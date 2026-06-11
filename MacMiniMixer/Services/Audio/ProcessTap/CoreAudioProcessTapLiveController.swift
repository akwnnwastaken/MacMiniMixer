import AudioToolbox
import CoreAudio
import Darwin
import Foundation

final class CoreAudioProcessTapLiveController: ProcessTapLiveControlling, @unchecked Sendable {
    private let sessionLock = NSLock()
    private var activeSession: ProcessTapLiveSession?

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        await Task.detached(priority: .userInitiated) {
            self.startLiveControlSynchronously(
                for: target,
                gain: gain,
                timeoutPolicy: timeoutPolicy,
                onDiagnostics: onDiagnostics,
                onStopped: onStopped
            )
        }.value
    }

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        await Task.detached(priority: .userInitiated) {
            self.stopLiveControlNow(reason: reason) ?? ProcessTapTestResult(
                outcome: .liveControlNotActive,
                message: "Live control is not active",
                severity: .info
            )
        }.value
    }

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption) {
        sessionLock.lock()
        let session = activeSession
        sessionLock.unlock()

        session?.updateGain(gain)
    }

    @discardableResult
    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult? {
        sessionLock.lock()
        guard let session = activeSession else {
            sessionLock.unlock()
            return nil
        }

        activeSession = nil
        sessionLock.unlock()

        return stop(session: session, reason: reason)
    }

    private func startLiveControlSynchronously(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) -> ProcessTapTestResult {
        sessionLock.lock()
        let alreadyRunning = activeSession != nil
        sessionLock.unlock()

        guard !alreadyRunning else {
            return ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Live control is already active",
                severity: .warning
            )
        }

        guard let processIdentifier = target.processIdentifier, processIdentifier > 0 else {
            AppLogger.processTap.warning("Live control start rejected: invalid PID app=\(target.appName, privacy: .public) pid=\(target.processIdentifier ?? -1, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .invalidTarget,
                message: "Select a real running app",
                detail: "Fallback/mock app rows do not have a process identifier.",
                severity: .warning
            )
        }

        if #available(macOS 14.2, *) {
            guard ProcessTapCoreAudio.hasAudioCaptureUsageDescription else {
                AppLogger.processTap.warning("Live control start rejected: missing usage description app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
                return ProcessTapTestResult(
                    outcome: .missingUsageDescription,
                    message: ProcessTapPermissionMessage.missingUsageDescription,
                    detail: ProcessTapPermissionMessage.missingUsageDescriptionDetail,
                    severity: .warning
                )
            }

            return attemptStart(
                target: target,
                gain: gain,
                timeoutPolicy: timeoutPolicy,
                processIdentifier: processIdentifier,
                onDiagnostics: onDiagnostics,
                onStopped: onStopped
            )
        } else {
            AppLogger.processTap.warning("Live control start rejected: unsupported macOS app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .unsupportedOS,
                message: "Process Tap is not available on this macOS version",
                detail: "Live control requires macOS 14.2 or later.",
                severity: .warning
            )
        }
    }

    @available(macOS 14.2, *)
    private func attemptStart(
        target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        processIdentifier: Int32,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) -> ProcessTapTestResult {
        let pid = pid_t(processIdentifier)
        AppLogger.processTap.info("Live control start requested app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) gain=\(gain.percentLabel, privacy: .public)")
        let resources = ProcessTapResourceContext()
        var didActivateSession = false
        let outputQueue = ProcessTapLiveOutputQueue()
        let gainState = ProcessTapLiveGainState(gain: gain)

        func cleanupInactiveResources() {
            _ = resources.cleanup(
                afterDestroyingIOProc: outputQueue.stop,
                statusFormatter: { "\($0)" }
            )
        }

        defer {
            if !didActivateSession {
                cleanupInactiveResources()
            }
        }

        guard let startDefaultOutputDeviceID = ProcessTapCoreAudio.defaultOutputDeviceID() else {
            AppLogger.processTap.error("Live control setup failed: missing default output device app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Could not read default output device",
                severity: .warning
            )
        }

        guard let processObjectID = ProcessTapCoreAudio.processObjectID(for: pid) else {
            AppLogger.processTap.warning("Live control setup failed: Core Audio process not found app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .processNotFound,
                message: "Could not find Core Audio process",
                detail: "PID \(processIdentifier) did not map to a Core Audio process object.",
                severity: .warning
            )
        }

        let createStatus = resources.createProcessTap(
            processObjectID: processObjectID,
            name: "MacMiniMixer Live Control - \(target.appName)",
            muteBehavior: .mutedWhenTapped
        )
        guard createStatus == noErr, resources.tapID != kAudioObjectUnknown else {
            AppLogger.processTap.error("Live control setup failed: create tap status=\(ProcessTapCoreAudio.formatOSStatus(createStatus), privacy: .public) app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: ProcessTapPermissionMessage.isPermissionDeniedStatus(createStatus) ? .permissionDenied : .liveControlSetupFailed,
                message: ProcessTapPermissionMessage.message(
                    forCreateStatus: createStatus,
                    fallback: "Could not create live process tap"
                ),
                detail: ProcessTapPermissionMessage.detail(
                    forCreateStatus: createStatus,
                    fallback: "Create failed with \(ProcessTapCoreAudio.formatOSStatus(createStatus))."
                ),
                severity: .warning
            )
        }

        guard let tapUID = resources.tapUID else {
            AppLogger.processTap.error("Live control setup failed: missing tap UID app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Could not read process tap UID",
                severity: .warning
            )
        }

        let createAggregateStatus = resources.createPrivateAggregateDevice(
            name: "MacMiniMixer Process Tap Live Control",
            uidPrefix: "com.macminimixer.process-tap-live-control",
            tapUID: tapUID
        )

        guard createAggregateStatus == noErr, resources.aggregateDeviceID != kAudioObjectUnknown else {
            AppLogger.processTap.error("Live control setup failed: create aggregate status=\(ProcessTapCoreAudio.formatOSStatus(createAggregateStatus), privacy: .public) app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Could not create live tap device",
                detail: "Aggregate setup failed with \(ProcessTapCoreAudio.formatOSStatus(createAggregateStatus)).",
                severity: .warning
            )
        }

        guard let tapStreamDescription = ProcessTapCoreAudio.streamDescription(for: resources.aggregateDeviceID) else {
            AppLogger.processTap.error("Live control setup failed: could not read stream format app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Could not read live tap format",
                severity: .warning
            )
        }

        guard ProcessTapCoreAudio.isSupportedFloatPCMMonoOrStereo(tapStreamDescription) else {
            AppLogger.processTap.warning("Live control setup failed: unsupported stream format app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) channels=\(tapStreamDescription.mChannelsPerFrame, privacy: .public) bits=\(tapStreamDescription.mBitsPerChannel, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Unsupported live tap format",
                detail: "Live control currently handles 32-bit Float PCM mono/stereo only.",
                severity: .warning
            )
        }

        let sampleRate = tapStreamDescription.mSampleRate > 0
            ? tapStreamDescription.mSampleRate
            : AppConstants.processTapReplayFallbackSampleRate
        let outputFormat = ProcessTapLiveOutputFormat(
            sampleRate: sampleRate,
            channelCount: Int(tapStreamDescription.mChannelsPerFrame)
        )

        let outputStartStatus = outputQueue.start(format: outputFormat)
        guard outputStartStatus == noErr else {
            AppLogger.processTap.error("Live control setup failed: AudioQueue start status=\(ProcessTapCoreAudio.formatOSStatus(outputStartStatus), privacy: .public) app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Live playback setup failed",
                detail: "AudioQueue setup failed with \(ProcessTapCoreAudio.formatOSStatus(outputStartStatus)).",
                severity: .warning
            )
        }

        let accumulator = ProcessTapDiagnosticsAccumulator()
        let timingAccumulator = ProcessTapCallbackTimingAccumulator()
        let callbackQueue = DispatchQueue(label: "com.macminimixer.process-tap-live-control.callback")
        let ioBlock: AudioDeviceIOBlock = { _, inputData, inputTime, _, _ in
            timingAccumulator.record(hostTime: inputTime.pointee.mHostTime)
            accumulator.observe(inputData)
            outputQueue.enqueue(inputData, gain: gainState.scalar)
        }

        let createIOProcStatus = resources.createIOProc(
            queue: callbackQueue,
            block: ioBlock
        )

        guard createIOProcStatus == noErr, resources.ioProcID != nil else {
            AppLogger.processTap.error("Live control setup failed: create IOProc status=\(ProcessTapCoreAudio.formatOSStatus(createIOProcStatus), privacy: .public) app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Could not attach live callback",
                detail: "IOProc setup failed with \(ProcessTapCoreAudio.formatOSStatus(createIOProcStatus)).",
                severity: .warning
            )
        }

        let startStatus = resources.startIO()
        guard startStatus == noErr else {
            AppLogger.processTap.error("Live control setup failed: start IO status=\(ProcessTapCoreAudio.formatOSStatus(startStatus), privacy: .public) app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Could not start live control",
                detail: "Start failed with \(ProcessTapCoreAudio.formatOSStatus(startStatus)).",
                severity: .warning
            )
        }

        let session = ProcessTapLiveSession(
            pid: pid,
            targetName: target.appName,
            gainState: gainState,
            startDefaultOutputDeviceID: startDefaultOutputDeviceID,
            resources: resources,
            outputQueue: outputQueue,
            accumulator: accumulator,
            timingAccumulator: timingAccumulator,
            onDiagnostics: onDiagnostics,
            onStopped: onStopped
        )

        sessionLock.lock()
        guard activeSession == nil else {
            sessionLock.unlock()
            return ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Live control is already active",
                severity: .warning
            )
        }

        activeSession = session
        sessionLock.unlock()
        didActivateSession = true

        startTimers(for: session, timeoutPolicy: timeoutPolicy)
        onDiagnostics(session.diagnostics())
        AppLogger.processTap.info("Live control started app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) outputDeviceID=\(startDefaultOutputDeviceID, privacy: .public)")

        return ProcessTapTestResult(
            outcome: .liveControlStarted,
            message: "Live control started",
            detail: startDetail(gain: gain, timeoutPolicy: timeoutPolicy),
            severity: .info
        )
    }

    private func startTimers(for session: ProcessTapLiveSession, timeoutPolicy: ProcessTapLiveTimeoutPolicy) {
        let diagnosticsTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        diagnosticsTimer.schedule(deadline: .now(), repeating: AppConstants.processTapLevelMeterUpdateInterval)
        diagnosticsTimer.setEventHandler { [weak self, weak session] in
            guard let self, let session else {
                return
            }

            if !self.isProcessRunning(session.pid) {
                self.stop(session: session, reason: .targetAppExited)
                return
            }

            if ProcessTapCoreAudio.defaultOutputDeviceID() != session.startDefaultOutputDeviceID {
                self.stop(session: session, reason: .outputDeviceChanged)
                return
            }

            session.onDiagnostics(session.diagnostics())
        }

        let timeoutTimer: DispatchSourceTimer?
        switch timeoutPolicy {
        case .limited(let duration):
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + duration)
            timer.setEventHandler { [weak self, weak session] in
                guard let self, let session else {
                    return
                }

                self.stop(session: session, reason: .timedOut)
            }
            timeoutTimer = timer
        case .indefinite:
            timeoutTimer = nil
        }

        session.setTimers(diagnosticsTimer: diagnosticsTimer, timeoutTimer: timeoutTimer)
        diagnosticsTimer.resume()
        timeoutTimer?.resume()
    }

    private func startDetail(gain: ProcessTapReplayGainOption, timeoutPolicy: ProcessTapLiveTimeoutPolicy) -> String {
        switch timeoutPolicy {
        case .limited(let duration):
            return "Gain \(gain.percentLabel). Auto-stops after \(Int(duration))s."
        case .indefinite:
            return "Gain \(gain.percentLabel)."
        }
    }

    @discardableResult
    private func stop(session: ProcessTapLiveSession, reason: ProcessTapLiveStopReason) -> ProcessTapTestResult {
        guard session.beginStopping() else {
            AppLogger.processTap.info("Live control stop ignored: already stopping app=\(session.targetName, privacy: .public) pid=\(session.pid, privacy: .public) reason=\(String(describing: reason), privacy: .public)")
            return ProcessTapTestResult(
                outcome: .liveControlStopped,
                message: "Live control is already stopping",
                severity: .info
            )
        }

        sessionLock.lock()
        if activeSession === session {
            activeSession = nil
        }
        sessionLock.unlock()

        AppLogger.processTap.info("Live control stop requested app=\(session.targetName, privacy: .public) pid=\(session.pid, privacy: .public) reason=\(String(describing: reason), privacy: .public)")
        let diagnostics = session.diagnostics()
        let cleanupErrors = session.cleanup()
        let result = liveStopResult(
            reason: reason,
            targetName: session.targetName,
            diagnostics: diagnostics,
            cleanupErrors: cleanupErrors
        )

        session.onStopped(result, diagnostics)
        if cleanupErrors.isEmpty {
            AppLogger.processTap.info("Live control stopped app=\(session.targetName, privacy: .public) pid=\(session.pid, privacy: .public) reason=\(String(describing: reason), privacy: .public)")
        } else {
            AppLogger.processTap.warning("Live control stopped with cleanup warnings app=\(session.targetName, privacy: .public) pid=\(session.pid, privacy: .public) warnings=\(cleanupErrors.joined(separator: ", "), privacy: .public)")
        }
        return result
    }

    private func isProcessRunning(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func liveStopResult(
        reason: ProcessTapLiveStopReason,
        targetName: String,
        diagnostics: ProcessTapLiveDiagnostics,
        cleanupErrors: [String]
    ) -> ProcessTapTestResult {
        if !cleanupErrors.isEmpty {
            return ProcessTapTestResult(
                outcome: .tapCleanupFailed,
                message: "Live control cleanup warning",
                detail: cleanupErrors.joined(separator: ", "),
                severity: .warning
            )
        }

        let detail = "Gain \(diagnostics.selectedGain.percentLabel), maxGap \(String(format: "%.1f", diagnostics.maxCallbackGapMilliseconds))ms, late \(diagnostics.lateCallbackCount), starv \(diagnostics.outputStarvationCount), \(diagnostics.callbackCount) cb, peak \(formatLevel(diagnostics.peakLevel)), RMS \(formatLevel(diagnostics.rmsLevel)), queued \(diagnostics.enqueuedBufferCount), drops \(diagnostics.droppedBufferCount), fail \(diagnostics.totalFailureCount)."

        switch reason {
        case .userStopped:
            return ProcessTapTestResult(
                outcome: .liveControlStopped,
                message: "Live control stopped",
                detail: detail,
                severity: .info
            )
        case .timedOut:
            return ProcessTapTestResult(
                outcome: .liveControlTimedOut,
                message: "Live control stopped: timeout",
                detail: detail,
                severity: .warning
            )
        case .outputDeviceChanged:
            return ProcessTapTestResult(
                outcome: .liveControlOutputChanged,
                message: "Live control stopped: output device changed",
                detail: detail,
                severity: .warning
            )
        case .targetAppExited:
            return ProcessTapTestResult(
                outcome: .liveControlAppExited,
                message: "Live control stopped: app exited",
                detail: detail,
                severity: .warning
            )
        case .appTerminating:
            return ProcessTapTestResult(
                outcome: .liveControlStopped,
                message: "Live control stopped for quit",
                detail: detail,
                severity: .info
            )
        case .systemSleep:
            return ProcessTapTestResult(
                outcome: .liveControlStopped,
                message: "Live control stopped: system sleep",
                detail: detail,
                severity: .info
            )
        case .setupFailed:
            return ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Live control setup failed",
                detail: detail,
                severity: .warning
            )
        }
    }

    private func formatLevel(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

}

