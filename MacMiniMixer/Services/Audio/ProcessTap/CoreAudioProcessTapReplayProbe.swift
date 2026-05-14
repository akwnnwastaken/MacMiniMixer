import AudioToolbox
import CoreAudio
import Darwin
import Foundation

final class CoreAudioProcessTapReplayProbe: ProcessTapReplayProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = false
    private var requestedStopReason: ProcessTapReplayProbeStopReason?

    func runReplayProbe(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapReplayResult {
        await Task.detached(priority: .userInitiated) {
            self.runReplayProbeSynchronously(for: target, gain: gain, onProgress: onProgress)
        }.value
    }

    func stopCurrentReplayProbe(reason: ProcessTapReplayProbeStopReason) {
        lock.lock()
        if isRunning, requestedStopReason == nil {
            requestedStopReason = reason
        }
        lock.unlock()
    }

    private func runReplayProbeSynchronously(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) -> ProcessTapReplayResult {
        guard beginReplayProbe() else {
            return ProcessTapReplayResult(
                outcome: .tapSetupFailed,
                message: "Replay probe is already running",
                severity: .warning
            )
        }

        defer {
            finishReplayProbe()
        }

        guard let processIdentifier = target.processIdentifier, processIdentifier > 0 else {
            return ProcessTapReplayResult(
                outcome: .invalidTarget,
                message: "Select a real running app",
                detail: "Fallback/mock app rows do not have a process identifier.",
                severity: .warning
            )
        }

        if #available(macOS 14.2, *) {
            guard ProcessTapCoreAudio.hasAudioCaptureUsageDescription else {
                return ProcessTapReplayResult(
                    outcome: .missingUsageDescription,
                    message: "Missing audio capture usage description",
                    detail: "Add NSAudioCaptureUsageDescription before real tap setup.",
                    severity: .warning
                )
            }

            return attemptReplayProbe(
                for: target,
                gain: gain,
                processIdentifier: processIdentifier,
                onProgress: onProgress
            )
        } else {
            return ProcessTapReplayResult(
                outcome: .unsupportedOS,
                message: "Process Tap is not available on this macOS version",
                detail: "Replay probing requires macOS 14.2 or later.",
                severity: .warning
            )
        }
    }

    private func beginReplayProbe() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !isRunning else {
            return false
        }

        isRunning = true
        requestedStopReason = nil
        return true
    }

    private func finishReplayProbe() {
        lock.lock()
        isRunning = false
        requestedStopReason = nil
        lock.unlock()
    }

    private func currentStopReason() -> ProcessTapReplayProbeStopReason? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return requestedStopReason
    }

    @available(macOS 14.2, *)
    private func attemptReplayProbe(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        processIdentifier: Int32,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) -> ProcessTapReplayResult {
        let pid = pid_t(processIdentifier)
        let resources = ProcessTapResourceContext()
        let replayOutput = ProcessTapReplayOutputQueue()

        defer {
            _ = resources.cleanup(beforeStoppingIO: replayOutput.stop)
        }

        guard let processObjectID = ProcessTapCoreAudio.processObjectID(for: pid) else {
            return ProcessTapReplayResult(
                outcome: .processNotFound,
                message: "Could not find Core Audio process",
                detail: "PID \(processIdentifier) did not map to a Core Audio process object.",
                severity: .warning
            )
        }

        let createStatus = resources.createProcessTap(
            processObjectID: processObjectID,
            name: "MacMiniMixer Replay Probe - \(target.appName)",
            muteBehavior: .mutedWhenTapped
        )
        guard createStatus == noErr, resources.tapID != kAudioObjectUnknown else {
            return ProcessTapReplayResult(
                outcome: createStatus == kAudioDevicePermissionsError ? .permissionDenied : .tapSetupFailed,
                message: createStatus == kAudioDevicePermissionsError
                    ? "Audio capture permission was denied"
                    : "Could not create replay process tap",
                detail: "Create failed with \(ProcessTapCoreAudio.formatOSStatus(createStatus)). No audio was replayed or saved.",
                severity: .warning
            )
        }

        guard let tapUID = resources.tapUID else {
            return ProcessTapReplayResult(
                outcome: .tapSetupFailed,
                message: "Could not read process tap UID",
                detail: "The tap was created, but replay probing could not attach it to a temporary aggregate device.",
                severity: .warning
            )
        }

        let createAggregateStatus = resources.createPrivateAggregateDevice(
            name: "MacMiniMixer Process Tap Replay Probe",
            uidPrefix: "com.macminimixer.process-tap-replay-probe",
            tapUID: tapUID
        )

        guard createAggregateStatus == noErr, resources.aggregateDeviceID != kAudioObjectUnknown else {
            return ProcessTapReplayResult(
                outcome: .tapSetupFailed,
                message: "Could not create replay tap device",
                detail: "Aggregate setup failed with \(ProcessTapCoreAudio.formatOSStatus(createAggregateStatus)). No audio was replayed or saved.",
                severity: .warning
            )
        }

        guard let tapStreamDescription = ProcessTapCoreAudio.streamDescription(for: resources.aggregateDeviceID) else {
            return ProcessTapReplayResult(
                outcome: .playbackSetupFailed,
                message: "Playback setup failed",
                detail: "Could not read the tap stream format. No audio was replayed or saved.",
                severity: .warning
            )
        }

        guard ProcessTapCoreAudio.isSupportedFloatPCMMonoOrStereo(tapStreamDescription) else {
            return ProcessTapReplayResult(
                outcome: .playbackSetupFailed,
                message: "Playback setup failed",
                detail: "Unsupported tap format. This probe currently handles 32-bit Float PCM mono/stereo only.",
                severity: .warning
            )
        }

        let sampleRate = tapStreamDescription.mSampleRate > 0
            ? tapStreamDescription.mSampleRate
            : ProcessTapCoreAudio.nominalSampleRate(for: resources.aggregateDeviceID)
                ?? AppConstants.processTapReplayFallbackSampleRate
        let outputFormat = ProcessTapReplayOutputFormat(
            sampleRate: sampleRate,
            channelCount: Int(tapStreamDescription.mChannelsPerFrame)
        )

        let playbackStatus = replayOutput.start(format: outputFormat)
        guard playbackStatus == noErr else {
            return ProcessTapReplayResult(
                outcome: .playbackSetupFailed,
                message: "Playback setup failed",
                detail: "AudioQueue setup failed with \(ProcessTapCoreAudio.formatOSStatus(playbackStatus)). No audio was replayed or saved.",
                severity: .warning
            )
        }

        let accumulator = ProcessTapReplayAccumulator()
        let callbackQueue = DispatchQueue(label: "com.macminimixer.process-tap-replay-probe.callback")
        let ioBlock: AudioDeviceIOBlock = { _, inputData, _, _, _ in
            accumulator.observe(inputData)
            replayOutput.enqueue(
                inputData,
                gain: gain.scalar
            )
        }

        let createIOProcStatus = resources.createIOProc(
            queue: callbackQueue,
            block: ioBlock
        )

        guard createIOProcStatus == noErr, resources.ioProcID != nil else {
            return ProcessTapReplayResult(
                outcome: .tapSetupFailed,
                message: "Could not attach replay callback",
                detail: "IOProc setup failed with \(ProcessTapCoreAudio.formatOSStatus(createIOProcStatus)). No audio was replayed or saved.",
                severity: .warning
            )
        }

        let startStatus = resources.startIO()
        guard startStatus == noErr else {
            return ProcessTapReplayResult(
                outcome: .tapSetupFailed,
                message: "Could not start replay probe",
                detail: "Start failed with \(ProcessTapCoreAudio.formatOSStatus(startStatus)). No audio was replayed or saved.",
                severity: .warning
            )
        }

        let stopReason = publishProgress(
            from: accumulator,
            targetPID: pid,
            onProgress: onProgress
        )

        let snapshot = accumulator.snapshot()
        let playbackSnapshot = replayOutput.snapshot()
        let diagnostics = replayDiagnostics(
            gain: gain,
            snapshot: snapshot,
            playbackSnapshot: playbackSnapshot
        )
        onProgress(snapshot.progress)
        let cleanupErrors = resources.cleanup(beforeStoppingIO: replayOutput.stop)

        guard cleanupErrors.isEmpty else {
            return ProcessTapReplayResult(
                outcome: .cleanupWarning,
                message: "Replay cleanup reported a warning",
                detail: cleanupErrors.joined(separator: ", "),
                severity: .warning,
                diagnostics: diagnostics
            )
        }

        if let stopReason {
            return stoppedResult(for: stopReason, diagnostics: diagnostics)
        }

        guard snapshot.callbackCount > 0 else {
            return ProcessTapReplayResult(
                outcome: .noAudioDetected,
                message: "Replay probe failed: no callbacks",
                detail: "Ran for \(formattedDuration). No audio was replayed after cleanup.",
                severity: .warning,
                diagnostics: diagnostics
            )
        }

        guard snapshot.detectedNonSilentAudio else {
            return ProcessTapReplayResult(
                outcome: .noAudioDetected,
                message: "No audio detected",
                detail: replayDetail(diagnostics),
                severity: .info,
                diagnostics: diagnostics
            )
        }

        return ProcessTapReplayResult(
            outcome: .replayCompleted,
            message: "Replay probe completed",
            detail: replayDetail(diagnostics),
            severity: .info,
            diagnostics: diagnostics
        )
    }

    private func publishProgress(
        from accumulator: ProcessTapReplayAccumulator,
        targetPID: pid_t,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) -> ProcessTapReplayProbeStopReason? {
        let deadline = Date().addingTimeInterval(AppConstants.processTapReplayProbeDuration)

        while Date() < deadline {
            Thread.sleep(forTimeInterval: AppConstants.processTapLevelMeterUpdateInterval)

            if let stopReason = currentStopReason() {
                return stopReason
            }

            guard processExists(targetPID) else {
                return .targetExited
            }

            onProgress(accumulator.snapshot().progress)
        }

        return nil
    }

    private func processExists(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }

        return errno == EPERM
    }

    private func stoppedResult(
        for reason: ProcessTapReplayProbeStopReason,
        diagnostics: ProcessTapReplayDiagnostics
    ) -> ProcessTapReplayResult {
        switch reason {
        case .userStopped:
            return ProcessTapReplayResult(
                outcome: .stopped,
                message: "Replay probe stopped",
                detail: replayDetail(diagnostics),
                severity: .info,
                diagnostics: diagnostics
            )
        case .outputDeviceChanged:
            return ProcessTapReplayResult(
                outcome: .outputDeviceChanged,
                message: "Replay probe stopped: output changed",
                detail: "Temporary replay resources were cleaned up.",
                severity: .warning,
                diagnostics: diagnostics
            )
        case .targetExited:
            return ProcessTapReplayResult(
                outcome: .targetExited,
                message: "Replay probe stopped: process exited",
                detail: "Temporary replay resources were cleaned up.",
                severity: .warning,
                diagnostics: diagnostics
            )
        }
    }

    private func replayDiagnostics(
        gain: ProcessTapReplayGainOption,
        snapshot: ProcessTapReplaySnapshot,
        playbackSnapshot: ProcessTapReplayOutputSnapshot
    ) -> ProcessTapReplayDiagnostics {
        ProcessTapReplayDiagnostics(
            selectedGain: gain,
            callbackCount: snapshot.callbackCount,
            peakLevel: snapshot.peakLevel,
            rmsLevel: snapshot.rmsLevel,
            enqueuedBufferCount: playbackSnapshot.enqueuedBufferCount,
            droppedBufferCount: playbackSnapshot.droppedBufferCount,
            enqueueFailureCount: playbackSnapshot.enqueueFailureCount,
            copyFailureCount: playbackSnapshot.copyFailureCount
        )
    }

    private func replayDetail(_ diagnostics: ProcessTapReplayDiagnostics) -> String {
        "Gain \(diagnostics.selectedGain.percentLabel), \(diagnostics.callbackCount) cb, peak \(formatLevel(diagnostics.peakLevel)), RMS \(formatLevel(diagnostics.rmsLevel)), queued \(diagnostics.enqueuedBufferCount), drops \(diagnostics.droppedBufferCount), fail \(diagnostics.totalFailureCount)."
    }

    private var formattedDuration: String {
        String(format: "%.1fs", AppConstants.processTapReplayProbeDuration)
    }

    private func formatLevel(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

}

