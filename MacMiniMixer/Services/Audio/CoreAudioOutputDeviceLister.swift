import CoreAudio
import Foundation

struct CoreAudioOutputDeviceLister: OutputDeviceListing {
    private static let hiddenVirtualDeviceNameKeywords = [
        "microsoft teams",
        "teams",
        "zoom",
        "blackhole",
        "background music",
        "loopback",
        "soundflower",
        "aggregate device",
        "multi output device"
    ]

    private let fallbackLister: OutputDeviceListing

    init(fallbackLister: OutputDeviceListing = MockOutputDeviceLister()) {
        self.fallbackLister = fallbackLister
    }

    func listOutputDevices() -> [OutputDeviceItem] {
        let devices = realOutputDevices()
        guard !devices.isEmpty else {
            return fallbackLister.listOutputDevices()
        }

        let userFacingDevices = devices.filter(isUserFacingOutputDevice)
        return userFacingDevices.isEmpty ? devices : userFacingDevices
    }

    private func realOutputDevices() -> [OutputDeviceItem] {
        let defaultDeviceID = defaultOutputDeviceID()
        var seenIDs = Set<OutputDeviceItem.ID>()

        return allAudioDeviceIDs()
            .filter { deviceID in
                deviceID == defaultDeviceID || hasOutputChannels(deviceID)
            }
            .compactMap { deviceID -> OutputDeviceItem? in
                guard let name = stringProperty(kAudioObjectPropertyName, for: deviceID) else {
                    return nil
                }

                let id = stableID(for: deviceID)
                guard seenIDs.insert(id).inserted else {
                    return nil
                }

                return OutputDeviceItem(
                    id: id,
                    name: name,
                    iconSystemName: iconSystemName(for: name),
                    isSystemDefault: defaultDeviceID == deviceID,
                    audioDeviceID: UInt32(deviceID)
                )
            }
            .sorted { first, second in
                if first.isSystemDefault != second.isSystemDefault {
                    return first.isSystemDefault
                }

                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            }
    }

    private func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )

        guard sizeStatus == noErr, dataSize > 0 else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        guard deviceCount > 0 else {
            return []
        }

        var deviceIDs = [AudioDeviceID](repeating: AudioDeviceID(), count: deviceCount)
        let dataStatus = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }

        guard dataStatus == noErr else {
            return []
        }

        return deviceIDs
    }

    private func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else {
            return false
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            bufferListPointer.deallocate()
        }

        let audioBufferList = bufferListPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let dataStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            audioBufferList
        )

        guard dataStatus == noErr else {
            return false
        }

        return UnsafeMutableAudioBufferListPointer(audioBufferList)
            .contains { $0.mNumberChannels > 0 }
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }

        return deviceID
    }

    private func stableID(for deviceID: AudioDeviceID) -> OutputDeviceItem.ID {
        if let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) {
            return "coreaudio:\(uid)"
        }

        return "coreaudio-device:\(deviceID)"
    }

    private func isUserFacingOutputDevice(_ device: OutputDeviceItem) -> Bool {
        if device.isSystemDefault {
            return true
        }

        let normalizedName = normalizedDeviceName(device.name)

        // This hides obvious app-created or virtual devices from the normal selector.
        // It is a user-facing simplification, not a complete Core Audio device taxonomy.
        return !Self.hiddenVirtualDeviceNameKeywords.contains { keyword in
            normalizedName.contains(keyword)
        }
    }

    private func normalizedDeviceName(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }

        guard status == noErr, let value else {
            return nil
        }

        let trimmedValue = (value.takeRetainedValue() as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func iconSystemName(for name: String) -> String {
        let lowercaseName = name.lowercased()

        if lowercaseName.contains("airpods") {
            return "airpodspro"
        }

        if lowercaseName.contains("hdmi") {
            return "cable.connector"
        }

        if lowercaseName.contains("display") || lowercaseName.contains("monitor") {
            return "display"
        }

        if lowercaseName.contains("speaker") {
            return "speaker.wave.2.fill"
        }

        return "hifispeaker.2"
    }
}
