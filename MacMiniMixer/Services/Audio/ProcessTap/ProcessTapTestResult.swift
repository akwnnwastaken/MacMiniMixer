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
        case replayProbeStopped
        case replayProbeOutputChanged
        case replayProbeTargetExited
        case liveControlStarting
        case liveControlStarted
        case liveControlNotActive
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

extension ProcessTapTestResult {
    /// User-facing warning to surface for a live-control outcome, or `nil` when the outcome
    /// needs no warning. Pure mapping extracted from `MixerViewModel` so it can be unit
    /// tested without driving the whole view model.
    var liveControlWarningMessage: String? {
        switch outcome {
        case .tapCleanupFailed:
            return "Live control cleanup warning"
        case .liveControlTimedOut:
            return "Live control stopped: timeout"
        case .liveControlOutputChanged:
            return "Live control stopped: output device changed"
        case .liveControlAppExited:
            return "Live control stopped: app exited"
        case .liveControlSetupFailed:
            return "Could not start live control"
        case .missingUsageDescription:
            return ProcessTapPermissionMessage.missingUsageDescription
        case .permissionDenied:
            return ProcessTapPermissionMessage.permissionRequired
        case .unsupportedOS:
            return ProcessTapCoreAudio.unsupportedOSMessage
        default:
            return nil
        }
    }

    /// Whether this outcome is fixable by the user granting System Audio Recording in System
    /// Settings. Only `.permissionDenied` qualifies: `.missingUsageDescription` is a build
    /// configuration problem, not something a user can resolve in Settings.
    var suggestsSystemAudioRecordingSettings: Bool {
        outcome == .permissionDenied
    }
}
