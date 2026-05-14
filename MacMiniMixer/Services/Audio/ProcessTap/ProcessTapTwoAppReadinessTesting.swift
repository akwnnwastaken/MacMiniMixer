import Foundation

enum ProcessTapTwoAppReadinessSlot: String, CaseIterable, Sendable {
    case appA
    case appB

    var label: String {
        switch self {
        case .appA:
            return "App A"
        case .appB:
            return "App B"
        }
    }
}

struct ProcessTapTwoAppReadinessSessionSnapshot: Identifiable, Equatable, Sendable {
    var id: ProcessTapTwoAppReadinessSlot { slot }
    let slot: ProcessTapTwoAppReadinessSlot
    let sessionID: ProcessTapLiveSessionID?
    let appName: String
    let phase: ProcessTapLiveSessionPhase
    let selectedGain: ProcessTapReplayGainOption
    let diagnostics: ProcessTapLiveDiagnostics?
    let message: String?

    static func starting(
        slot: ProcessTapTwoAppReadinessSlot,
        target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption
    ) -> ProcessTapTwoAppReadinessSessionSnapshot {
        ProcessTapTwoAppReadinessSessionSnapshot(
            slot: slot,
            sessionID: nil,
            appName: target.appName,
            phase: .starting,
            selectedGain: gain,
            diagnostics: nil,
            message: nil
        )
    }

    static func final(
        slot: ProcessTapTwoAppReadinessSlot,
        target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        phase: ProcessTapLiveSessionPhase,
        message: String?
    ) -> ProcessTapTwoAppReadinessSessionSnapshot {
        ProcessTapTwoAppReadinessSessionSnapshot(
            slot: slot,
            sessionID: nil,
            appName: target.appName,
            phase: phase,
            selectedGain: gain,
            diagnostics: nil,
            message: message
        )
    }
}

struct ProcessTapTwoAppReadinessSnapshot: Equatable, Sendable {
    let sessions: [ProcessTapTwoAppReadinessSessionSnapshot]

    static let empty = ProcessTapTwoAppReadinessSnapshot(sessions: [])
}

struct ProcessTapTwoAppReadinessResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case idle
        case starting
        case running
        case notRunning
        case stopped
        case timedOut
        case outputDeviceChanged
        case appExited
        case invalidTarget
        case setupFailed
        case cleanupWarning
    }

    let outcome: Outcome
    let message: String
    let detail: String?
    let severity: ProcessTapTestResult.Severity

    init(
        outcome: Outcome,
        message: String,
        detail: String? = nil,
        severity: ProcessTapTestResult.Severity
    ) {
        self.outcome = outcome
        self.message = message
        self.detail = detail
        self.severity = severity
    }

    static let idle = ProcessTapTwoAppReadinessResult(
        outcome: .idle,
        message: "Two-app readiness idle",
        severity: .info
    )
}

protocol ProcessTapTwoAppReadinessTesting: Sendable {
    func startTest(
        appA: ProcessTapTarget,
        appB: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onUpdate: @escaping @Sendable (ProcessTapTwoAppReadinessSnapshot) -> Void,
        onFinished: @escaping @Sendable (ProcessTapTwoAppReadinessResult, ProcessTapTwoAppReadinessSnapshot) -> Void
    ) async -> ProcessTapTwoAppReadinessResult

    func stopAll(reason: ProcessTapLiveStopReason) async -> ProcessTapTwoAppReadinessResult

    @discardableResult
    func stopAllNow(reason: ProcessTapLiveStopReason) -> ProcessTapTwoAppReadinessResult?
}

final class CoreAudioProcessTapTwoAppReadinessTester: ProcessTapTwoAppReadinessTesting, @unchecked Sendable {
    private let lock = NSLock()
    private var activeRun: TwoAppReadinessRun?

