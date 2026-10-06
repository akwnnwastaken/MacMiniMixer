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

    func testFailedVolumeWriteMarksOutputVolumeNonWritable() {
        let volumeController = FakeSystemVolumeController(shouldSucceed: false)
        let coordinator = makeCoordinator(systemVolumeController: volumeController)

        XCTAssertTrue(coordinator.isSystemOutputVolumeWritable)

        coordinator.setSystemVolume(80)

        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)
    }

    func testSwitchingOutputDeviceResetsVolumeWritability() {
        let volumeController = FakeSystemVolumeController(shouldSucceed: false)
        let coordinator = makeCoordinator(
            outputDeviceLister: FakeOutputDeviceLister(devices: [
                makeSystemOutputDevice(id: "built-in", isDefault: true),
                makeSystemOutputDevice(id: "airpods")
            ]),
            systemVolumeController: volumeController
        )

        coordinator.setSystemVolume(80)
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)

        _ = coordinator.selectOutputDevice("airpods")

        XCTAssertTrue(coordinator.isSystemOutputVolumeWritable)
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

    func testFinishEditingWithoutPriorSetReturnsNoWarning() {
        let coordinator = makeCoordinator()

        let message = coordinator.finishSystemVolumeEditing()

        XCTAssertNil(message)
    }

    func testFinishEditingAfterSuccessfulSetReturnsNoWarning() {
        let volumeController = FakeSystemVolumeController()
        let coordinator = makeCoordinator(systemVolumeController: volumeController)

        coordinator.setSystemVolume(60)
        let message = coordinator.finishSystemVolumeEditing()

        XCTAssertNil(message)
    }

    func testRefreshWithUnchangedDevicesReportsNoOutputDeviceChange() {
        let lister = FakeOutputDeviceLister(devices: [
            makeSystemOutputDevice(id: "built-in", isDefault: true),
            makeSystemOutputDevice(id: "airpods")
        ])
        let coordinator = makeCoordinator(outputDeviceLister: lister)

        let result = coordinator.refreshOutputDevices()

        XCTAssertEqual(coordinator.selectedOutputDeviceID, "built-in")
        XCTAssertEqual(result.previousDefaultDeviceID, "built-in")
        XCTAssertEqual(result.currentDefaultDeviceID, "built-in")
        XCTAssertFalse(result.didSelectionChange)
        XCTAssertFalse(result.didOutputDeviceChange)
    }

    func testMuteFailureReportsCouldNotMuteWarning() {
        let audioController = FakeSystemOutputAudioController(systemVolume: 70)
        let volumeController = FakeSystemVolumeController(shouldSucceed: false)
        let coordinator = makeCoordinator(
            audioController: audioController,
            systemVolumeController: volumeController
        )

        let message = coordinator.toggleSystemOutputMuted()

        XCTAssertEqual(message, "Could not mute system output")
    }

    func testRestoreFailureReportsCouldNotRestoreWarning() {
        let audioController = FakeSystemOutputAudioController(systemVolume: 0)
        let volumeController = FakeSystemVolumeController(shouldSucceed: false)
        let coordinator = makeCoordinator(
            audioController: audioController,
            systemVolumeController: volumeController
        )

        XCTAssertTrue(coordinator.isSystemOutputMuted)

        let message = coordinator.toggleSystemOutputMuted()

        XCTAssertEqual(message, "Could not restore system output")
    }

    func testUnmutingFromZeroWithoutRememberedVolumeRestoresDefault() {
        let audioController = FakeSystemOutputAudioController(systemVolume: 0)
        let volumeController = FakeSystemVolumeController()
        let coordinator = makeCoordinator(
            audioController: audioController,
            systemVolumeController: volumeController
        )

        XCTAssertTrue(coordinator.isSystemOutputMuted)

        let message = coordinator.toggleSystemOutputMuted()

        XCTAssertNil(message)
        XCTAssertEqual(coordinator.systemVolume, AppConstants.defaultSystemOutputRestoreVolume)
        XCTAssertFalse(coordinator.isSystemOutputMuted)
        XCTAssertEqual(
            volumeController.requestedScalars,
            [AppConstants.defaultSystemOutputRestoreVolume / AppConstants.volumeRange.upperBound]
        )
        XCTAssertEqual(
            audioController.setSystemVolumeRequests,
            [AppConstants.defaultSystemOutputRestoreVolume]
        )
    }

    // MARK: - Proactive volume writability probe

    func testInitialNotSettableProbeMarksOutputVolumeNonWritableWithoutWriting() {
        let volumeController = FakeSystemVolumeController(settableProbeResult: false)
        let coordinator = makeCoordinator(systemVolumeController: volumeController)

        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(volumeController.settableProbeCount, 1)
        XCTAssertTrue(volumeController.requestedScalars.isEmpty)
    }

    func testInitialUnknownProbeAssumesOutputVolumeWritable() {
        let volumeController = FakeSystemVolumeController(settableProbeResult: nil)
        let coordinator = makeCoordinator(systemVolumeController: volumeController)

        XCTAssertTrue(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(volumeController.settableProbeCount, 1)
    }

    func testInitialSettableProbeKeepsOutputVolumeWritable() {
        let volumeController = FakeSystemVolumeController(settableProbeResult: true)
        let coordinator = makeCoordinator(systemVolumeController: volumeController)

        XCTAssertTrue(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(volumeController.settableProbeCount, 1)
    }

    func testRefreshDetectingOutputDeviceChangeReprobesWritability() {
        let lister = FakeOutputDeviceLister(devices: [
            makeSystemOutputDevice(id: "built-in", isDefault: true),
            makeSystemOutputDevice(id: "hdmi")
        ])
        let volumeController = FakeSystemVolumeController(settableProbeResult: true)
        let coordinator = makeCoordinator(
            outputDeviceLister: lister,
            systemVolumeController: volumeController
        )
        XCTAssertTrue(coordinator.isSystemOutputVolumeWritable)

        lister.devices = [
            makeSystemOutputDevice(id: "built-in"),
            makeSystemOutputDevice(id: "hdmi", isDefault: true)
        ]
        volumeController.settableProbeResult = false

        let result = coordinator.refreshOutputDevices()

        XCTAssertTrue(result.didOutputDeviceChange)
        XCTAssertEqual(coordinator.selectedOutputDeviceID, "hdmi")
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(volumeController.settableProbeCount, 2)
        XCTAssertTrue(volumeController.requestedScalars.isEmpty)
    }

    func testRefreshDetectingOutputDeviceChangeWithUnknownProbeClearsReadOnly() {
        let lister = FakeOutputDeviceLister(devices: [
            makeSystemOutputDevice(id: "hdmi", isDefault: true),
            makeSystemOutputDevice(id: "built-in")
        ])
        let volumeController = FakeSystemVolumeController(settableProbeResult: false)
        let coordinator = makeCoordinator(
            outputDeviceLister: lister,
            systemVolumeController: volumeController
        )
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)

        lister.devices = [
            makeSystemOutputDevice(id: "hdmi"),
            makeSystemOutputDevice(id: "built-in", isDefault: true)
        ]
        volumeController.settableProbeResult = nil

        let result = coordinator.refreshOutputDevices()

        XCTAssertTrue(result.didOutputDeviceChange)
        XCTAssertEqual(coordinator.selectedOutputDeviceID, "built-in")
        XCTAssertTrue(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(volumeController.settableProbeCount, 2)
    }

    func testRefreshWithoutOutputDeviceChangeKeepsRejectedWriteWithoutReprobing() {
        let volumeController = FakeSystemVolumeController(shouldSucceed: false, settableProbeResult: true)
        let coordinator = makeCoordinator(systemVolumeController: volumeController)

        coordinator.setSystemVolume(80)
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)

        let result = coordinator.refreshOutputDevices()

        XCTAssertFalse(result.didOutputDeviceChange)
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(volumeController.settableProbeCount, 1)
    }

    func testSuccessfulOutputDeviceSelectionReprobesWritability() {
        let volumeController = FakeSystemVolumeController(settableProbeResult: true)
        let coordinator = makeCoordinator(
            outputDeviceLister: FakeOutputDeviceLister(devices: [
                makeSystemOutputDevice(id: "built-in", isDefault: true),
                makeSystemOutputDevice(id: "hdmi")
            ]),
            systemVolumeController: volumeController
        )
        XCTAssertTrue(coordinator.isSystemOutputVolumeWritable)
        volumeController.settableProbeResult = false

        let result = coordinator.selectOutputDevice("hdmi")

        XCTAssertEqual(result, SystemOutputDeviceSelectionResult.selected)
        XCTAssertEqual(coordinator.selectedOutputDeviceID, "hdmi")
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(volumeController.settableProbeCount, 2)
    }

    func testSuccessfulOutputDeviceSelectionWithUnknownProbeAssumesWritable() {
        let volumeController = FakeSystemVolumeController(settableProbeResult: false)
        let coordinator = makeCoordinator(
            outputDeviceLister: FakeOutputDeviceLister(devices: [
                makeSystemOutputDevice(id: "hdmi", isDefault: true),
                makeSystemOutputDevice(id: "airpods")
            ]),
            systemVolumeController: volumeController
        )
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)
        volumeController.settableProbeResult = nil

        let result = coordinator.selectOutputDevice("airpods")

        XCTAssertEqual(result, SystemOutputDeviceSelectionResult.selected)
        XCTAssertTrue(coordinator.isSystemOutputVolumeWritable)
    }

    func testRejectedWriteAfterSettableProbeMarksOutputVolumeNonWritable() {
        let volumeController = FakeSystemVolumeController(shouldSucceed: false, settableProbeResult: true)
        let coordinator = makeCoordinator(systemVolumeController: volumeController)
        XCTAssertTrue(coordinator.isSystemOutputVolumeWritable)

        coordinator.setSystemVolume(80)
        let message = coordinator.finishSystemVolumeEditing()

        XCTAssertEqual(message, "This device does not expose writable volume")
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(volumeController.settableProbeCount, 1)
    }

    func testSuccessfulWriteAfterNotSettableProbeMarksOutputVolumeWritable() {
        let volumeController = FakeSystemVolumeController(shouldSucceed: true, settableProbeResult: false)
        let coordinator = makeCoordinator(systemVolumeController: volumeController)
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)

        coordinator.setSystemVolume(60)

        XCTAssertTrue(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(volumeController.requestedScalars, [0.6])
    }

    func testProbeDrivenWritabilityChangeNotifiesBeforeApplying() {
        let volumeController = FakeSystemVolumeController(settableProbeResult: true)
        let coordinator = makeCoordinator(systemVolumeController: volumeController)
        var writabilityObservedAtNotify: [Bool] = []
        coordinator.setOnWillChange {
            // willSet-style timing: a read here still observes the previous value.
            writabilityObservedAtNotify.append(coordinator.isSystemOutputVolumeWritable)
        }
        volumeController.settableProbeResult = false

        // Re-selecting the current device keeps the selection, so the probe is the only
        // source of the writability change.
        let result = coordinator.selectOutputDevice("built-in")

        XCTAssertEqual(result, SystemOutputDeviceSelectionResult.selected)
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(writabilityObservedAtNotify.last, true)
    }

    // MARK: - Failure paths

    func testFailedOutputDeviceSelectionRestoresPreviousWritabilityWithoutReprobing() {
        let volumeController = FakeSystemVolumeController(settableProbeResult: false)
        let coordinator = makeCoordinator(
            outputDeviceLister: FakeOutputDeviceLister(devices: [
                makeSystemOutputDevice(id: "hdmi", isDefault: true),
                makeSystemOutputDevice(id: "airpods")
            ]),
            outputDeviceController: FakeOutputDeviceController(shouldSucceed: false),
            systemVolumeController: volumeController
        )
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)

        let result = coordinator.selectOutputDevice("airpods")

        XCTAssertEqual(result, SystemOutputDeviceSelectionResult.failed(message: "Could not switch output device"))
        XCTAssertEqual(coordinator.selectedOutputDeviceID, "hdmi")
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(volumeController.settableProbeCount, 1)
    }

    func testSelectingUnknownOutputDeviceReturnsNotFoundWithoutSideEffects() {
        let controller = FakeOutputDeviceController()
        let volumeController = FakeSystemVolumeController()
        let coordinator = makeCoordinator(
            outputDeviceController: controller,
            systemVolumeController: volumeController
        )
        var willChangeCount = 0
        coordinator.setOnWillChange { willChangeCount += 1 }

        let result = coordinator.selectOutputDevice("missing")

        XCTAssertEqual(result, SystemOutputDeviceSelectionResult.notFound)
        XCTAssertEqual(coordinator.selectedOutputDeviceID, "built-in")
        XCTAssertTrue(controller.requestedDeviceIDs.isEmpty)
        XCTAssertEqual(willChangeCount, 0)
        XCTAssertEqual(volumeController.settableProbeCount, 1)
    }

    func testMissingOutputDevicesFallBackToPlaceholderSelection() {
        let controller = FakeOutputDeviceController()
        let coordinator = makeCoordinator(
            outputDeviceLister: FakeOutputDeviceLister(devices: []),
            outputDeviceController: controller
        )

        let result = coordinator.selectOutputDevice("output:none")

        XCTAssertEqual(coordinator.selectedOutputDeviceID, "output:none")
        XCTAssertEqual(coordinator.selectedOutputDeviceName, "Output")
        XCTAssertEqual(result, SystemOutputDeviceSelectionResult.notFound)
        XCTAssertTrue(controller.requestedDeviceIDs.isEmpty)
    }

    func testRefreshWhenAllOutputDevicesDisappearFallsBackToPlaceholder() {
        let lister = FakeOutputDeviceLister(devices: [
            makeSystemOutputDevice(id: "built-in", isDefault: true)
        ])
        let coordinator = makeCoordinator(outputDeviceLister: lister)
        lister.devices = []

        let result = coordinator.refreshOutputDevices()

        XCTAssertTrue(coordinator.outputDevices.isEmpty)
        XCTAssertEqual(coordinator.selectedOutputDeviceID, "output:none")
        XCTAssertEqual(coordinator.selectedOutputDeviceName, "Output")
        XCTAssertEqual(result.previousDefaultDeviceID, "built-in")
        XCTAssertNil(result.currentDefaultDeviceID)
        XCTAssertTrue(result.didSelectionChange)
        XCTAssertTrue(result.didOutputDeviceChange)
    }

    func testRefreshSystemOutputVolumeWithUnavailableReaderKeepsCurrentState() {
        let audioController = FakeSystemOutputAudioController(systemVolume: 35)
        let reader = FakeSystemVolumeReader(volumeScalar: nil)
        let coordinator = makeCoordinator(
            audioController: audioController,
            systemVolumeReader: reader
        )
        var willChangeCount = 0
        coordinator.setOnWillChange { willChangeCount += 1 }

        coordinator.refreshSystemOutputVolume()

        XCTAssertEqual(coordinator.systemVolume, 35)
        XCTAssertFalse(coordinator.isSystemOutputMuted)
        XCTAssertEqual(willChangeCount, 0)
    }

    func testFailedVolumeWriteWarningIsReportedOnceWhenReaderIsUnavailable() {
        let audioController = FakeSystemOutputAudioController(systemVolume: 25)
        let reader = FakeSystemVolumeReader(volumeScalar: nil)
        let volumeController = FakeSystemVolumeController(shouldSucceed: false)
        let coordinator = makeCoordinator(
            audioController: audioController,
            systemVolumeReader: reader,
            systemVolumeController: volumeController
        )

        coordinator.setSystemVolume(80)
        let firstMessage = coordinator.finishSystemVolumeEditing()
        let secondMessage = coordinator.finishSystemVolumeEditing()

        XCTAssertEqual(firstMessage, "This device does not expose writable volume")
        XCTAssertNil(secondMessage)
        XCTAssertEqual(volumeController.requestedScalars, [0.8])
        XCTAssertTrue(audioController.setSystemVolumeRequests.isEmpty)
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)
    }

    func testFinishEditingReflectsOnlyTheMostRecentWriteOfADrag() {
        let volumeController = FakeSystemVolumeController(shouldSucceed: false)
        let coordinator = makeCoordinator(systemVolumeController: volumeController)

        coordinator.setSystemVolume(80)
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)
        volumeController.shouldSucceed = true
        coordinator.setSystemVolume(60)
        let message = coordinator.finishSystemVolumeEditing()

        XCTAssertNil(message)
        XCTAssertTrue(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(volumeController.requestedScalars, [0.8, 0.6])
    }

    func testMuteFailureRefreshesVolumeFromReaderAndMarksNonWritable() {
        let audioController = FakeSystemOutputAudioController(systemVolume: 70)
        let reader = FakeSystemVolumeReader(volumeScalar: 0.7)
        let volumeController = FakeSystemVolumeController(shouldSucceed: false)
        let coordinator = makeCoordinator(
            audioController: audioController,
            systemVolumeReader: reader,
            systemVolumeController: volumeController
        )

        let message = coordinator.toggleSystemOutputMuted()

        XCTAssertEqual(message, "Could not mute system output")
        XCTAssertEqual(volumeController.requestedScalars, [0])
        XCTAssertEqual(coordinator.systemVolume, 70, accuracy: 0.0001)
        XCTAssertFalse(coordinator.isSystemOutputMuted)
        XCTAssertTrue(audioController.setSystemVolumeRequests.isEmpty)
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)
    }

    func testRestoreFailureKeepsRememberedVolumeForNextRestore() {
        let audioController = FakeSystemOutputAudioController(systemVolume: 70)
        let reader = FakeSystemVolumeReader(volumeScalar: 0)
        let volumeController = FakeSystemVolumeController()
        let coordinator = makeCoordinator(
            audioController: audioController,
            systemVolumeReader: reader,
            systemVolumeController: volumeController
        )

        let muteMessage = coordinator.toggleSystemOutputMuted()
        XCTAssertNil(muteMessage)
        volumeController.shouldSucceed = false

        let failedRestoreMessage = coordinator.toggleSystemOutputMuted()

        XCTAssertEqual(failedRestoreMessage, "Could not restore system output")
        XCTAssertEqual(coordinator.systemVolume, 0)
        XCTAssertTrue(coordinator.isSystemOutputMuted)
        XCTAssertFalse(coordinator.isSystemOutputVolumeWritable)

        volumeController.shouldSucceed = true
        let restoreMessage = coordinator.toggleSystemOutputMuted()

        XCTAssertNil(restoreMessage)
        XCTAssertEqual(coordinator.systemVolume, 70)
        XCTAssertFalse(coordinator.isSystemOutputMuted)
        XCTAssertTrue(coordinator.isSystemOutputVolumeWritable)
        XCTAssertEqual(volumeController.requestedScalars, [0, 0.7, 0.7])
        XCTAssertEqual(audioController.setSystemVolumeRequests, [0, 70])
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
    /// Value returned by the read-only writability probe (`nil` = unknown).
    var settableProbeResult: Bool?
    private(set) var requestedScalars: [Double] = []
    private(set) var settableProbeCount = 0

    init(shouldSucceed: Bool = true, settableProbeResult: Bool? = nil) {
        self.shouldSucceed = shouldSucceed
        self.settableProbeResult = settableProbeResult
    }

    func setCurrentOutputVolumeScalar(_ volumeScalar: Double) -> Bool {
        requestedScalars.append(volumeScalar)
        return shouldSucceed
    }

    func isCurrentOutputVolumeSettable() -> Bool? {
        settableProbeCount += 1
        return settableProbeResult
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

final class CoreAudioOutputDeviceListerOwnDeviceTests: XCTestCase {
    func testMacMiniMixerAggregateDeviceUIDsAreHiddenFromTheSelector() {
        for uid in [
            "com.macminimixer.process-tap-live-output.4C1F2A9E-1D3B-4E5F-8A7B-0C9D8E7F6A5B",
            "com.macminimixer.process-tap-live-control.4C1F2A9E",
            "com.macminimixer.helper-audio-probe.4C1F2A9E",
            "com.macminimixer.process-tap-replay-probe.4C1F2A9E",
            "com.macminimixer.process-tap-diagnostic.4C1F2A9E",
            "com.macminimixer.process-tap-mute-probe.4C1F2A9E"
        ] {
            XCTAssertTrue(CoreAudioOutputDeviceLister.isOwnAggregateDevice(uid: uid), uid)
        }
    }

    func testOtherDeviceUIDsStayInTheSelector() {
        XCTAssertFalse(CoreAudioOutputDeviceLister.isOwnAggregateDevice(uid: nil))
        XCTAssertFalse(CoreAudioOutputDeviceLister.isOwnAggregateDevice(uid: "BuiltInSpeakerDevice"))
        XCTAssertFalse(CoreAudioOutputDeviceLister.isOwnAggregateDevice(uid: "AppleUSBAudioEngine:Generic:USB Audio:1234:1"))
        // A user's own aggregate (Audio MIDI Setup) is not ours to hide here.
        XCTAssertFalse(CoreAudioOutputDeviceLister.isOwnAggregateDevice(uid: "~:AMS2_Aggregate:0"))
    }
}