private final class ProcessTapLiveSession: @unchecked Sendable {
    let pid: pid_t
    let targetName: String
    let gainState: ProcessTapLiveGainState
    let startDefaultOutputDeviceID: AudioDeviceID
    let resources: ProcessTapResourceContext
    let outputQueue: ProcessTapLiveOutputQueue
    let accumulator: ProcessTapDiagnosticsAccumulator
    let timingAccumulator: ProcessTapCallbackTimingAccumulator
    let onDiagnostics: @Sendable (ProcessTapLiveDiagnostics) -> Void
    let onStopped: @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void

    private let cleanupLock = NSLock()
    private var didBeginStop = false
    private var didCleanUp = false
    private var diagnosticsTimer: DispatchSourceTimer?
    private var timeoutTimer: DispatchSourceTimer?

    init(
        pid: pid_t,
        targetName: String,
        gainState: ProcessTapLiveGainState,
        startDefaultOutputDeviceID: AudioDeviceID,
        resources: ProcessTapResourceContext,
        outputQueue: ProcessTapLiveOutputQueue,
        accumulator: ProcessTapDiagnosticsAccumulator,
        timingAccumulator: ProcessTapCallbackTimingAccumulator,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) {
        self.pid = pid
        self.targetName = targetName
        self.gainState = gainState
        self.startDefaultOutputDeviceID = startDefaultOutputDeviceID
        self.resources = resources
        self.outputQueue = outputQueue
        self.accumulator = accumulator
        self.timingAccumulator = timingAccumulator
        self.onDiagnostics = onDiagnostics
        self.onStopped = onStopped
    }

