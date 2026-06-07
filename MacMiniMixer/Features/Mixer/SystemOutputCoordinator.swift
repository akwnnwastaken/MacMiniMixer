import Foundation

struct SystemOutputRefreshResult: Equatable {
    let previousDefaultDeviceID: OutputDeviceItem.ID?
    let currentDefaultDeviceID: OutputDeviceItem.ID?
    let didSelectionChange: Bool

    var didOutputDeviceChange: Bool {
        didSelectionChange || currentDefaultDeviceID != previousDefaultDeviceID
    }
}

enum SystemOutputDeviceSelectionResult: Equatable {
    case selected
    case notFound
    case failed(message: String)
}

@MainActor
final class SystemOutputCoordinator {
    private(set) var systemVolume: Double
    private(set) var outputDevices: [OutputDeviceItem]
    private(set) var selectedOutputDeviceID: OutputDeviceItem.ID
    private(set) var isSystemOutputMuted: Bool
    /// Whether the currently selected output device accepted the most recent volume
    /// write. Assumed writable until a write attempt is rejected, and reset to writable
    /// whenever the selected device changes.
    private(set) var isSystemOutputVolumeWritable = true

    private let audioController: AudioControlling
    private let outputDeviceLister: OutputDeviceListing
    private let outputDeviceController: OutputDeviceControlling
    private let systemVolumeReader: SystemVolumeReading
    private let systemVolumeController: SystemVolumeControlling
    private var lastNonZeroSystemVolume: Double
    private var lastSliderVolumeSetSucceeded: Bool?
    private var onWillChange: (() -> Void)?

    init(
        audioController: AudioControlling,
        outputDeviceLister: OutputDeviceListing,
        outputDeviceController: OutputDeviceControlling,
        systemVolumeReader: SystemVolumeReading,
        systemVolumeController: SystemVolumeControlling
    ) {
        self.audioController = audioController
        self.outputDeviceLister = outputDeviceLister
        self.outputDeviceController = outputDeviceController
        self.systemVolumeReader = systemVolumeReader
        self.systemVolumeController = systemVolumeController

        let initialSystemVolume = audioController.systemVolume.clamped(to: AppConstants.volumeRange)
        self.systemVolume = initialSystemVolume
        self.isSystemOutputMuted = initialSystemVolume <= AppConstants.volumeRange.lowerBound
        self.lastNonZeroSystemVolume = initialSystemVolume > AppConstants.volumeRange.lowerBound
            ? initialSystemVolume
            : AppConstants.defaultSystemOutputRestoreVolume

        let listedOutputDevices = outputDeviceLister.listOutputDevices()
        self.outputDevices = listedOutputDevices
        self.selectedOutputDeviceID = Self.preferredOutputDeviceID(in: listedOutputDevices)
    }

    var selectedOutputDeviceName: String {
        outputDevices.first { $0.id == selectedOutputDeviceID }?.name ?? "Output"
    }

    func setOnWillChange(_ onWillChange: @escaping () -> Void) {
        self.onWillChange = onWillChange
    }

    func setSystemVolume(_ volume: Double) {
        lastSliderVolumeSetSucceeded = applyRequestedSystemVolume(volume)
    }

    func finishSystemVolumeEditing() -> String? {
        defer {
            lastSliderVolumeSetSucceeded = nil
            refreshSystemOutputVolume()
        }

        guard let didUpdateVolume = lastSliderVolumeSetSucceeded else {
            return nil
        }

        return didUpdateVolume ? nil : "This device does not expose writable volume"
    }

    func toggleSystemOutputMuted() -> String? {
        let willRestoreOutput = isSystemOutputMuted || systemVolume <= AppConstants.volumeRange.lowerBound
        let targetVolume: Double

        if willRestoreOutput {
            targetVolume = restoredSystemOutputVolume
        } else {
            rememberNonZeroSystemVolume(systemVolume)
            targetVolume = AppConstants.volumeRange.lowerBound
        }

        guard applyRequestedSystemVolume(targetVolume) else {
            refreshSystemOutputVolume()
            return willRestoreOutput ? "Could not restore system output" : "Could not mute system output"
        }

        return nil
    }

    func selectOutputDevice(_ deviceID: OutputDeviceItem.ID) -> SystemOutputDeviceSelectionResult {
        guard let device = outputDevices.first(where: { $0.id == deviceID }) else {
            return .notFound
        }

        let previousDeviceID = selectedOutputDeviceID
        setSelectedOutputDeviceID(deviceID)

        guard outputDeviceController.setDefaultOutputDevice(device) else {
            setSelectedOutputDeviceID(previousDeviceID)
            return .failed(message: "Could not switch output device")
        }

        return .selected
    }