    func startTest(
        appA: ProcessTapTarget,
        appB: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onUpdate: @escaping @Sendable (ProcessTapTwoAppReadinessSnapshot) -> Void,
        onFinished: @escaping @Sendable (ProcessTapTwoAppReadinessResult, ProcessTapTwoAppReadinessSnapshot) -> Void
    ) async -> ProcessTapTwoAppReadinessResult {
        guard appA.appID != appB.appID else {
            return ProcessTapTwoAppReadinessResult(
                outcome: .invalidTarget,
                message: "Choose two different apps",
                severity: .warning
            )
        }

        guard isValidTarget(appA), isValidTarget(appB) else {
            onUpdate(invalidTargetSnapshot(appA: appA, appB: appB, gain: gain))
            return ProcessTapTwoAppReadinessResult(
                outcome: .invalidTarget,
                message: "Both apps need valid processes",
                severity: .warning
            )
        }

        if let preflightFailure = preflightFailure(appA: appA, appB: appB, gain: gain) {
            onUpdate(preflightFailure.snapshot)
            return preflightFailure.result
        }

        let run = TwoAppReadinessRun(
            manager: ProcessTapLiveSessionManager(
                maxSessions: 2,
                controllerFactory: { CoreAudioProcessTapLiveController() }
            ),
            appA: appA,
            appB: appB,
            gain: gain,
            onUpdate: onUpdate,
            onFinished: onFinished
        )

        guard activate(run) else {
            return ProcessTapTwoAppReadinessResult(
                outcome: .setupFailed,
                message: "Two-app test is already running",
                severity: .warning
            )
        }

        onUpdate(run.snapshot)

        let appAStart = await run.manager.startSession(
            for: appA,
            gain: gain,
            onDiagnostics: { [weak self] sessionID, diagnostics in
                self?.recordDiagnostics(diagnostics, sessionID: sessionID, runID: run.id)
            },
            onStopped: { [weak self] sessionID, result, diagnostics in
                self?.handleSessionStopped(
                    sessionID: sessionID,
                    result: result,
                    diagnostics: diagnostics,
                    runID: run.id
                )
            }
        )

        guard appAStart.result.outcome == .liveControlStarted, let appASessionID = appAStart.sessionID else {
            run.markSetupFailed(slot: .appA, message: appAStart.result.message)
            run.markNotStarted(slot: .appB)
            finish(runID: run.id, result: setupFailureResult(appAStart.result), clearActiveRun: true)
            return setupFailureResult(appAStart.result)
        }

        run.markStarted(slot: .appA, sessionID: appASessionID)
        onUpdate(run.snapshot)

        let appBStart = await run.manager.startSession(
            for: appB,
            gain: gain,
            onDiagnostics: { [weak self] sessionID, diagnostics in
                self?.recordDiagnostics(diagnostics, sessionID: sessionID, runID: run.id)
            },
            onStopped: { [weak self] sessionID, result, diagnostics in
                self?.handleSessionStopped(
                    sessionID: sessionID,
                    result: result,
                    diagnostics: diagnostics,
                    runID: run.id
                )
            }
        )

        guard appBStart.result.outcome == .liveControlStarted, let appBSessionID = appBStart.sessionID else {
            run.markSetupFailed(slot: .appB, message: appBStart.result.message)
            _ = run.beginStopping()
            _ = await run.requestStop(reason: .setupFailed)
            run.finalizeUnresolvedStoppingSessions()
            finish(runID: run.id, result: setupFailureResult(appBStart.result), clearActiveRun: true)
            return setupFailureResult(appBStart.result)
        }

        run.markStarted(slot: .appB, sessionID: appBSessionID)
        onUpdate(run.snapshot)
        run.startTimeout { [weak self] runID in
            Task {
                _ = await self?.stopAll(runID: runID, reason: .timedOut)
            }
        }

        return ProcessTapTwoAppReadinessResult(
            outcome: .running,
            message: "Two-app test running",
            detail: "Auto-stops after \(Int(AppConstants.processTapTwoAppReadinessDuration))s.",
            severity: .info
        )
    }

