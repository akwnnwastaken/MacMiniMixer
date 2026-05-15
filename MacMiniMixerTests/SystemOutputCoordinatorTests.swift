import XCTest
@testable import MacMiniMixer

@MainActor
final class SystemOutputCoordinatorTests: XCTestCase {
    func testRefreshSystemOutputVolumeReadsCurrentVolume() {
        let reader = FakeSystemVolumeReader(volumeScalar: 0.42)
        let coordinator = makeCoordinator(systemVolumeReader: reader)

        coordinator.refreshSystemOutputVolume()

        XCTAssertEqual(coordinator.systemVolume, 42, accuracy: 0.0001)
        XCTAssertFalse(coordinator.isSystemOutputMuted)
    }

    func testSetSystemVolumeClampsAndWritesRequestedValue() {
        let audioController = FakeSystemOutputAudioController(systemVolume: 25)
        let volumeController = FakeSystemVolumeController()
        let coordinator = makeCoordinator(
            audioController: audioController,
            systemVolumeController: volumeController
        )

        coordinator.setSystemVolume(150)

        XCTAssertEqual(coordinator.systemVolume, 100)
        XCTAssertEqual(volumeController.requestedScalars, [1])
        XCTAssertEqual(audioController.setSystemVolumeRequests, [100])
    }

    func testFailedVolumeWriteReportsEditingWarningAndRefreshesVolume() {
        let audioController = FakeSystemOutputAudioController(systemVolume: 25)
        let reader = FakeSystemVolumeReader(volumeScalar: 0.25)
        let volumeController = FakeSystemVolumeController(shouldSucceed: false)
        let coordinator = makeCoordinator(
            audioController: audioController,
            systemVolumeReader: reader,
            systemVolumeController: volumeController
        )

        coordinator.setSystemVolume(80)
        let message = coordinator.finishSystemVolumeEditing()

        XCTAssertEqual(message, "This device does not expose writable volume")
        XCTAssertEqual(coordinator.systemVolume, 25)
        XCTAssertTrue(audioController.setSystemVolumeRequests.isEmpty)
    }

    func testMuteSetsVolumeToZeroAndRemembersLastNonZeroVolume() {
        let audioController = FakeSystemOutputAudioController(systemVolume: 70)
        let volumeController = FakeSystemVolumeController()
        let coordinator = makeCoordinator(
            audioController: audioController,
            systemVolumeController: volumeController
        )

        let muteMessage = coordinator.toggleSystemOutputMuted()
        let restoreMessage = coordinator.toggleSystemOutputMuted()

        XCTAssertNil(muteMessage)
        XCTAssertNil(restoreMessage)
        XCTAssertEqual(volumeController.requestedScalars, [0, 0.7])
        XCTAssertEqual(audioController.setSystemVolumeRequests, [0, 70])
        XCTAssertEqual(coordinator.systemVolume, 70)
        XCTAssertFalse(coordinator.isSystemOutputMuted)
    }

    func testOutputDeviceRefreshUpdatesDevicesAndSelectedDefault() {
        let lister = FakeOutputDeviceLister(devices: [
            makeSystemOutputDevice(id: "built-in", isDefault: true),
            makeSystemOutputDevice(id: "airpods")
        ])
        let coordinator = makeCoordinator(outputDeviceLister: lister)
        lister.devices = [
            makeSystemOutputDevice(id: "built-in"),
            makeSystemOutputDevice(id: "airpods", isDefault: true),
            makeSystemOutputDevice(id: "display")
        ]

        let result = coordinator.refreshOutputDevices()

        XCTAssertEqual(coordinator.outputDevices.map { $0.id }, ["built-in", "airpods", "display"])
        XCTAssertEqual(coordinator.selectedOutputDeviceID, "airpods")
        XCTAssertEqual(result.previousDefaultDeviceID, "built-in")
        XCTAssertEqual(result.currentDefaultDeviceID, "airpods")
        XCTAssertTrue(result.didSelectionChange)
        XCTAssertTrue(result.didOutputDeviceChange)
    }

    func testOutputDeviceSelectionSuccessUpdatesSelectedDevice() {
        let controller = FakeOutputDeviceController()
        let coordinator = makeCoordinator(
            outputDeviceLister: FakeOutputDeviceLister(devices: [
                makeSystemOutputDevice(id: "built-in", isDefault: true),
                makeSystemOutputDevice(id: "airpods")
            ]),
            outputDeviceController: controller
        )

        let result = coordinator.selectOutputDevice("airpods")

        XCTAssertEqual(result, SystemOutputDeviceSelectionResult.selected)
        XCTAssertEqual(coordinator.selectedOutputDeviceID, "airpods")
        XCTAssertEqual(controller.requestedDeviceIDs, ["airpods"])
    }

