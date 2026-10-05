import CoreAudio
import Foundation

/// Outcome of attempting to destroy a process tap during teardown. A `.failed` result means the
/// tap object may still exist inside coreaudiod — and since live taps carry `.mutedWhenTapped`,
/// that leaves the tapped apps muted system-wide until the app or coreaudiod restarts. Callers
/// must treat `.failed` as a strong, user-visible warning, never as a clean stop.
enum ProcessTapDestroyOutcome: Equatable {
    case succeeded(attempts: Int)
    case failed(lastStatus: OSStatus, attempts: Int)
}

/// Pure decision for whether a drained output queue should count as output starvation. Output
/// starvation only means an underrun once the session has actually received real (non-silent)
/// audio *and* the fresh output queue has had time to establish its playback cadence. Two false
/// positives are excluded:
///   - Before any real audio (`hasObservedRealAudioInput == false`): a drained queue is the
///     "waiting for app audio" idle state (e.g. starting Real Control on an app that is not
///     playing).
///   - During the brief startup window right after real audio first flows into a brand-new queue
///     (`hasCompletedStartupWarmup == false`): a fresh AudioQueue can drain once or twice while it
///     builds its buffer lead, even on a healthy route. This is the residual Starv seen after a
///     per-app Real restart (stop app, start the same app again while another stays active). It is
///     transient and clears itself; counting it would be a false alarm.
/// Once warmup completes, a real-audio drain increments normally, so steady-state starvation is
/// still reported.
enum ProcessTapStarvation {
    static func shouldCount(
        isStarted: Bool,
        poolIsFull: Bool,
        hasObservedRealAudioInput: Bool,
        hasCompletedStartupWarmup: Bool
    ) -> Bool {
        isStarted && poolIsFull && hasObservedRealAudioInput && hasCompletedStartupWarmup
    }
}

/// Pure teardown helpers, isolated from the Core Audio object state so they can be unit-tested
/// by injecting the destroy/sleep operations (no real Core Audio, no real sleeping in tests).
enum ProcessTapTeardown {
    /// Destroys a process tap, retrying on failure up to `maxAttempts` with `retryDelay` between
    /// attempts. Retrying matters because the first destroy can fail transiently while an output
    /// device route change is still settling; a later attempt then succeeds and releases the mute
    /// rather than leaking a muted tap. Retrying is always safe: once the tap is gone, a further
    /// destroy of the same id simply returns a (logged, benign) error.
    static func destroyProcessTapWithRetry(
        tapID: AudioObjectID,
        maxAttempts: Int,
        retryDelay: TimeInterval,
        destroy: (AudioObjectID) -> OSStatus,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> ProcessTapDestroyOutcome {
        let attempts = max(1, maxAttempts)
        var lastStatus: OSStatus = noErr

        for attempt in 1...attempts {
            let status = destroy(tapID)
            if status == noErr {
                return .succeeded(attempts: attempt)
            }

            lastStatus = status
            if attempt < attempts {
                sleep(max(0, retryDelay))
            }
        }

        return .failed(lastStatus: lastStatus, attempts: attempts)
    }
}

struct ProcessTapProcessEligibility: Equatable, Sendable {
    let isEligible: Bool
    let reason: String?

    static let eligible = ProcessTapProcessEligibility(isEligible: true, reason: nil)

    static func unavailable(_ reason: String) -> ProcessTapProcessEligibility {
        ProcessTapProcessEligibility(isEligible: false, reason: reason)
    }
}

enum ProcessTapPermissionMessage {
    static let permissionRequired = "System Audio Recording permission is required for Process Tap."
    static let permissionSettingsHint = "Enable it in System Settings → Privacy & Security → System Audio Recording."
    static let missingUsageDescription = "System Audio Recording permission is not configured."
    static let missingUsageDescriptionDetail = "NSAudioCaptureUsageDescription is missing from the app bundle."
    static let missingUsageDescriptionReason = "Missing audio capture usage description"

    static func isPermissionDeniedStatus(_ status: OSStatus) -> Bool {
        status == kAudioDevicePermissionsError
    }

    static func message(forCreateStatus status: OSStatus, fallback: String) -> String {
        isPermissionDeniedStatus(status) ? permissionRequired : fallback
    }

    static func detail(forCreateStatus status: OSStatus, fallback: String) -> String {
        isPermissionDeniedStatus(status) ? permissionSettingsHint : fallback
    }

    static func message(forEligibilityReason reason: String?, fallback: String) -> String {
        reason == missingUsageDescriptionReason ? missingUsageDescription : fallback
    }

    static func detail(forEligibilityReason reason: String?) -> String? {
        reason == missingUsageDescriptionReason ? missingUsageDescriptionDetail : reason
    }