    func stopAll(reason: ProcessTapLiveStopReason) async -> ProcessTapTwoAppReadinessResult {
        guard let run = currentRun() else {
            return ProcessTapTwoAppReadinessResult(
                outcome: .notRunning,
                message: "Two-app test is not running",
                severity: .info
            )
        }

        return await stopAll(runID: run.id, reason: reason)
    }

    @discardableResult
    func stopAllNow(reason: ProcessTapLiveStopReason) -> ProcessTapTwoAppReadinessResult? {
        guard let run = takeCurrentRun() else {
            return nil
        }

        run.cancelTimeout()
        _ = run.manager.stopLiveControlNow(reason: reason)
        run.finalizeUnresolvedStoppingSessions()
        let result = resultForStopReason(reason, snapshot: run.snapshot)
        run.onFinished(result, run.snapshot)
        return result
    }

    private func stopAll(runID: UUID, reason: ProcessTapLiveStopReason) async -> ProcessTapTwoAppReadinessResult {
        guard let run = run(with: runID) else {
            return ProcessTapTwoAppReadinessResult(
                outcome: .notRunning,
                message: "Two-app test is not running",
                severity: .info
            )
        }

        guard run.beginStopping() else {
            return resultForStopReason(reason, snapshot: run.snapshot)
        }

        run.cancelTimeout()
        _ = await run.requestStop(reason: reason)
        run.finalizeUnresolvedStoppingSessions()
        let result = resultForStopReason(reason, snapshot: run.snapshot)
        finish(runID: runID, result: result, clearActiveRun: true)
        return result
    }

    private func activate(_ run: TwoAppReadinessRun) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard activeRun == nil else {
            return false
        }