    func beginStopping() -> Bool {
        cleanupLock.lock()
        defer {
            cleanupLock.unlock()
        }

        guard !didBeginStop else {
            return false
        }

        didBeginStop = true
        return true
    }

    func setTimers(diagnosticsTimer: DispatchSourceTimer, timeoutTimer: DispatchSourceTimer?) {
        cleanupLock.lock()
        self.diagnosticsTimer = diagnosticsTimer
        self.timeoutTimer = timeoutTimer
        cleanupLock.unlock()
    }

    func cleanup() -> [String] {
        cleanupLock.lock()
        guard !didCleanUp else {
            cleanupLock.unlock()
            return []
        }

        didCleanUp = true
        let diagnosticsTimer = diagnosticsTimer
        let timeoutTimer = timeoutTimer
        self.diagnosticsTimer = nil
        self.timeoutTimer = nil
        cleanupLock.unlock()

        diagnosticsTimer?.cancel()
        timeoutTimer?.cancel()

        return resources.cleanup(
            beforeStoppingIO: {
                self.outputQueue.beginFadeOut()
                Thread.sleep(forTimeInterval: AppConstants.processTapLiveFadeOutDuration)
                self.outputQueue.stop()
            },
            statusFormatter: { "\($0)" }
        )
    }

    func updateGain(_ gain: ProcessTapReplayGainOption) {
        gainState.update(gain)
    }