    /// Opens the Privacy & Security pane where the user can grant System Audio Recording.
    /// We intentionally target the Privacy & Security root rather than a version-specific
    /// anchor: the "System Audio Recording" anchor is not reliably documented across macOS
    /// versions, and landing on the correct pane is the safe, non-surprising behavior.
    static let systemAudioRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy"
    )
}

/// One Core Audio process object (a client process connected to the HAL), as read from
/// `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyPID` /
/// `kAudioProcessPropertyBundleID` / `kAudioProcessPropertyIsRunningOutput`. Plain value so the
/// per-app matching (`AppAudioProcessMatcher`) can be unit-tested without Core Audio.
struct AudioProcessObjectInfo: Equatable, Sendable {
    let objectID: AudioObjectID
    let processIdentifier: Int32
    let bundleIdentifier: String?
    /// The process is running IO with at least one active output stream (i.e. playing right now).
    let isRunningOutput: Bool
}

/// Source of the HAL's audio-producing process list. Faked in tests.
protocol AudioProcessObjectListing: Sendable {
    func listAudioProcessObjects() -> [AudioProcessObjectInfo]
}

/// Production `AudioProcessObjectListing`: reads the HAL process object list on macOS 14.2+ (the
/// same availability gate as every Process Tap API here), and returns nothing on older systems.
struct CoreAudioProcessObjectLister: AudioProcessObjectListing {
    func listAudioProcessObjects() -> [AudioProcessObjectInfo] {
        guard #available(macOS 14.2, *) else {
            return []
        }

        return ProcessTapCoreAudio.audioProcessObjects()
    }
}

enum ProcessTapCoreAudio {
    static var isProcessTapAvailable: Bool {
        if #available(macOS 14.2, *) {
            return true
        }