        activeRun = run
        return true
    }

    private func currentRun() -> TwoAppReadinessRun? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return activeRun
    }

    private func run(with id: UUID) -> TwoAppReadinessRun? {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard activeRun?.id == id else {
            return nil
        }

        return activeRun
    }

    private func takeCurrentRun() -> TwoAppReadinessRun? {
        lock.lock()
        defer {
            lock.unlock()
        }

        let run = activeRun
        activeRun = nil
        return run
    }

    private func finish(
        runID: UUID,
        result: ProcessTapTwoAppReadinessResult,
        clearActiveRun: Bool
    ) {
        guard let run = clearActiveRun ? takeRun(with: runID) : run(with: runID) else {
            return
        }

        run.cancelTimeout()
        run.onFinished(result, run.snapshot)
    }

    private func takeRun(with id: UUID) -> TwoAppReadinessRun? {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard activeRun?.id == id else {
            return nil
        }

        let run = activeRun
        activeRun = nil
        return run
    }

    private func recordDiagnostics(
        _ diagnostics: ProcessTapLiveDiagnostics,
        sessionID: ProcessTapLiveSessionID,
        runID: UUID
    ) {
        guard let run = run(with: runID) else {
            return
        }

        run.recordDiagnostics(diagnostics, sessionID: sessionID)
        run.onUpdate(run.snapshot)
    }

    private func handleSessionStopped(
        sessionID: ProcessTapLiveSessionID,
        result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?,
        runID: UUID
    ) {
        guard let run = run(with: runID) else {
            return
        }

        run.recordStopped(result, diagnostics: diagnostics, sessionID: sessionID)
        run.onUpdate(run.snapshot)

        guard !run.isStopping else {
            return
        }

        Task {
            _ = await stopAll(runID: runID, reason: result.outcome.twoAppStopReason)
        }
    }

    private func isValidTarget(_ target: ProcessTapTarget) -> Bool {
        guard let processIdentifier = target.processIdentifier else {
            return false
        }

        return processIdentifier > 0
    }

    private func preflightFailure(
        appA: ProcessTapTarget,
        appB: ProcessTapTarget,
        gain: ProcessTapReplayGainOption
    ) -> (result: ProcessTapTwoAppReadinessResult, snapshot: ProcessTapTwoAppReadinessSnapshot)? {
        let appAEligibility = ProcessTapCoreAudio.processTapEligibility(for: appA.processIdentifier)
        let appBEligibility = ProcessTapCoreAudio.processTapEligibility(for: appB.processIdentifier)

        guard appAEligibility.isEligible, appBEligibility.isEligible else {
            let appAFailed = !appAEligibility.isEligible
            let appBFailed = !appBEligibility.isEligible
            let reasons = [appAEligibility.reason, appBEligibility.reason]
                .compactMap { $0 }
            let reason = reasons.first ?? "Core Audio process unavailable"
            let message = reason == ProcessTapCoreAudio.unsupportedOSMessage
                ? "Process Tap is not available"
                : reason

            return (
                result: ProcessTapTwoAppReadinessResult(
                    outcome: .setupFailed,
                    message: message,
                    detail: appAFailed && appBFailed ? "Neither selected app is available to Core Audio." : "One selected app is not available to Core Audio.",
                    severity: .warning
                ),
                snapshot: ProcessTapTwoAppReadinessSnapshot(
                    sessions: [
                        .final(
                            slot: .appA,
                            target: appA,
                            gain: gain,
                            phase: appAFailed ? .failed : .stopped,
                            message: appAFailed ? appAEligibility.reason : "Not started"
                        ),
                        .final(
                            slot: .appB,
                            target: appB,
                            gain: gain,
                            phase: appBFailed ? .failed : .stopped,
                            message: appBFailed ? appBEligibility.reason : "Not started"
                        )
                    ]
                )
            )
        }

        return nil
    }

    private func invalidTargetSnapshot(
        appA: ProcessTapTarget,
        appB: ProcessTapTarget,
        gain: ProcessTapReplayGainOption
    ) -> ProcessTapTwoAppReadinessSnapshot {
        ProcessTapTwoAppReadinessSnapshot(
            sessions: [
                .final(
                    slot: .appA,
                    target: appA,
                    gain: gain,
                    phase: isValidTarget(appA) ? .stopped : .failed,
                    message: isValidTarget(appA) ? "Not started" : "Invalid process"
                ),
                .final(
                    slot: .appB,
                    target: appB,
                    gain: gain,
                    phase: isValidTarget(appB) ? .stopped : .failed,
                    message: isValidTarget(appB) ? "Not started" : "Invalid process"
                )
            ]
        )
    }

    private func finalSnapshot(
        appA: ProcessTapTarget,
        appB: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        appAMessage: String,
        appBMessage: String
    ) -> ProcessTapTwoAppReadinessSnapshot {
        ProcessTapTwoAppReadinessSnapshot(
            sessions: [
                .final(slot: .appA, target: appA, gain: gain, phase: .failed, message: appAMessage),
                .final(slot: .appB, target: appB, gain: gain, phase: .failed, message: appBMessage)
            ]
        )
    }

    private func setupFailureResult(_ result: ProcessTapTestResult) -> ProcessTapTwoAppReadinessResult {
        ProcessTapTwoAppReadinessResult(
            outcome: result.outcome == .permissionDenied ? .setupFailed : .setupFailed,
            message: "Two-app setup failed",
            detail: result.message,
            severity: .warning
        )
    }

    private func resultForStopReason(
        _ reason: ProcessTapLiveStopReason,
        snapshot: ProcessTapTwoAppReadinessSnapshot
    ) -> ProcessTapTwoAppReadinessResult {
        let detail = snapshot.sessions
            .map { session in
                let diagnostics = session.diagnostics
                return "\(session.appName): \(diagnostics?.callbackCount ?? 0) cb, drops \(diagnostics?.droppedBufferCount ?? 0), fail \(diagnostics?.totalFailureCount ?? 0)"
            }
            .joined(separator: " | ")

        switch reason {
        case .timedOut:
            return ProcessTapTwoAppReadinessResult(
                outcome: .timedOut,
                message: "Two-app test stopped: timeout",
                detail: detail,
                severity: .warning
            )
        case .outputDeviceChanged:
            return ProcessTapTwoAppReadinessResult(
                outcome: .outputDeviceChanged,
                message: "Two-app test stopped: output changed",
                detail: detail,
                severity: .warning
            )
        case .targetAppExited:
            return ProcessTapTwoAppReadinessResult(
                outcome: .appExited,
                message: "Two-app test stopped: app exited",
                detail: detail,
                severity: .warning
            )
        case .appTerminating:
            return ProcessTapTwoAppReadinessResult(
                outcome: .stopped,
                message: "Two-app test stopped for quit",
                detail: detail,
                severity: .info
            )
        case .setupFailed:
            return ProcessTapTwoAppReadinessResult(
                outcome: .setupFailed,
                message: "Two-app setup failed",
                detail: detail,
                severity: .warning
            )
        case .userStopped:
            return ProcessTapTwoAppReadinessResult(
                outcome: .stopped,
                message: "Two-app test stopped",
                detail: detail,
                severity: .info
            )
        }
    }
}

