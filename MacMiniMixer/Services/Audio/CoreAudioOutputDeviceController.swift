import CoreAudio
import Foundation

struct CoreAudioOutputDeviceController: OutputDeviceControlling {
    func setDefaultOutputDevice(_ device: OutputDeviceItem) -> Bool {
        guard let rawAudioDeviceID = device.audioDeviceID else {
            return false
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectHasProperty(systemObjectID, &address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        let settableStatus = AudioObjectIsPropertySettable(systemObjectID, &address, &isSettable)
        guard settableStatus == noErr, isSettable.boolValue else {
            return false
        }

        var audioDeviceID = AudioDeviceID(rawAudioDeviceID)
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            systemObjectID,
            &address,
            0,
            nil,
            dataSize,
            &audioDeviceID
        )

        return status == noErr
    }
}
