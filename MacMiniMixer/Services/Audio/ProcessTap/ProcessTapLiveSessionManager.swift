import Foundation

/// Serializes every Product Real Core Audio *lifecycle* operation — private-aggregate / tap / IOProc
/// / AudioQueue **create** (a session start) and **destroy** (a session stop) — so no two ever run
/// concurrently against coreaudiod.
///
/// Why this exists: each Product Real session owns its own aggregate device wrapping a process tap.
/// Creating or destroying one of those aggregates makes coreaudiod reconfigure the shared HAL device
/// list, which briefly disturbs *every* running IO — including a still-active session's replay queue.
/// If a teardown of one session overlaps the setup of another (or a second teardown), two of those
/// reconfigurations land at once and the disturbance compounds, producing the audible starvation /
/// clicks seen during a combination change (stop B while A stays active, then start C). Funnelling
/// all setup/teardown through this actor makes coreaudiod see one route change at a time.
///
/// This is *not* an audio-callback lock: only session setup/teardown passes through here. The
/// realtime replay callback path never touches this actor. It also does not impose any delay — it
/// only prevents overlap; the post-teardown settle window stays owned by `ProductRealStartSettleGate`
/// on the start path.
actor ProductRealCoreAudioLifecycleGate {
    /// Tail of the serial chain: the most recently enqueued operation (which may still be running).
    /// A new operation awaits this before starting, then installs itself as the new tail, so every
    /// operation runs strictly after all previously enqueued ones have finished.
    private var tail: Task<Void, Never>?

    /// Runs `operation` only after every previously enqueued operation has completed, guaranteeing
    /// Core Audio setup/teardown never overlaps, and returns the operation's own result to its
    /// caller. Operations are admitted in the order they enter the actor (FIFO).
    @discardableResult
    func perform<T: Sendable>(_ operation: @Sendable @escaping () async -> T) async -> T {
        let previous = tail
        let work = Task { () -> T in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await work.value }
        return await work.value
    }
}

protocol ProcessTapLiveSessionManaging: Sendable {
    var activeSession: ProcessTapLiveSessionState? { get }
    var activeSessions: [ProcessTapLiveSessionState] { get }

