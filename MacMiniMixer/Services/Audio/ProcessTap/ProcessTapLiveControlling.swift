import Foundation

protocol ProcessTapLiveControlling: Sendable {
    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption)

    @discardableResult
    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult?
}
