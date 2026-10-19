import CoreAudio
import Foundation

struct CoreAudioSystemVolumeReader: SystemVolumeReading {
    func readCurrentOutputVolumeScalar() -> Double? {
        guard let deviceID = CoreAudioHelpers.defaultOutputDeviceID() else {
            return nil
        }

        return outputVolumeScalar(for: deviceID)
    }

    func readCurrentOutputMuted() -> Bool? {
        guard let deviceID = CoreAudioHelpers.defaultOutputDeviceID() else {
            return nil
        }

        // shortcut: main element only; add per-channel mute if a device turns up without one.
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeGlobal] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(deviceID, &address) else {
                continue
            }

            var muted = UInt32(0)
            var dataSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &muted) == noErr {
                return muted != 0
            }
        }

        return nil
    }

    private func outputVolumeScalar(for deviceID: AudioDeviceID) -> Double? {
        let scopes = [
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyScopeGlobal
        ]

        for scope in scopes {
            if let mainVolume = volumeScalar(
                for: deviceID,
                scope: scope,
                element: kAudioObjectPropertyElementMain
            ) {
                return mainVolume
            }
        }

        for scope in scopes {
            let channelVolumes = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
                .compactMap { element in
                    volumeScalar(for: deviceID, scope: scope, element: element)
                }

            if !channelVolumes.isEmpty {
                return channelVolumes.reduce(0, +) / Double(channelVolumes.count)
            }
        }

        return nil
    }

    private func volumeScalar(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var volume = Float32(0)
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &volume)

        guard status == noErr else {
            return nil
        }

        return Double(volume).clamped(to: 0...1)
    }
}