private final class TwoAppReadinessRun: @unchecked Sendable {
    let id = UUID()
    let manager: ProcessTapLiveSessionManager
    let onUpdate: @Sendable (ProcessTapTwoAppReadinessSnapshot) -> Void
    let onFinished: @Sendable (ProcessTapTwoAppReadinessResult, ProcessTapTwoAppReadinessSnapshot) -> Void

    private let lock = NSLock()
    private var sessions: [ProcessTapTwoAppReadinessSlot: ProcessTapTwoAppReadinessSessionSnapshot]
    private var sessionSlots: [ProcessTapLiveSessionID: ProcessTapTwoAppReadinessSlot] = [:]
    private var timeoutTask: Task<Void, Never>?
    private var didBeginStopping = false

    init(
        manager: ProcessTapLiveSessionManager,
        appA: ProcessTapTarget,
        appB: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onUpdate: @escaping @Sendable (ProcessTapTwoAppReadinessSnapshot) -> Void,
        onFinished: @escaping @Sendable (ProcessTapTwoAppReadinessResult, ProcessTapTwoAppReadinessSnapshot) -> Void
    ) {
        self.manager = manager
        self.onUpdate = onUpdate
        self.onFinished = onFinished
        self.sessions = [
            .appA: .starting(slot: .appA, target: appA, gain: gain),
            .appB: .starting(slot: .appB, target: appB, gain: gain)
        ]
    }