private struct ProcessTapReplayOutputFormat {
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

private final class ProcessTapReplayOutputQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: AudioQueueRef?
    private var availableBuffers: [AudioQueueBufferRef] = []
    private var outputFormat: ProcessTapReplayOutputFormat?
    private var isStarted = false
    private var isStopped = false
    private var enqueuedBufferCount = 0
    private var droppedBufferCount = 0
    private var enqueueFailureCount = 0
    private var copyFailureCount = 0

    func start(format: ProcessTapReplayOutputFormat) -> OSStatus {
        lock.lock()
        outputFormat = format
        isStopped = false
        enqueuedBufferCount = 0
        droppedBufferCount = 0
        enqueueFailureCount = 0
        copyFailureCount = 0
        lock.unlock()

        var streamDescription = format.audioStreamBasicDescription
        var newQueue: AudioQueueRef?
        let createStatus = AudioQueueNewOutput(
            &streamDescription,
            processTapReplayAudioQueueCallback,
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

        let startStatus = AudioQueueStart(newQueue, nil)
        guard startStatus == noErr else {
            AudioQueueDispose(newQueue, true)
            return startStatus
        }

        lock.lock()
        queue = newQueue
        availableBuffers = allocatedBuffers
        isStarted = true
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
        if enqueueStatus != noErr {
            incrementEnqueueFailureCount()
            recycle(buffer)
        } else {
            incrementEnqueuedBufferCount()
        }
    }

    func recycle(_ buffer: AudioQueueBufferRef) {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }

        availableBuffers.append(buffer)
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
        queue = nil
        availableBuffers.removeAll()
        lock.unlock()

        guard let queueToStop else {
            return
        }

        if isStarted {
            AudioQueueStop(queueToStop, true)
        }
        AudioQueueDispose(queueToStop, true)
    }