        return false
    }

    static let unsupportedOSMessage = "Process Tap requires macOS 14.2 or later."

    static var hasAudioCaptureUsageDescription: Bool {
        guard let usageDescription = Bundle.main.object(
            forInfoDictionaryKey: "NSAudioCaptureUsageDescription"
        ) as? String else {
            return false
        }

        return !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @available(macOS 14.2, *)
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

    /// Every Core Audio process object the HAL currently knows (`kAudioHardwarePropertyProcessObjectList`,
    /// "client processes currently connected to the system"), with the pid, bundle id and
    /// running-output state of each. A process only appears here once it has used Core Audio, so an
    /// app that has not played anything since launch has no entry yet. Objects whose pid cannot be
    /// read are skipped. Synchronous HAL reads (one list read plus three small reads per object).
    @available(macOS 14.2, *)
    static func audioProcessObjects() -> [AudioProcessObjectInfo] {
        processObjectIDList().compactMap { objectID -> AudioProcessObjectInfo? in
            guard let processIdentifier = processPID(for: objectID), processIdentifier > 0 else {
                return nil
            }

            return AudioProcessObjectInfo(
                objectID: objectID,
                processIdentifier: Int32(processIdentifier),
                bundleIdentifier: stringProperty(kAudioProcessPropertyBundleID, for: objectID),
                isRunningOutput: (uint32Property(kAudioProcessPropertyIsRunningOutput, for: objectID) ?? 0) != 0
            )
        }
    }

    @available(macOS 14.2, *)
    private static func processObjectIDList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
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

        let objectCount = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        guard objectCount > 0 else {
            return []
        }

        var objectIDs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: objectCount)
        let dataStatus = objectIDs.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return kAudio_ParamError
            }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }

        guard dataStatus == noErr else {
            return []
        }

        // The list can shrink between the size and data reads; only the returned bytes are valid.
        let returnedCount = min(objectCount, Int(dataSize) / MemoryLayout<AudioObjectID>.stride)
        return objectIDs.prefix(returnedCount).filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    @available(macOS 14.2, *)
    private static func processPID(for processObjectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processIdentifier = pid_t(0)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)

        let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &dataSize, &processIdentifier)
        guard status == noErr else {
            return nil
        }

        return processIdentifier
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector, for objectID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    static func processTapEligibility(for processIdentifier: Int32?) -> ProcessTapProcessEligibility {
        guard #available(macOS 14.2, *) else {
            return .unavailable(unsupportedOSMessage)
        }

        guard hasAudioCaptureUsageDescription else {
            return .unavailable(ProcessTapPermissionMessage.missingUsageDescriptionReason)
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
        CoreAudioHelpers.defaultOutputDeviceID()
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
            if let scopedStreamDescription = ProcessTapCoreAudio.streamDescription(for: deviceID, scope: scope) {
                return scopedStreamDescription
            }
        }

        return nil
    }

    /// The device's stream format in exactly `scope` (no fallback to other scopes), or nil.
    static func streamDescription(
        for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
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

        return status == noErr ? streamDescription : nil
    }

    /// Number of streams the device exposes in `scope` (`kAudioDevicePropertyStreams`), or nil when
    /// it cannot be read.
    static func streamCount(for deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else {
            return nil
        }

        return Int(dataSize) / MemoryLayout<AudioStreamID>.size
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
    private let cleanupLock = NSLock()

    var tapUID: String? {
        guard #available(macOS 14.2, *) else {
            return nil
        }

        return ProcessTapCoreAudio.stringProperty(kAudioTapPropertyUID, for: tapID)
    }

    @available(macOS 14.2, *)
    func createProcessTap(
        processObjectID: AudioObjectID,
        name: String,
        muteBehavior: CATapMuteBehavior
    ) -> OSStatus {
        createProcessTap(
            processObjectIDs: [processObjectID],
            name: name,
            muteBehavior: muteBehavior
        )
    }

    /// Creates one stereo-mixdown tap over several process objects of the same app (e.g. a
    /// browser's main process plus its audio helper), so the app's whole output is captured — and,
    /// with `.mutedWhenTapped`, muted — by a single tap/aggregate/IOProc.
    @available(macOS 14.2, *)
    func createProcessTap(
        processObjectIDs: [AudioObjectID],
        name: String,
        muteBehavior: CATapMuteBehavior
    ) -> OSStatus {
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDescription.name = name
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = muteBehavior

        return AudioHardwareCreateProcessTap(tapDescription, &tapID)
    }

    @available(macOS 14.2, *)
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

    /// Apple's recommended tap playback structure: a private aggregate whose main (clock)
    /// sub-device is the output device and whose only sub-tap is the process tap, so a single
    /// IOProc reads the tap from its input and writes the device from its output on one clock.
    /// The tap-only `createPrivateAggregateDevice` stays for the AudioQueue path and the probes.
    @available(macOS 14.2, *)
    func createPrivateOutputAggregateDevice(
        name: String,
        uidPrefix: String,
        tapUID: String,
        outputDeviceUID: String,
        uniqueID: String = UUID().uuidString
    ) -> OSStatus {
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "\(uidPrefix).\(uniqueID)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputDeviceUID
                ]
            ],
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
        // Multiple stop paths can race. Claim cleanup under a lock, then perform
        // slower Core Audio teardown outside the lock.
        cleanupLock.lock()
        guard !didCleanUp else {
            cleanupLock.unlock()
            AppLogger.cleanup.info("Process Tap cleanup ignored duplicate request")
            return []
        }

        didCleanUp = true
        cleanupLock.unlock()

        AppLogger.cleanup.info("Process Tap cleanup claimed tapID=\(self.tapID, privacy: .public) aggregateID=\(self.aggregateDeviceID, privacy: .public) didStartIO=\(self.didStartIO, privacy: .public)")
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

        // Destroying the process tap is the step that releases `.mutedWhenTapped`, so it is the
        // one teardown failure that can leave system audio muted after the app is gone. It is
        // attempted unconditionally (even if the IO/aggregate steps above errored) and retried,
        // because a route-transition can make the first attempt fail transiently. A persisted tap
        // is escalated to `.fault` and flagged distinctly so it is never reported as a clean stop.
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            let tapID = self.tapID
            let destroyOutcome = ProcessTapTeardown.destroyProcessTapWithRetry(
                tapID: tapID,
                maxAttempts: AppConstants.processTapDestroyMaxAttempts,
                retryDelay: AppConstants.processTapDestroyRetryDelay,
                destroy: { AudioHardwareDestroyProcessTap($0) }
            )

            switch destroyOutcome {
            case .succeeded(let attempts):
                if attempts > 1 {
                    AppLogger.cleanup.warning("Process Tap destroy succeeded after \(attempts, privacy: .public) attempts tapID=\(tapID, privacy: .public)")
                }
            case .failed(let lastStatus, let attempts):
                let formattedStatus = statusFormatter(lastStatus)
                AppLogger.cleanup.fault("CRITICAL: Process Tap destroy failed after \(attempts, privacy: .public) attempts status=\(formattedStatus, privacy: .public) tapID=\(tapID, privacy: .public). Tapped apps may stay muted until MacMiniMixer or coreaudiod restarts.")
                cleanupErrors.append("destroy tap (audio may stay muted until restart) \(formattedStatus) after \(attempts) attempts")
            }
        }

        if cleanupErrors.isEmpty {
            AppLogger.cleanup.info("Process Tap cleanup finished")
        } else {
            AppLogger.cleanup.warning("Process Tap cleanup finished with warnings: \(cleanupErrors.joined(separator: ", "), privacy: .public)")
        }

        return cleanupErrors
    }
}