    func diagnostics() -> ProcessTapLiveDiagnostics {
        let inputSnapshot = accumulator.snapshot()
        let outputSnapshot = outputQueue.snapshot()
        let timingSnapshot = timingAccumulator.snapshot()

        return ProcessTapLiveDiagnostics(
            selectedGain: gainState.option,
            callbackCount: inputSnapshot.callbackCount,
            peakLevel: inputSnapshot.peakLevel,
            rmsLevel: inputSnapshot.rmsLevel,
            enqueuedBufferCount: outputSnapshot.enqueuedBufferCount,
            droppedBufferCount: outputSnapshot.droppedBufferCount,
            enqueueFailureCount: outputSnapshot.enqueueFailureCount,
            copyFailureCount: outputSnapshot.copyFailureCount,
            maxCallbackGapMilliseconds: timingSnapshot.maxCallbackGapMilliseconds,
            lateCallbackCount: timingSnapshot.lateCallbackCount,
            outputStarvationCount: outputSnapshot.outputStarvationCount
        )
    }
}

private final class ProcessTapLiveGainState: @unchecked Sendable {
    private let lock = NSLock()
    private var gain: ProcessTapReplayGainOption

    init(gain: ProcessTapReplayGainOption) {
        self.gain = gain
    }

    var scalar: Float {
        lock.lock()
        defer {
            lock.unlock()
        }

        return gain.scalar
    }