    func snapshot() -> ProcessTapReplayOutputSnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }

        return ProcessTapReplayOutputSnapshot(
            enqueuedBufferCount: enqueuedBufferCount,
            droppedBufferCount: droppedBufferCount,
            enqueueFailureCount: enqueueFailureCount,
            copyFailureCount: copyFailureCount
        )
    }

    private func incrementEnqueuedBufferCount() {
        lock.lock()
        enqueuedBufferCount += 1
        lock.unlock()
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
        format: ProcessTapReplayOutputFormat,
        gain: Float
    ) -> Bool {
        let outputChannelCount = format.channelCount
        guard outputChannelCount > 0 else {
            return false
        }

        let outputData = outputBuffer.pointee.mAudioData
        let mutableInputData = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
        let inputBuffers = UnsafeMutableAudioBufferListPointer(mutableInputData)
        guard !inputBuffers.isEmpty else {
            return false
        }

        let maxFrames = Int(outputBuffer.pointee.mAudioDataBytesCapacity)
            / (MemoryLayout<Float32>.stride * outputChannelCount)
        guard maxFrames > 0 else {
            return false
        }

        let frameCount = min(maxFrames, frameCount(in: inputBuffers))
        guard frameCount > 0 else {
            return false
        }

        let outputSamples = outputData.assumingMemoryBound(to: Float32.self)

        if inputBuffers.count == 1 {
            copyInterleavedInput(
                inputBuffers[0],
                into: outputSamples,
                frameCount: frameCount,
                outputChannelCount: outputChannelCount,
                gain: gain
            )
        } else {
            copyPlanarInput(
                inputBuffers,
                into: outputSamples,
                frameCount: frameCount,
                outputChannelCount: outputChannelCount,
                gain: gain
            )
        }

        outputBuffer.pointee.mAudioDataByteSize = UInt32(
            frameCount * outputChannelCount * MemoryLayout<Float32>.stride
        )
        return true
    }

    private func frameCount(in inputBuffers: UnsafeMutableAudioBufferListPointer) -> Int {
        if inputBuffers.count == 1 {
            let channelCount = max(1, Int(inputBuffers[0].mNumberChannels))
            return Int(inputBuffers[0].mDataByteSize) / (MemoryLayout<Float32>.stride * channelCount)
        }

        return inputBuffers.reduce(Int.max) { partialResult, buffer in
            min(partialResult, Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride)
        }
    }

    private func copyInterleavedInput(
        _ inputBuffer: AudioBuffer,
        into outputSamples: UnsafeMutablePointer<Float32>,
        frameCount: Int,
        outputChannelCount: Int,
        gain: Float
    ) {
        guard let inputData = inputBuffer.mData else {
            return
        }

        let inputChannelCount = max(1, Int(inputBuffer.mNumberChannels))
        let inputSamples = inputData.assumingMemoryBound(to: Float32.self)

        for frame in 0..<frameCount {
            for outputChannel in 0..<outputChannelCount {
                let inputChannel = min(outputChannel, inputChannelCount - 1)
                outputSamples[(frame * outputChannelCount) + outputChannel] =
                    inputSamples[(frame * inputChannelCount) + inputChannel] * gain
            }
        }
    }

    private func copyPlanarInput(
        _ inputBuffers: UnsafeMutableAudioBufferListPointer,
        into outputSamples: UnsafeMutablePointer<Float32>,
        frameCount: Int,
        outputChannelCount: Int,
        gain: Float
    ) {
        for frame in 0..<frameCount {
            for outputChannel in 0..<outputChannelCount {
                let inputBuffer = inputBuffers[min(outputChannel, inputBuffers.count - 1)]
                guard let inputData = inputBuffer.mData else {
                    outputSamples[(frame * outputChannelCount) + outputChannel] = 0
                    continue
                }

                let inputSamples = inputData.assumingMemoryBound(to: Float32.self)
                outputSamples[(frame * outputChannelCount) + outputChannel] = inputSamples[frame] * gain
            }
        }
    }
}