    func refreshOutputDevices() -> SystemOutputRefreshResult {
        let previousDeviceID = selectedOutputDeviceID
        let previousDefaultDeviceID = outputDevices.first { $0.isSystemDefault }?.id
        let refreshedDevices = outputDeviceLister.listOutputDevices()

        setOutputDevices(refreshedDevices)
        let didSelectionChange = syncSelectedOutputDeviceWithDefault(fallbackDeviceID: previousDeviceID)
        let refreshedDefaultDeviceID = refreshedDevices.first { $0.isSystemDefault }?.id

        return SystemOutputRefreshResult(
            previousDefaultDeviceID: previousDefaultDeviceID,
            currentDefaultDeviceID: refreshedDefaultDeviceID,
            didSelectionChange: didSelectionChange
        )
    }

    func refreshSystemOutputVolume() {
        guard let volumeScalar = systemVolumeReader.readCurrentOutputVolumeScalar() else {
            return
        }

        let refreshedVolume = (volumeScalar * AppConstants.volumeRange.upperBound)
            .clamped(to: AppConstants.volumeRange)

        applySystemVolume(refreshedVolume)
    }

    @discardableResult
    private func syncSelectedOutputDeviceWithDefault(fallbackDeviceID: OutputDeviceItem.ID?) -> Bool {
        let previousSelectedDeviceID = selectedOutputDeviceID

        if let defaultDevice = outputDevices.first(where: { $0.isSystemDefault }) {
            setSelectedOutputDeviceID(defaultDevice.id)
        } else if let fallbackDeviceID,
                  outputDevices.contains(where: { $0.id == fallbackDeviceID }) {
            setSelectedOutputDeviceID(fallbackDeviceID)
        } else {
            setSelectedOutputDeviceID(Self.preferredOutputDeviceID(in: outputDevices))
        }

        return selectedOutputDeviceID != previousSelectedDeviceID
    }

    private static func preferredOutputDeviceID(in devices: [OutputDeviceItem]) -> OutputDeviceItem.ID {
        devices.first { $0.isSystemDefault }?.id ?? devices.first?.id ?? "output:none"
    }

    private func applyRequestedSystemVolume(_ volume: Double) -> Bool {
        let clampedVolume = volume.clamped(to: AppConstants.volumeRange)
        let volumeScalar = clampedVolume / AppConstants.volumeRange.upperBound

        applySystemVolume(clampedVolume)

        let didSetVolume = systemVolumeController.setCurrentOutputVolumeScalar(volumeScalar)
        if didSetVolume {
            audioController.setSystemVolume(clampedVolume)
        }

        setSystemOutputVolumeWritable(didSetVolume)
        return didSetVolume
    }

    private var restoredSystemOutputVolume: Double {
        let restoredVolume = lastNonZeroSystemVolume.clamped(to: AppConstants.volumeRange)
        return restoredVolume > AppConstants.volumeRange.lowerBound
            ? restoredVolume
            : AppConstants.defaultSystemOutputRestoreVolume
    }

    private func applySystemVolume(_ volume: Double) {
        let clampedVolume = volume.clamped(to: AppConstants.volumeRange)

        notifyWillChange()
        systemVolume = clampedVolume
        isSystemOutputMuted = clampedVolume <= AppConstants.volumeRange.lowerBound

        if clampedVolume > AppConstants.volumeRange.lowerBound {
            rememberNonZeroSystemVolume(clampedVolume)
        }
    }

    private func rememberNonZeroSystemVolume(_ volume: Double) {
        let clampedVolume = volume.clamped(to: AppConstants.volumeRange)

        if clampedVolume > AppConstants.volumeRange.lowerBound {
            lastNonZeroSystemVolume = clampedVolume
        }
    }

    private func setOutputDevices(_ outputDevices: [OutputDeviceItem]) {
        notifyWillChange()
        self.outputDevices = outputDevices
    }

    private func setSelectedOutputDeviceID(_ selectedOutputDeviceID: OutputDeviceItem.ID) {
        let didChangeDevice = selectedOutputDeviceID != self.selectedOutputDeviceID
        notifyWillChange()
        self.selectedOutputDeviceID = selectedOutputDeviceID

        if didChangeDevice {
            // Writability is per-device; a new device is assumed writable until proven otherwise.
            setSystemOutputVolumeWritable(true)
        }
    }

    private func setSystemOutputVolumeWritable(_ isWritable: Bool) {
        guard isWritable != isSystemOutputVolumeWritable else {
            return
        }

        notifyWillChange()
        isSystemOutputVolumeWritable = isWritable
    }

    private func notifyWillChange() {
        onWillChange?()
    }
}
