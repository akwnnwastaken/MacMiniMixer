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