private struct ProcessTapReplayOutputSnapshot {
    let enqueuedBufferCount: Int
    let droppedBufferCount: Int
    let enqueueFailureCount: Int
    let copyFailureCount: Int
}

private func processTapReplayAudioQueueCallback(
    userData: UnsafeMutableRawPointer?,
    queue: AudioQueueRef,
    buffer: AudioQueueBufferRef
) {
    guard let userData else {
        return
    }

    let outputQueue = Unmanaged<ProcessTapReplayOutputQueue>.fromOpaque(userData).takeUnretainedValue()
    outputQueue.recycle(buffer)
}

private struct ProcessTapReplaySnapshot {
    let callbackCount: Int
    let measuredSampleCount: UInt64
    let peakLevel: Double
    let rmsLevel: Double

    var detectedNonSilentAudio: Bool {
        peakLevel > 0.001
    }

    var progress: ProcessTapDiagnosticProgress {
        ProcessTapDiagnosticProgress(
            callbackCount: callbackCount,
            peakLevel: peakLevel,
            rmsLevel: rmsLevel,
            audioDetected: detectedNonSilentAudio
        )
    }
}

private final class ProcessTapReplayAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var callbackCount = 0
    private var measuredSampleCount: UInt64 = 0
    private var peakLevel: Double = 0
    private var sumOfSquares: Double = 0

    func observe(_ inputData: UnsafePointer<AudioBufferList>) {
        var localSampleCount: UInt64 = 0
        var localPeak: Double = 0
        var localSumOfSquares: Double = 0

        let mutableInputData = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
        for buffer in UnsafeMutableAudioBufferListPointer(mutableInputData) {
            guard let data = buffer.mData else {
                continue
            }

            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride
            guard sampleCount > 0 else {
                continue
            }

            let samples = data.assumingMemoryBound(to: Float32.self)
            for index in 0..<sampleCount {
                let sampleValue = Double(samples[index])
                guard sampleValue.isFinite else {
                    continue
                }

                let absoluteSample = abs(sampleValue)
                localPeak = max(localPeak, absoluteSample)
                localSumOfSquares += sampleValue * sampleValue
                localSampleCount += 1
            }
        }

        lock.lock()
        callbackCount += 1
        peakLevel = max(peakLevel, localPeak)
        sumOfSquares += localSumOfSquares
        measuredSampleCount += localSampleCount
        lock.unlock()
    }

    func snapshot() -> ProcessTapReplaySnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }

        let rmsLevel = measuredSampleCount > 0
            ? sqrt(sumOfSquares / Double(measuredSampleCount))
            : 0

        return ProcessTapReplaySnapshot(
            callbackCount: callbackCount,
            measuredSampleCount: measuredSampleCount,
            peakLevel: peakLevel,
            rmsLevel: rmsLevel
        )
    }
}