    var option: ProcessTapReplayGainOption {
        lock.lock()
        defer {
            lock.unlock()
        }

        return gain
    }

    func update(_ gain: ProcessTapReplayGainOption) {
        lock.lock()
        self.gain = gain
        lock.unlock()
    }
}

private struct ProcessTapLiveOutputFormat {
    let sampleRate: Double
    let channelCount: Int

    var audioStreamBasicDescription: AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float32>.stride)
        let channels = UInt32(channelCount)

        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerSample * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}

private final class ProcessTapLiveOutputQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let gainRampLock = NSLock()
    private var queue: AudioQueueRef?
    private var availableBuffers: [AudioQueueBufferRef] = []
    private var outputFormat: ProcessTapLiveOutputFormat?
    private var isStarted = false
    private var isStopped = false
    private var enqueuedBufferCount = 0
    private var droppedBufferCount = 0
    private var enqueueFailureCount = 0
    private var copyFailureCount = 0
    /// Diagnostic-only: counts times the queue fully drained (every buffer back in the pool) while
    /// playback was started — a public-API proxy for an AudioQueue underrun. Note the false-positive
    /// risk: a genuine input pause (no new audio) also drains the queue, so a non-zero count means
    /// "the queue ran dry; investigate", not "definite glitch".
    private var outputStarvationCount = 0
    private var gainRamp = ProcessTapLiveGainRamp()

    func start(format: ProcessTapLiveOutputFormat) -> OSStatus {
        lock.lock()
        outputFormat = format
        isStopped = false
        isStarted = false
        enqueuedBufferCount = 0
        droppedBufferCount = 0
        enqueueFailureCount = 0
        copyFailureCount = 0
        outputStarvationCount = 0
        lock.unlock()

        gainRampLock.lock()
        gainRamp = ProcessTapLiveGainRamp(format: format)
        gainRampLock.unlock()

        var streamDescription = format.audioStreamBasicDescription
        var newQueue: AudioQueueRef?
        let createStatus = AudioQueueNewOutput(
            &streamDescription,
            processTapLiveAudioQueueCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil,
            0,
            &newQueue
        )

        guard createStatus == noErr, let newQueue else {
            return createStatus
        }

        var allocatedBuffers: [AudioQueueBufferRef] = []
        for _ in 0..<AppConstants.processTapReplayBufferCount {
            var buffer: AudioQueueBufferRef?
            let allocateStatus = AudioQueueAllocateBuffer(
                newQueue,
                AppConstants.processTapReplayBufferByteSize,
                &buffer
            )

            guard allocateStatus == noErr, let buffer else {
                AudioQueueDispose(newQueue, true)
                return allocateStatus
            }

            allocatedBuffers.append(buffer)
        }

        lock.lock()
        queue = newQueue
        availableBuffers = allocatedBuffers
        lock.unlock()

        return noErr
    }

    func enqueue(_ inputData: UnsafePointer<AudioBufferList>, gain: Float) {
        lock.lock()
        guard !isStopped,
              let queue,
              let outputFormat,
              let buffer = availableBuffers.popLast() else {
            droppedBufferCount += 1
            lock.unlock()
            return
        }
        lock.unlock()

        guard copy(inputData, into: buffer, format: outputFormat, gain: gain) else {
            incrementCopyFailureCount()
            recycle(buffer)
            return
        }

        let enqueueStatus = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        if enqueueStatus == noErr {
            recordSuccessfulEnqueueAndStartIfReady(queue)
        } else {
            incrementEnqueueFailureCount()
            recycle(buffer)
        }
    }

    func beginFadeOut() {
        gainRampLock.lock()
        gainRamp.beginFadeOut()
        gainRampLock.unlock()
    }

    func recycle(_ buffer: AudioQueueBufferRef) {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }

        availableBuffers.append(buffer)
        // If playback has started and every buffer is back in the pool, nothing is queued ahead of
        // the device — the queue has drained (underrun proxy). The `!isStopped` guard above keeps
        // the natural drain during teardown from counting.
        if isStarted && availableBuffers.count >= AppConstants.processTapReplayBufferCount {
            outputStarvationCount += 1
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }

        isStopped = true
        let queueToStop = queue
        let wasStarted = isStarted
        queue = nil
        availableBuffers.removeAll()
        lock.unlock()

        guard let queueToStop else {
            return
        }

        if wasStarted {
            AudioQueueStop(queueToStop, true)
        }
        AudioQueueDispose(queueToStop, true)
    }

    func snapshot() -> ProcessTapLiveOutputSnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }

        return ProcessTapLiveOutputSnapshot(
            enqueuedBufferCount: enqueuedBufferCount,
            droppedBufferCount: droppedBufferCount,
            enqueueFailureCount: enqueueFailureCount,
            copyFailureCount: copyFailureCount,
            outputStarvationCount: outputStarvationCount
        )
    }

    private func recordSuccessfulEnqueueAndStartIfReady(_ queue: AudioQueueRef) {
        var shouldStart = false

        lock.lock()
        enqueuedBufferCount += 1
        if !isStarted && enqueuedBufferCount >= AppConstants.processTapLivePrimingBufferCount {
            isStarted = true
            shouldStart = true
        }
        lock.unlock()

        guard shouldStart else {
            return
        }

        let startStatus = AudioQueueStart(queue, nil)
        if startStatus != noErr {
            incrementEnqueueFailureCount()
        }
    }

    private func incrementEnqueueFailureCount() {
        lock.lock()
        enqueueFailureCount += 1
        lock.unlock()
    }

    private func incrementCopyFailureCount() {
        lock.lock()
        copyFailureCount += 1
        lock.unlock()
    }

    private func copy(
        _ inputData: UnsafePointer<AudioBufferList>,
        into outputBuffer: AudioQueueBufferRef,
        format: ProcessTapLiveOutputFormat,
        gain: Float
    ) -> Bool {
        let outputData = outputBuffer.pointee.mAudioData
        let outputSamples = outputData.assumingMemoryBound(to: Float32.self)

        gainRampLock.lock()
        defer {
            gainRampLock.unlock()
        }

        var gainProvider = ProcessTapLiveFrameGainProvider(
            gainRamp: gainRamp,
            targetGain: gain
        )
        guard let result = ProcessTapOutputBufferCopier.copy(
            inputData,
            into: outputSamples,
            outputByteCapacity: outputBuffer.pointee.mAudioDataBytesCapacity,
            outputChannelCount: format.channelCount,
            gainProvider: &gainProvider
        ) else {
            return false
        }

        gainRamp = gainProvider.gainRamp
        outputBuffer.pointee.mAudioDataByteSize = result.outputByteSize
        return true
    }
}