    var snapshot: ProcessTapTwoAppReadinessSnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }

        return ProcessTapTwoAppReadinessSnapshot(
            sessions: ProcessTapTwoAppReadinessSlot.allCases.compactMap { sessions[$0] }
        )
    }

    var isStopping: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        return didBeginStopping
    }

    func markStarted(slot: ProcessTapTwoAppReadinessSlot, sessionID: ProcessTapLiveSessionID) {
        lock.lock()
        if let session = sessions[slot] {
            sessions[slot] = ProcessTapTwoAppReadinessSessionSnapshot(
                slot: slot,
                sessionID: sessionID,
                appName: session.appName,
                phase: .active,
                selectedGain: session.selectedGain,
                diagnostics: session.diagnostics,
                message: nil
            )
            sessionSlots[sessionID] = slot
        }
        lock.unlock()
    }

    func recordDiagnostics(_ diagnostics: ProcessTapLiveDiagnostics, sessionID: ProcessTapLiveSessionID) {
        updateSession(sessionID: sessionID, phase: .active, diagnostics: diagnostics, message: nil)
    }

    func recordStopped(
        _ result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?,
        sessionID: ProcessTapLiveSessionID
    ) {
        updateSession(
            sessionID: sessionID,
            phase: result.outcome == .tapCleanupFailed ? .failed : .stopped,
            diagnostics: diagnostics,
            message: result.message
        )
    }

    func markSetupFailed(slot: ProcessTapTwoAppReadinessSlot, message: String) {
        lock.lock()
        if let session = sessions[slot] {
            sessions[slot] = ProcessTapTwoAppReadinessSessionSnapshot(
                slot: session.slot,
                sessionID: session.sessionID,
                appName: session.appName,
                phase: .failed,
                selectedGain: session.selectedGain,
                diagnostics: session.diagnostics,
                message: message
            )
        }
        lock.unlock()
    }

    func markNotStarted(slot: ProcessTapTwoAppReadinessSlot) {
        lock.lock()
        if let session = sessions[slot] {
            sessions[slot] = ProcessTapTwoAppReadinessSessionSnapshot(
                slot: session.slot,
                sessionID: session.sessionID,
                appName: session.appName,
                phase: .stopped,
                selectedGain: session.selectedGain,
                diagnostics: session.diagnostics,
                message: "Not started"
            )
        }
        lock.unlock()
    }

    func beginStopping() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !didBeginStopping else {
            return false
        }

        didBeginStopping = true
        sessions = sessions.mapValues { session in
            guard session.phase == .starting || session.phase == .active else {
                return session
            }

            return ProcessTapTwoAppReadinessSessionSnapshot(
                slot: session.slot,
                sessionID: session.sessionID,
                appName: session.appName,
                phase: .stopping,
                selectedGain: session.selectedGain,
                diagnostics: session.diagnostics,
                message: session.message
            )
        }
        return true
    }

    func finalizeUnresolvedStoppingSessions() {
        lock.lock()
        sessions = sessions.mapValues { session in
            let finalPhase: ProcessTapLiveSessionPhase
            let finalMessage: String?

            switch session.phase {
            case .starting:
                finalPhase = .failed
                finalMessage = session.message ?? "Setup did not complete"
            case .stopping:
                finalPhase = .stopped
                finalMessage = session.message
            default:
                return session
            }

            return ProcessTapTwoAppReadinessSessionSnapshot(
                slot: session.slot,
                sessionID: session.sessionID,
                appName: session.appName,
                phase: finalPhase,
                selectedGain: session.selectedGain,
                diagnostics: session.diagnostics,
                message: finalMessage
            )
        }
        lock.unlock()
    }

    func requestStop(reason: ProcessTapLiveStopReason) async -> [ProcessTapTestResult] {
        await manager.stopAll(reason: reason)
    }

    func startTimeout(_ action: @escaping @Sendable (UUID) -> Void) {
        timeoutTask?.cancel()
        timeoutTask = Task { [id] in
            let delay = UInt64(AppConstants.processTapTwoAppReadinessDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)

            guard !Task.isCancelled else {
                return
            }

            action(id)
        }
    }

    func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func updateSession(
        sessionID: ProcessTapLiveSessionID,
        phase: ProcessTapLiveSessionPhase,
        diagnostics: ProcessTapLiveDiagnostics?,
        message: String?
    ) {
        lock.lock()
        guard let slot = sessionSlots[sessionID],
              let session = sessions[slot] else {
            lock.unlock()
            return
        }

        sessions[slot] = ProcessTapTwoAppReadinessSessionSnapshot(
            slot: slot,
            sessionID: sessionID,
            appName: session.appName,
            phase: phase,
            selectedGain: diagnostics?.selectedGain ?? session.selectedGain,
            diagnostics: diagnostics ?? session.diagnostics,
            message: message
        )
        lock.unlock()
    }
}

private extension ProcessTapTestResult.Outcome {
    var twoAppStopReason: ProcessTapLiveStopReason {
        switch self {
        case .liveControlTimedOut:
            return .timedOut
        case .liveControlOutputChanged:
            return .outputDeviceChanged
        case .liveControlAppExited:
            return .targetAppExited
        case .tapCleanupFailed:
            return .setupFailed
        default:
            return .setupFailed
        }
    }
}
