import Foundation

struct ProcessTapTestResult: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable {
        case invalidTarget
        case unsupportedOS
        case missingUsageDescription
        case permissionUnknown
        case permissionDenied
        case processNotFound
        case tapSetupSucceeded
        case tapSetupFailed
        case tapCleanupFailed
        case streamDiagnosticsRunning
        case streamDiagnosticsDetectedAudio
        case streamDiagnosticsNoAudio
        case streamDiagnosticsNoCallbacks
        case streamDiagnosticsLevelUnavailable
        case helperProbeRunning
        case helperProbeStopped
        case helperProbeOutputChanged
        case helperProbeTargetExited
        case muteBehaviorNotAvailable
        case muteBehaviorProbeDetectedAudio
        case muteBehaviorProbeNoAudio
        case muteBehaviorProbeNoCallbacks
        case replayProbeRunning
        case replayProbeCompleted
        case replayProbeNoAudio
        case replayProbePlaybackSetupFailed
        case liveControlStarting
        case liveControlStarted
        case liveControlStopped
        case liveControlTimedOut
        case liveControlOutputChanged
        case liveControlAppExited
        case liveControlSetupFailed
    }

    enum Severity: Equatable, Sendable {
        case info
        case warning
    }

    let id: UUID
    let outcome: Outcome
    let message: String
    let detail: String?
    let severity: Severity

    init(
        id: UUID = UUID(),
        outcome: Outcome,
        message: String,
        detail: String? = nil,
        severity: Severity
    ) {
        self.id = id
        self.outcome = outcome
        self.message = message
        self.detail = detail
        self.severity = severity
    }
}