    func testOutputDeviceSelectionFailureReportsWarningAndRestoresPreviousSelection() {
        let controller = FakeOutputDeviceController(shouldSucceed: false)
        let coordinator = makeCoordinator(
            outputDeviceLister: FakeOutputDeviceLister(devices: [
                makeSystemOutputDevice(id: "built-in", isDefault: true),
                makeSystemOutputDevice(id: "airpods")
            ]),
            outputDeviceController: controller
        )

        let result = coordinator.selectOutputDevice("airpods")

        XCTAssertEqual(result, SystemOutputDeviceSelectionResult.failed(message: "Could not switch output device"))
        XCTAssertEqual(coordinator.selectedOutputDeviceID, "built-in")
        XCTAssertEqual(controller.requestedDeviceIDs, ["airpods"])
    }

    func testRefreshWithoutDefaultKeepsFallbackSelectionWhenAvailable() {
        let lister = FakeOutputDeviceLister(devices: [
            makeSystemOutputDevice(id: "built-in", isDefault: true),
            makeSystemOutputDevice(id: "airpods")
        ])
        let coordinator = makeCoordinator(outputDeviceLister: lister)

        _ = coordinator.selectOutputDevice("airpods")
        lister.devices = [
            makeSystemOutputDevice(id: "built-in"),
            makeSystemOutputDevice(id: "airpods")
        ]

        let result = coordinator.refreshOutputDevices()

        XCTAssertEqual(coordinator.selectedOutputDeviceID, "airpods")
        XCTAssertFalse(result.didSelectionChange)
        XCTAssertTrue(result.didOutputDeviceChange)
    }

    private func makeCoordinator(
        audioController: FakeSystemOutputAudioController = FakeSystemOutputAudioController(systemVolume: 50),
        outputDeviceLister: FakeOutputDeviceLister = FakeOutputDeviceLister(devices: [
            makeSystemOutputDevice(id: "built-in", isDefault: true)
        ]),
        outputDeviceController: FakeOutputDeviceController = FakeOutputDeviceController(),
        systemVolumeReader: FakeSystemVolumeReader = FakeSystemVolumeReader(volumeScalar: 0.5),
        systemVolumeController: FakeSystemVolumeController = FakeSystemVolumeController()
    ) -> SystemOutputCoordinator {
        SystemOutputCoordinator(
            audioController: audioController,
            outputDeviceLister: outputDeviceLister,
            outputDeviceController: outputDeviceController,
            systemVolumeReader: systemVolumeReader,
            systemVolumeController: systemVolumeController
        )
    }

}

private func makeSystemOutputDevice(id: String, isDefault: Bool = false) -> OutputDeviceItem {
    OutputDeviceItem(
        id: id,
        name: id,
        iconSystemName: "speaker.wave.2.fill",
        isSystemDefault: isDefault,
        audioDeviceID: nil
    )
}

private final class FakeSystemOutputAudioController: AudioControlling {
    private(set) var systemVolume: Double
    private(set) var setSystemVolumeRequests: [Double] = []
    private(set) var appVolumeRequests: [(volume: Double, appID: MixerAppItem.ID)] = []
    private(set) var appMutedRequests: [(isMuted: Bool, appID: MixerAppItem.ID)] = []

    init(systemVolume: Double) {
        self.systemVolume = systemVolume
    }

    func setSystemVolume(_ volume: Double) {
        systemVolume = volume
        setSystemVolumeRequests.append(volume)
    }

    func setVolume(_ volume: Double, for appID: MixerAppItem.ID) {
        appVolumeRequests.append((volume, appID))
    }

    func setMuted(_ isMuted: Bool, for appID: MixerAppItem.ID) {
        appMutedRequests.append((isMuted, appID))
    }
}

private final class FakeSystemVolumeReader: SystemVolumeReading {
    var volumeScalar: Double?

    init(volumeScalar: Double?) {
        self.volumeScalar = volumeScalar
    }

    func readCurrentOutputVolumeScalar() -> Double? {
        volumeScalar
    }
}

private final class FakeSystemVolumeController: SystemVolumeControlling {
    var shouldSucceed: Bool
    private(set) var requestedScalars: [Double] = []

    init(shouldSucceed: Bool = true) {
        self.shouldSucceed = shouldSucceed
    }

    func setCurrentOutputVolumeScalar(_ volumeScalar: Double) -> Bool {
        requestedScalars.append(volumeScalar)
        return shouldSucceed
    }
}

private final class FakeOutputDeviceLister: OutputDeviceListing {
    var devices: [OutputDeviceItem]

    init(devices: [OutputDeviceItem]) {
        self.devices = devices
    }

    func listOutputDevices() -> [OutputDeviceItem] {
        devices
    }
}

private final class FakeOutputDeviceController: OutputDeviceControlling {
    var shouldSucceed: Bool
    private(set) var requestedDeviceIDs: [OutputDeviceItem.ID] = []

    init(shouldSucceed: Bool = true) {
        self.shouldSucceed = shouldSucceed
    }

    func setDefaultOutputDevice(_ device: OutputDeviceItem) -> Bool {
        requestedDeviceIDs.append(device.id)
        return shouldSucceed
    }
}