    func startSession(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapLiveSessionStartResult

    func startSession(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapLiveSessionStartResult

    func stopSession(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult
    func stopAll(reason: ProcessTapLiveStopReason) async -> [ProcessTapTestResult]
    func updateGain(sessionID: ProcessTapLiveSessionID, gain: ProcessTapReplayGainOption)
}

final class ProcessTapLiveSessionManager: ProcessTapLiveSessionManaging, ProcessTapLiveControlling, @unchecked Sendable {
    private let controllerFactory: @Sendable () -> ProcessTapLiveControlling
    /// Maximum concurrent (starting/active/stopping) sessions, or `nil` for no limit. The Product
    /// Real manager is built with `AppConstants.maxConcurrentLiveSessions` (nil = unlimited); the
    /// compatibility initializer and diagnostics (e.g. Two-App Readiness) pass explicit caps.
    private let maxSessions: Int?
    /// Serializes all Core Audio session create/destroy across every session this manager owns, so a
    /// teardown never overlaps a setup (or another teardown) and churns the shared route twice at
    /// once. Shared by all sessions here because they all target the same coreaudiod route.
    private let lifecycleGate: ProductRealCoreAudioLifecycleGate
    private let lock = NSLock()
    private var sessions: [ProcessTapLiveSessionID: ProcessTapLiveSessionState] = [:]
    private var controllers: [ProcessTapLiveSessionID: ProcessTapLiveControlling] = [:]
    private var compatibilityActiveSessionID: ProcessTapLiveSessionID?

    init(
        controller: ProcessTapLiveControlling,
        lifecycleGate: ProductRealCoreAudioLifecycleGate = ProductRealCoreAudioLifecycleGate()
    ) {
        self.controllerFactory = { controller }
        self.maxSessions = 1
        self.lifecycleGate = lifecycleGate
    }

    /// - Parameter maxSessions: Concurrent-session cap; `nil` means unlimited. A non-nil value is
    ///   clamped to at least 1.
    init(
        maxSessions: Int?,
        lifecycleGate: ProductRealCoreAudioLifecycleGate = ProductRealCoreAudioLifecycleGate(),
        controllerFactory: @escaping @Sendable () -> ProcessTapLiveControlling
    ) {
        self.controllerFactory = controllerFactory
        self.maxSessions = maxSessions.map { max(1, $0) }
        self.lifecycleGate = lifecycleGate
    }

    var activeSession: ProcessTapLiveSessionState? {
        activeSessions.first
    }

    var activeSessions: [ProcessTapLiveSessionState] {
        lock.lock()
        defer {
            lock.unlock()
        }

        return sessions.values
            .filter { $0.phase == .starting || $0.phase == .active || $0.phase == .stopping }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func startSession(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapLiveSessionStartResult {
        await startSession(
            for: target,
            gain: gain,
            timeoutPolicy: .standard,
            onDiagnostics: onDiagnostics,
            onStopped: onStopped
        )
    }

    // Non-private so multi-session callers (e.g. Two-App Readiness) can choose a timeout
    // policy other than `.standard`; the protocol method keeps the `.standard` default.
    func startSession(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapLiveSessionStartResult {
        let sessionID = ProcessTapLiveSessionID()
        let sessionState = ProcessTapLiveSessionState(id: sessionID, target: target, gain: gain)
        let controller = controllerFactory()

        guard reserveSession(sessionState, controller: controller) else {
            AppLogger.processTap.warning("Live session start rejected: max sessions reached app=\(target.appName, privacy: .public) pid=\(target.processIdentifier ?? -1, privacy: .public) maxSessions=\(self.maxSessionsLogDescription, privacy: .public)")
            return ProcessTapLiveSessionStartResult(
                sessionID: nil,
                result: ProcessTapTestResult(
                    outcome: .liveControlSetupFailed,
                    message: "Live control is already active",
                    severity: .warning
                )
            )
        }

        AppLogger.processTap.info("Live session start reserved sessionID=\(sessionID.rawValue.uuidString, privacy: .public) app=\(target.appName, privacy: .public) pid=\(target.processIdentifier ?? -1, privacy: .public)")
        // Core Audio object creation (aggregate/tap/IOProc/AudioQueue) goes through the lifecycle
        // gate so it never overlaps another session's create or a teardown churning the same route.
        let result = await lifecycleGate.perform {
            await controller.startLiveControl(
                for: target,
                gain: gain,
                timeoutPolicy: timeoutPolicy
            ) { [weak self] diagnostics in
                self?.recordDiagnostics(diagnostics, for: sessionID)
                onDiagnostics(sessionID, diagnostics)
            } onStopped: { [weak self] result, diagnostics in
                self?.recordStopped(result, diagnostics: diagnostics, for: sessionID)
                onStopped(sessionID, result, diagnostics)
            }
        }

        if result.outcome == .liveControlStarted {
            markSession(sessionID, phase: .active, gain: gain)
            AppLogger.processTap.info("Live session active sessionID=\(sessionID.rawValue.uuidString, privacy: .public) app=\(target.appName, privacy: .public)")
            return ProcessTapLiveSessionStartResult(sessionID: sessionID, result: result)
        }

        markSession(sessionID, phase: .failed)
        removeSession(sessionID)
        AppLogger.processTap.warning("Live session start failed sessionID=\(sessionID.rawValue.uuidString, privacy: .public) app=\(target.appName, privacy: .public) outcome=\(String(describing: result.outcome), privacy: .public)")
        return ProcessTapLiveSessionStartResult(sessionID: nil, result: result)
    }

    func stopSession(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        AppLogger.processTap.info("Live session stop requested sessionID=\(id.rawValue.uuidString, privacy: .public) reason=\(String(describing: reason), privacy: .public)")
        markSession(id, phase: .stopping, stopReason: reason)

        guard let controller = controller(for: id) else {
            removeSession(id)
            AppLogger.processTap.info("Live session stop found no controller sessionID=\(id.rawValue.uuidString, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .liveControlNotActive,
                message: "Live control is not active",
                severity: .info
            )
        }

        // Core Audio teardown goes through the same lifecycle gate as creation, so destroying this
        // session's aggregate/tap never overlaps another session's create/destroy on the shared
        // route — the single most likely source of the combination-change starvation/clicks.
        let result = await lifecycleGate.perform {
            await controller.stopLiveControl(reason: reason)
        }
        if result.outcome == .liveControlNotActive {
            removeSession(id)
        }

        AppLogger.processTap.info("Live session stop completed sessionID=\(id.rawValue.uuidString, privacy: .public) outcome=\(String(describing: result.outcome), privacy: .public)")
        return result
    }

    func stopAll(reason: ProcessTapLiveStopReason) async -> [ProcessTapTestResult] {
        let sessionIDs = activeSessions.map(\.id)
        guard !sessionIDs.isEmpty else {
            return []
        }

        var results: [ProcessTapTestResult] = []
        for sessionID in sessionIDs {
            let result = await stopSession(id: sessionID, reason: reason)
            results.append(result)
        }

        return results
    }

    func updateGain(sessionID: ProcessTapLiveSessionID, gain: ProcessTapReplayGainOption) {
        lock.lock()
        guard var session = sessions[sessionID] else {
            lock.unlock()
            return
        }

        session.gain = gain
        sessions[sessionID] = session
        lock.unlock()

        controller(for: sessionID)?.updateLiveControlGain(gain)
    }

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        let startResult = await startSession(
            for: target,
            gain: gain,
            timeoutPolicy: timeoutPolicy,
            onDiagnostics: { _, diagnostics in
                onDiagnostics(diagnostics)
            },
            onStopped: { _, result, diagnostics in
                onStopped(result, diagnostics)
            }
        )

        if let sessionID = startResult.sessionID {
            setCompatibilityActiveSessionID(sessionID)
        }

        return startResult.result
    }

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        guard let sessionID = currentCompatibilitySessionID() ?? activeSession?.id else {
            return ProcessTapTestResult(
                outcome: .liveControlNotActive,
                message: "Live control is not active",
                severity: .info
            )
        }

        return await stopSession(id: sessionID, reason: reason)
    }

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption) {
        guard let sessionID = currentCompatibilitySessionID() ?? activeSession?.id else {
            return
        }

        updateGain(sessionID: sessionID, gain: gain)
    }

    @discardableResult
    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult? {
        lock.lock()
        let sessionIDs = activeSessionIDs
        let controllersToStop = sessionIDs.compactMap { controllers[$0] }
        for sessionID in sessionIDs {
            if var session = sessions[sessionID] {
                session.phase = .stopping
                session.stopReason = reason
                sessions[sessionID] = session
            }
        }
        compatibilityActiveSessionID = nil
        lock.unlock()

        var result: ProcessTapTestResult?
        for controller in controllersToStop {
            let sessionResult = controller.stopLiveControlNow(reason: reason)
            result = result ?? sessionResult
        }

        lock.lock()
        for sessionID in sessionIDs {
            sessions.removeValue(forKey: sessionID)
            controllers.removeValue(forKey: sessionID)
        }
        lock.unlock()

        return result
    }

    private var activeSessionCount: Int {
        sessions.values.filter { $0.phase == .starting || $0.phase == .active || $0.phase == .stopping }.count
    }

    /// Log-friendly rendering of the cap, so an unlimited manager never prints a sentinel number.
    private var maxSessionsLogDescription: String {
        maxSessions.map { String($0) } ?? "unlimited"
    }

    private var activeSessionIDs: [ProcessTapLiveSessionID] {
        sessions
            .filter { $0.value.phase == .starting || $0.value.phase == .active || $0.value.phase == .stopping }
            .map(\.key)
    }

    private func reserveSession(
        _ sessionState: ProcessTapLiveSessionState,
        controller: ProcessTapLiveControlling
    ) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        // `nil` cap = unlimited: every reservation is admitted (resource failures surface later
        // through the controller's own start result).
        if let maxSessions = self.maxSessions, activeSessionCount >= maxSessions {
            return false
        }

        sessions[sessionState.id] = sessionState
        controllers[sessionState.id] = controller
        return true
    }

    private func controller(for sessionID: ProcessTapLiveSessionID) -> ProcessTapLiveControlling? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return controllers[sessionID]
    }

    private func currentCompatibilitySessionID() -> ProcessTapLiveSessionID? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return compatibilityActiveSessionID
    }

