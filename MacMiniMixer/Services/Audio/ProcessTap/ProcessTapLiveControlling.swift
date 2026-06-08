import Foundation

enum ProcessTapLiveTimeoutPolicy: Equatable, Sendable {
    case limited(TimeInterval)
    case indefinite

    static let standard = ProcessTapLiveTimeoutPolicy.limited(AppConstants.processTapLiveControlMaxDuration)
}

protocol ProcessTapLiveControlling: Sendable {
    func startLiveControlSession(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapLiveSessionStartResult

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult

    func stopLiveControlSession(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption)

    @discardableResult
    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult?
}

extension ProcessTapLiveControlling {
    func startLiveControlSession(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapLiveSessionStartResult {
        let result = await startLiveControl(
            for: target,
            gain: gain,
            timeoutPolicy: timeoutPolicy,
            onDiagnostics: onDiagnostics,
            onStopped: onStopped
        )
        return ProcessTapLiveSessionStartResult(sessionID: nil, result: result)
    }

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        await startLiveControl(
            for: target,
            gain: gain,
            timeoutPolicy: .standard,
            onDiagnostics: onDiagnostics,
            onStopped: onStopped
        )
    }

    func stopLiveControlSession(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        ProcessTapTestResult(
            outcome: .liveControlNotActive,
            message: "Live control is not active",
            severity: .info
        )
    }
}
