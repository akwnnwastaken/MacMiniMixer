import Foundation

protocol ProcessTapLiveSessionManaging: Sendable {
    var activeSession: ProcessTapLiveSessionState? { get }
    var activeSessions: [ProcessTapLiveSessionState] { get }

    func startSession(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapLiveSessionStartResult

    func stopSession(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult
    func stopAll(reason: ProcessTapLiveStopReason) async -> [ProcessTapTestResult]
    func updateGain(sessionID: ProcessTapLiveSessionID, gain: ProcessTapReplayGainOption)
}

final class ProcessTapLiveSessionManager: ProcessTapLiveSessionManaging, ProcessTapLiveControlling, @unchecked Sendable {
    private let controllerFactory: @Sendable () -> ProcessTapLiveControlling
    private let maxSessions: Int
    private let lock = NSLock()
    private var sessions: [ProcessTapLiveSessionID: ProcessTapLiveSessionState] = [:]
    private var controllers: [ProcessTapLiveSessionID: ProcessTapLiveControlling] = [:]
    private var compatibilityActiveSessionID: ProcessTapLiveSessionID?

    init(controller: ProcessTapLiveControlling) {
        self.controllerFactory = { controller }
        self.maxSessions = 1
    }

    init(
        maxSessions: Int,
        controllerFactory: @escaping @Sendable () -> ProcessTapLiveControlling
    ) {
        self.controllerFactory = controllerFactory
        self.maxSessions = max(1, maxSessions)
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
        let sessionID = ProcessTapLiveSessionID()
        let sessionState = ProcessTapLiveSessionState(id: sessionID, target: target, gain: gain)
        let controller = controllerFactory()

        guard reserveSession(sessionState, controller: controller) else {
            return ProcessTapLiveSessionStartResult(
                sessionID: nil,
                result: ProcessTapTestResult(
                    outcome: .liveControlSetupFailed,
                    message: "Live control is already active",
                    severity: .warning
                )
            )
        }

        let result = await controller.startLiveControl(
            for: target,
            gain: gain
        ) { [weak self] diagnostics in
            self?.recordDiagnostics(diagnostics, for: sessionID)
            onDiagnostics(sessionID, diagnostics)
        } onStopped: { [weak self] result, diagnostics in
            self?.recordStopped(result, diagnostics: diagnostics, for: sessionID)
            onStopped(sessionID, result, diagnostics)
        }

        if result.outcome == .liveControlStarted {
            markSession(sessionID, phase: .active, gain: gain)
            return ProcessTapLiveSessionStartResult(sessionID: sessionID, result: result)
        }

        markSession(sessionID, phase: .failed)
        removeSession(sessionID)
        return ProcessTapLiveSessionStartResult(sessionID: nil, result: result)
    }

    func stopSession(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        markSession(id, phase: .stopping, stopReason: reason)

        guard let controller = controller(for: id) else {
            removeSession(id)
            return ProcessTapTestResult(
                outcome: .liveControlNotActive,
                message: "Live control is not active",
                severity: .info
            )
        }

        let result = await controller.stopLiveControl(reason: reason)
        if result.outcome == .liveControlNotActive {
            removeSession(id)
        }

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
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        let startResult = await startSession(
            for: target,
            gain: gain,
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

        guard activeSessionCount < maxSessions else {
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
        if var session = sessions[sessionID] {
            session.phase = result.outcome == .tapCleanupFailed ? .failed : .stopped
            session.diagnostics = diagnostics
            session.stopReason = result.outcome.stopReason
            if result.outcome == .tapCleanupFailed, let detail = result.detail {
                session.cleanupWarnings = [detail]
            }
            sessions[sessionID] = session
        }

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
