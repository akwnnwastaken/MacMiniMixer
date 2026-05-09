import CoreAudio
import Foundation

struct CoreAudioSystemVolumeController: SystemVolumeControlling {
    func setCurrentOutputVolumeScalar(_ volumeScalar: Double) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else {
            return false
        }

        return setOutputVolumeScalar(volumeScalar, for: deviceID)
    }

    private func setOutputVolumeScalar(_ volumeScalar: Double, for deviceID: AudioDeviceID) -> Bool {
        let clampedScalar = Float32(volumeScalar.clamped(to: 0...1))
        let scopes = [
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyScopeGlobal
        ]

        for scope in scopes {
            if setVolumeScalar(
                clampedScalar,
                for: deviceID,
                scope: scope,
                element: kAudioObjectPropertyElementMain
            ) {
                return true
            }
        }

        for scope in scopes {
            let channelResults = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
                .map { element in
                    setVolumeScalar(
                        clampedScalar,
                        for: deviceID,
                        scope: scope,
                        element: element
                    )
                }

            if channelResults.contains(true) {
                return true
            }
        }

        return false
    }

    private func setVolumeScalar(
        _ volumeScalar: Float32,
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        guard settableStatus == noErr, isSettable.boolValue else {
            return false
        }

        var writableScalar = volumeScalar
        let dataSize = UInt32(MemoryLayout<Float32>.size)
        let setStatus = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            dataSize,
            &writableScalar
        )

        return setStatus == noErr
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
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