private struct ProcessTapLiveFrameGainProvider: ProcessTapOutputFrameGainProviding {
    var gainRamp: ProcessTapLiveGainRamp
    let targetGain: Float

    mutating func gain(forFrame frame: Int) -> Float {
        gainRamp.nextGain(targetGain: targetGain)
    }
}

private struct ProcessTapLiveGainRamp {
    private var fadeInRemainingFrames = 0
    private var fadeInTotalFrames = 1
    private var fadeOutRemainingFrames = 0
    private var fadeOutTotalFrames = 1
    private var fadeOutStartGain: Float = 0
    private var currentGain: Float = 0
    private var isFadingOut = false

    init() {}

    init(format: ProcessTapLiveOutputFormat) {
        let sampleRate = format.sampleRate > 0
            ? format.sampleRate
            : AppConstants.processTapReplayFallbackSampleRate

        fadeInTotalFrames = Self.frameCount(
            duration: AppConstants.processTapLiveFadeInDuration,
            sampleRate: sampleRate
        )
        fadeInRemainingFrames = fadeInTotalFrames
        fadeOutTotalFrames = Self.frameCount(
            duration: AppConstants.processTapLiveFadeOutDuration,
            sampleRate: sampleRate
        )
    }

    mutating func beginFadeOut() {
        guard !isFadingOut else {
            return
        }

        isFadingOut = true
        fadeOutStartGain = currentGain
        fadeOutRemainingFrames = fadeOutTotalFrames
        fadeInRemainingFrames = 0
    }

