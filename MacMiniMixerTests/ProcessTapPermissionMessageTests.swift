import CoreAudio
import XCTest
@testable import MacMiniMixer

final class ProcessTapPermissionMessageTests: XCTestCase {
    func testPermissionDeniedStatusUsesActionableUserMessage() {
        XCTAssertTrue(ProcessTapPermissionMessage.isPermissionDeniedStatus(kAudioDevicePermissionsError))
        XCTAssertEqual(
            ProcessTapPermissionMessage.message(
                forCreateStatus: kAudioDevicePermissionsError,
                fallback: "Could not create process tap"
            ),
            "System Audio Recording permission is required for Process Tap."
        )
        XCTAssertEqual(
            ProcessTapPermissionMessage.detail(
                forCreateStatus: kAudioDevicePermissionsError,
                fallback: "Create failed."
            ),
            "Enable it in System Settings → Privacy & Security → System Audio Recording."
        )
    }

    func testNonPermissionStatusKeepsFallbackMessageAndDetail() {
        XCTAssertFalse(ProcessTapPermissionMessage.isPermissionDeniedStatus(noErr))
        XCTAssertEqual(
            ProcessTapPermissionMessage.message(
                forCreateStatus: noErr,
                fallback: "Could not create process tap"
            ),
            "Could not create process tap"
        )
        XCTAssertEqual(
            ProcessTapPermissionMessage.detail(
                forCreateStatus: noErr,
                fallback: "Create failed."
            ),
            "Create failed."
        )
    }

    func testLiveControlWarningMessageMapsStopOutcomes() {
        XCTAssertEqual(makeResult(.liveControlTimedOut).liveControlWarningMessage, "Live control stopped: timeout")
        XCTAssertEqual(makeResult(.liveControlAppExited).liveControlWarningMessage, "Live control stopped: app exited")
        XCTAssertEqual(makeResult(.liveControlOutputChanged).liveControlWarningMessage, "Live control stopped: output device changed")
        XCTAssertEqual(makeResult(.liveControlSetupFailed).liveControlWarningMessage, "Could not start live control")
        XCTAssertEqual(makeResult(.tapCleanupFailed).liveControlWarningMessage, "Live control cleanup warning")
    }

    func testLiveControlWarningMessageReusesPermissionMessages() {
        XCTAssertEqual(makeResult(.permissionDenied).liveControlWarningMessage, ProcessTapPermissionMessage.permissionRequired)
        XCTAssertEqual(makeResult(.missingUsageDescription).liveControlWarningMessage, ProcessTapPermissionMessage.missingUsageDescription)
        XCTAssertEqual(makeResult(.unsupportedOS).liveControlWarningMessage, ProcessTapCoreAudio.unsupportedOSMessage)
    }

    func testLiveControlWarningMessageIsNilForNonWarningOutcomes() {
        XCTAssertNil(makeResult(.liveControlStarted).liveControlWarningMessage)
        XCTAssertNil(makeResult(.liveControlStopped).liveControlWarningMessage)
        XCTAssertNil(makeResult(.tapSetupSucceeded).liveControlWarningMessage)
    }

    func testOnlyPermissionDeniedSuggestsSystemAudioRecordingSettings() {
        XCTAssertTrue(makeResult(.permissionDenied).suggestsSystemAudioRecordingSettings)
        XCTAssertFalse(makeResult(.missingUsageDescription).suggestsSystemAudioRecordingSettings)
        XCTAssertFalse(makeResult(.unsupportedOS).suggestsSystemAudioRecordingSettings)
        XCTAssertFalse(makeResult(.liveControlStarted).suggestsSystemAudioRecordingSettings)
    }

    func testSystemAudioRecordingSettingsURLTargetsPrivacyPane() {
        XCTAssertEqual(
            ProcessTapPermissionMessage.systemAudioRecordingSettingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        )
    }

    private func makeResult(_ outcome: ProcessTapTestResult.Outcome) -> ProcessTapTestResult {
        ProcessTapTestResult(outcome: outcome, message: "", severity: .warning)
    }

    func testMissingUsageDescriptionReasonUsesConfigurationMessage() {
        XCTAssertEqual(
            ProcessTapPermissionMessage.message(
                forEligibilityReason: ProcessTapPermissionMessage.missingUsageDescriptionReason,
                fallback: "Process Tap is unavailable"
            ),
            "System Audio Recording permission is not configured."
        )
        XCTAssertEqual(
            ProcessTapPermissionMessage.detail(
                forEligibilityReason: ProcessTapPermissionMessage.missingUsageDescriptionReason
            ),
            "NSAudioCaptureUsageDescription is missing from the app bundle."
        )
    }
}
