import CoreAudio
import Foundation

struct ProcessTapProcessEligibility: Equatable, Sendable {
    let isEligible: Bool
    let reason: String?

    static let eligible = ProcessTapProcessEligibility(isEligible: true, reason: nil)

    static func unavailable(_ reason: String) -> ProcessTapProcessEligibility {
        ProcessTapProcessEligibility(isEligible: false, reason: reason)
    }
}

enum ProcessTapCoreAudio {
    static var hasAudioCaptureUsageDescription: Bool {
        guard let usageDescription = Bundle.main.object(
            forInfoDictionaryKey: "NSAudioCaptureUsageDescription"
        ) as? String else {
            return false
        }

        return !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var mutablePID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        let status = withUnsafePointer(to: &mutablePID) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                pidPointer,
                &dataSize,
                &processObjectID
            )
        }

        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            return nil
        }

        return processObjectID
    }

    static func processTapEligibility(for processIdentifier: Int32?) -> ProcessTapProcessEligibility {
        guard #available(macOS 14.2, *) else {
            return .unavailable("Unsupported macOS")
        }

        guard hasAudioCaptureUsageDescription else {
            return .unavailable("Missing audio capture usage description")
        }

        guard let processIdentifier, processIdentifier > 0 else {
            return .unavailable("Invalid process")
        }

        // Browser and web-app audio may be rendered by helper/content processes,
        // so the visible app PID may not be a Core Audio tap target.
        guard processObjectID(for: pid_t(processIdentifier)) != nil else {
            return .unavailable("Core Audio process unavailable")
        }

        return .eligible
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
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

    static func stringProperty(_ selector: AudioObjectPropertySelector, for objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
        }

        guard status == noErr, let value else {
            return nil
        }

        let trimmedValue = (value.takeRetainedValue() as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    static func nominalSampleRate(for deviceID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)
        guard status == noErr, sampleRate > 0 else {
            return nil
        }

        return sampleRate
    }

    static func streamDescription(for deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
        let scopes = [
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyScopeInput,
            kAudioObjectPropertyScopeGlobal
        ]

        for scope in scopes {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )

            guard AudioObjectHasProperty(deviceID, &address) else {
                continue
            }

            var streamDescription = AudioStreamBasicDescription()
            var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &streamDescription
            )

            if status == noErr {
                return streamDescription
            }
        }

        return nil
    }

    static func isSupportedFloatPCMMonoOrStereo(_ streamDescription: AudioStreamBasicDescription) -> Bool {
        let channelCount = streamDescription.mChannelsPerFrame
        let isFloat = streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0

        return streamDescription.mFormatID == kAudioFormatLinearPCM
            && isFloat
            && streamDescription.mBitsPerChannel == 32
            && channelCount >= 1
            && channelCount <= 2
    }

    static func formatOSStatus(_ status: OSStatus) -> String {
        "\(status) (\(fourCharacterCode(for: status)))"
    }

    private static func fourCharacterCode(for status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let characters = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]

        guard characters.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return "not printable"
        }

        return String(decoding: characters, as: UTF8.self)
    }
}

final class ProcessTapResourceContext {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private(set) var ioProcID: AudioDeviceIOProcID?

    private var didStartIO = false
    private var didCleanUp = false

    var tapUID: String? {
        ProcessTapCoreAudio.stringProperty(kAudioTapPropertyUID, for: tapID)
    }

    func createProcessTap(
        processObjectID: AudioObjectID,
        name: String,
        muteBehavior: CATapMuteBehavior
    ) -> OSStatus {
        guard #available(macOS 14.2, *) else {
            return kAudioHardwareUnsupportedOperationError
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDescription.name = name
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = muteBehavior

        return AudioHardwareCreateProcessTap(tapDescription, &tapID)
    }

    func createPrivateAggregateDevice(
        name: String,
        uidPrefix: String,
        tapUID: String,
        uniqueID: String = UUID().uuidString
    ) -> OSStatus {
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "\(uidPrefix).\(uniqueID)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        return AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        )
    }

    func createIOProc(
        queue: DispatchQueue,
        block: @escaping AudioDeviceIOBlock
    ) -> OSStatus {
        AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDeviceID,
            queue,
            block
        )
    }

    func startIO() -> OSStatus {
        let status = AudioDeviceStart(aggregateDeviceID, ioProcID)
        if status == noErr {
            didStartIO = true
        }
        return status
    }

    func cleanup(
        beforeStoppingIO: (() -> Void)? = nil,
        afterDestroyingIOProc: (() -> Void)? = nil,
        statusFormatter: (OSStatus) -> String = ProcessTapCoreAudio.formatOSStatus
    ) -> [String] {
        guard !didCleanUp else {
            return []
        }

        didCleanUp = true
        var cleanupErrors: [String] = []

        beforeStoppingIO?()

        if didStartIO {
            let stopStatus = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if stopStatus != noErr {
                cleanupErrors.append("stop \(statusFormatter(stopStatus))")
            }
        }

        if let ioProcID {
            let destroyIOProcStatus = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            if destroyIOProcStatus != noErr {
                cleanupErrors.append("destroy IOProc \(statusFormatter(destroyIOProcStatus))")
            }
        }

        afterDestroyingIOProc?()

        if aggregateDeviceID != kAudioObjectUnknown {
            let destroyAggregateStatus = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if destroyAggregateStatus != noErr {
                cleanupErrors.append("destroy aggregate \(statusFormatter(destroyAggregateStatus))")
            }
        }

        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            let destroyTapStatus = AudioHardwareDestroyProcessTap(tapID)
            if destroyTapStatus != noErr {
                cleanupErrors.append("destroy tap \(statusFormatter(destroyTapStatus))")
            }
        }

        return cleanupErrors
    }
}