    mutating func nextGain(targetGain: Float) -> Float {
        let sanitizedTargetGain = max(0, targetGain)

        if isFadingOut {
            guard fadeOutRemainingFrames > 0 else {
                currentGain = 0
                return 0
            }

            let completedFrames = fadeOutTotalFrames - fadeOutRemainingFrames + 1
            let fadeFraction = min(1, Float(completedFrames) / Float(max(1, fadeOutTotalFrames)))
            currentGain = fadeOutStartGain * max(0, 1 - fadeFraction)
            fadeOutRemainingFrames -= 1
            return currentGain
        }

        guard fadeInRemainingFrames > 0 else {
            currentGain = sanitizedTargetGain
            return sanitizedTargetGain
        }

        let completedFrames = fadeInTotalFrames - fadeInRemainingFrames + 1
        let fadeFraction = min(1, Float(completedFrames) / Float(max(1, fadeInTotalFrames)))
        currentGain = sanitizedTargetGain * fadeFraction
        fadeInRemainingFrames -= 1
        return currentGain
    }

    private static func frameCount(duration: TimeInterval, sampleRate: Double) -> Int {
        max(1, Int((duration * sampleRate).rounded()))
    }
}

private func processTapLiveAudioQueueCallback(
    userData: UnsafeMutableRawPointer?,
    queue: AudioQueueRef,
    buffer: AudioQueueBufferRef
) {
    guard let userData else {
        return
    }

    let outputQueue = Unmanaged<ProcessTapLiveOutputQueue>.fromOpaque(userData).takeUnretainedValue()
    outputQueue.recycle(buffer)
}

private struct ProcessTapLiveOutputSnapshot {
    let enqueuedBufferCount: Int
    let droppedBufferCount: Int
    let enqueueFailureCount: Int
    let copyFailureCount: Int
    let outputStarvationCount: Int
}
