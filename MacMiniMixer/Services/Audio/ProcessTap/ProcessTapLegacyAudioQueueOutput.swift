// LEGACY fallback: the AudioQueue live-output path (tap-only aggregate IOProc that hands each
// buffer to a separate AudioQueue on the output device's clock).
//
// The direct aggregate output engine (`ProcessTapLiveOutputMode.directAggregateOutput`) is the
// default live output and is proven on hardware. This path is kept only as a fallback for:
//   1. `MacMiniMixerLiveOutputMode=audioQueue` (explicit opt-out via UserDefaults),
//   2. output devices that expose input streams (headset/interface microphones), where the direct
//      aggregate's input list cannot be told apart from the tap stream,
//   3. any direct-setup failure (`ProcessTapDirectOutputStartAttempt.fallBackToAudioQueue`).
//
// It is scheduled for removal once the direct engine has had more real-hardware time. It is
// isolated in this one file so it can be deleted together with the `attemptAudioQueueStart` call in
// `CoreAudioProcessTapLiveController.attemptStart` and the `.audioQueue` backend case.

import AudioToolbox
import CoreAudio
import Darwin
import Foundation

extension CoreAudioProcessTapLiveController {
    /// Legacy live output (`ProcessTapLiveOutputMode.audioQueue`): tap-only aggregate IOProc that
    /// hands each buffer to a separate AudioQueue on the output device's clock.
    @available(macOS 14.2, *)
    func attemptAudioQueueStart(
        target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        processIdentifier: Int32,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) -> ProcessTapTestResult {
        let pid = pid_t(processIdentifier)
        AppLogger.processTap.info("Live control start requested app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) gain=\(gain.percentLabel, privacy: .public) output=audioQueue")
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

        let tapUID: String
        switch createLiveTap(target: target, processIdentifier: processIdentifier, resources: resources) {
        case .created(let createdTapUID):
            tapUID = createdTapUID
        case .failed(let result):
            return result
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
            // `observe` returns whether this callback had real (non-silent) audio, reusing the peak
            // it already computes — no extra scan — so the output queue can gate starvation on it.
            let hadRealAudioInput = accumulator.observe(inputData)
            outputQueue.enqueue(inputData, gain: gainState.scalar, hadRealAudioInput: hadRealAudioInput)
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
            output: .audioQueue(outputQueue),
            accumulator: accumulator,
            timingAccumulator: timingAccumulator,
            publishGate: ProcessTapDiagnosticsPublishGate(),
            onDiagnostics: onDiagnostics,
            onStopped: onStopped
        )

        guard activate(session, timeoutPolicy: timeoutPolicy) else {
            return ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Live control is already active",
                severity: .warning
            )
        }

        didActivateSession = true
        AppLogger.processTap.info("Live control started app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) outputDeviceID=\(startDefaultOutputDeviceID, privacy: .public) output=audioQueue")

        return ProcessTapTestResult(
            outcome: .liveControlStarted,
            message: "Live control started",
            detail: startDetail(gain: gain, timeoutPolicy: timeoutPolicy),
            severity: .info
        )
    }
}

final class ProcessTapLiveOutputQueue: @unchecked Sendable {
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
    /// playback was started — a public-API proxy for an AudioQueue underrun. Only counted once the
    /// session has observed real (non-silent) input (`hasObservedRealAudioInput`): a queue draining
    /// before any real audio is the "waiting for app audio" idle state, not an underrun. A genuine
    /// mid-stream input pause can still drain the queue, so a non-zero count means "the queue ran
    /// dry; investigate", not "definite glitch".
    private var outputStarvationCount = 0
    /// Latched true the first time a real (non-silent) input callback is enqueued. Gates
    /// `outputStarvationCount` so a silent/no-audio Real session does not log false starvation.
    private var hasObservedRealAudioInput = false
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
        hasObservedRealAudioInput = false
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

    func enqueue(_ inputData: UnsafePointer<AudioBufferList>, gain: Float, hadRealAudioInput: Bool) {
        lock.lock()
        // Latch under the lock we already hold here — no extra synchronisation on the callback.
        if hadRealAudioInput {
            hasObservedRealAudioInput = true
        }
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
        // the natural drain during teardown from counting; `hasObservedRealAudioInput` keeps a
        // silent/no-audio session from counting; and the startup-warmup gate keeps a brand-new
        // queue's first-cadence drain (the residual per-app-restart Starv) from counting until it
        // has enqueued enough buffers to be considered warmed up. `enqueuedBufferCount` is mutated
        // only under this same lock, so reading it here is consistent.
        if ProcessTapStarvation.shouldCount(
            isStarted: isStarted,
            poolIsFull: availableBuffers.count >= AppConstants.processTapReplayBufferCount,
            hasObservedRealAudioInput: hasObservedRealAudioInput,
            hasCompletedStartupWarmup: enqueuedBufferCount >= AppConstants.processTapReplayStartupWarmupBufferCount
        ) {
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
            outputStarvationCount: outputStarvationCount,
            // Real audio is flowing but the fresh queue is still establishing cadence: the neutral
            // "Starting audio…" window during which a transient drain is not counted as starvation.
            isWithinStartupWarmup: hasObservedRealAudioInput
                && enqueuedBufferCount < AppConstants.processTapReplayStartupWarmupBufferCount
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