    private func setCompatibilityActiveSessionID(_ sessionID: ProcessTapLiveSessionID) {
        lock.lock()
        compatibilityActiveSessionID = sessionID
        lock.unlock()
    }

    private func markSession(
        _ sessionID: ProcessTapLiveSessionID,
        phase: ProcessTapLiveSessionPhase,
        gain: ProcessTapReplayGainOption? = nil,
        stopReason: ProcessTapLiveStopReason? = nil
    ) {
        lock.lock()
        if var session = sessions[sessionID] {
            session.phase = phase
            if let gain {
                session.gain = gain
            }
            if let stopReason {
                session.stopReason = stopReason
            }
            sessions[sessionID] = session
        }
        lock.unlock()
    }

    private func recordDiagnostics(_ diagnostics: ProcessTapLiveDiagnostics, for sessionID: ProcessTapLiveSessionID) {
        lock.lock()
        if var session = sessions[sessionID] {
            session.diagnostics = diagnostics
            session.gain = diagnostics.selectedGain
            sessions[sessionID] = session
        }
        lock.unlock()
    }

    private func recordStopped(
        _ result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?,
        for sessionID: ProcessTapLiveSessionID
    ) {
        lock.lock()
        // The session is terminal here (stopped, or cleanup-failed). We remove it directly rather
        // than writing its final phase/diagnostics/cleanupWarnings back first: the manager only ever
        // exposes non-terminal sessions (`activeSessions` filters to starting/active/stopping), and
        // the terminal `result`/`diagnostics` are already delivered to callers by the external
        // onStopped callback. Writing the final state and then removing the entry on the next line
        // under this same lock was a dead store (never observable), so it is intentionally omitted.
        sessions.removeValue(forKey: sessionID)
        controllers.removeValue(forKey: sessionID)
        if compatibilityActiveSessionID == sessionID {
            compatibilityActiveSessionID = nil
        }
        lock.unlock()
    }

    private func removeSession(_ sessionID: ProcessTapLiveSessionID) {
        lock.lock()
        sessions.removeValue(forKey: sessionID)
        controllers.removeValue(forKey: sessionID)
        if compatibilityActiveSessionID == sessionID {
            compatibilityActiveSessionID = nil
        }
        lock.unlock()
    }
}

private extension ProcessTapTestResult.Outcome {
    var stopReason: ProcessTapLiveStopReason? {
        switch self {
        case .liveControlTimedOut:
            return .timedOut
        case .liveControlOutputChanged:
            return .outputDeviceChanged
        case .liveControlAppExited:
            return .targetAppExited
        case .liveControlSetupFailed:
            return .setupFailed
        case .liveControlStopped, .tapCleanupFailed:
            return .userStopped
        default:
            return nil
        }
    }
}
