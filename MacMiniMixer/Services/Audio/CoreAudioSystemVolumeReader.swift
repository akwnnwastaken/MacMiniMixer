import CoreAudio
import Foundation

struct CoreAudioSystemVolumeReader: SystemVolumeReading {
    func readCurrentOutputVolumeScalar() -> Double? {
        guard let deviceID = CoreAudioHelpers.defaultOutputDeviceID() else {
            return nil
        }

        return outputVolumeScalar(for: deviceID)
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
