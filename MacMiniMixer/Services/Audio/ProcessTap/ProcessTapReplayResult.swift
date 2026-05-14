import Foundation

struct ProcessTapReplayResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case invalidTarget
        case unsupportedOS
        case missingUsageDescription
        case permissionDenied
        case processNotFound
        case tapSetupFailed
        case playbackSetupFailed
        case replayCompleted
        case noAudioDetected
        case stopped
        case outputDeviceChanged
        case targetExited
        case cleanupWarning
    }

    let outcome: Outcome
    let message: String
    let detail: String?
    let severity: ProcessTapTestResult.Severity
    let diagnostics: ProcessTapReplayDiagnostics?

    init(
        outcome: Outcome,
        message: String,
        detail: String? = nil,
        severity: ProcessTapTestResult.Severity,
        diagnostics: ProcessTapReplayDiagnostics? = nil
    ) {
        self.outcome = outcome
        self.message = message
        self.detail = detail
        self.severity = severity
        self.diagnostics = diagnostics
    }

    var testResult: ProcessTapTestResult {
        ProcessTapTestResult(
            outcome: outcome.testOutcome,
            message: message,
            detail: detail,
            severity: severity
        )
    }
}

struct ProcessTapReplayDiagnostics: Equatable, Sendable {
    let selectedGain: ProcessTapReplayGainOption
    let callbackCount: Int
    let peakLevel: Double
    let rmsLevel: Double
    let enqueuedBufferCount: Int
    let droppedBufferCount: Int
    let enqueueFailureCount: Int
    let copyFailureCount: Int

    var totalFailureCount: Int {
        droppedBufferCount + enqueueFailureCount + copyFailureCount
    }
}

private extension ProcessTapReplayResult.Outcome {
    var testOutcome: ProcessTapTestResult.Outcome {
        switch self {
        case .invalidTarget:
            return .invalidTarget
        case .unsupportedOS:
            return .unsupportedOS
        case .missingUsageDescription:
            return .missingUsageDescription
        case .permissionDenied:
            return .permissionDenied
        case .processNotFound:
            return .processNotFound
        case .tapSetupFailed:
            return .tapSetupFailed
        case .playbackSetupFailed:
            return .replayProbePlaybackSetupFailed
        case .replayCompleted:
            return .replayProbeCompleted
        case .noAudioDetected:
            return .replayProbeNoAudio
        case .stopped:
            return .replayProbeStopped
        case .outputDeviceChanged:
            return .replayProbeOutputChanged
        case .targetExited:
            return .replayProbeTargetExited
        case .cleanupWarning:
            return .tapCleanupFailed
        }
    }
}
