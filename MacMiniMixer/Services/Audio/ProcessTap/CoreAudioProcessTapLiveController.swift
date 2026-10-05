import AudioToolbox
import CoreAudio
import Darwin
import Foundation

final class CoreAudioProcessTapLiveController: ProcessTapLiveControlling, @unchecked Sendable {
    private let sessionLock = NSLock()
    private var activeSession: ProcessTapLiveSession?
    private let outputMode: ProcessTapLiveOutputMode
    private let directResampleMode: ProcessTapDirectResampleMode

    /// Delay before the one-off "direct resample report" log of a converting direct session.
    private static let directResampleReportDelay: TimeInterval = 2

    /// `outputMode` / `directResampleMode` default to the configured modes (`UserDefaults`
    /// overrides, else `AppConstants` defaults), read once here when the controller is made.
    init(
        outputMode: ProcessTapLiveOutputMode = ProcessTapLiveOutputMode.configured(),
        directResampleMode: ProcessTapDirectResampleMode = ProcessTapDirectResampleMode.configured()
    ) {
        self.outputMode = outputMode
        self.directResampleMode = directResampleMode
    }

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
        if outputMode == .directAggregateOutput {
            let directAttempt = attemptDirectOutputStart(
                target: target,
                gain: gain,
                timeoutPolicy: timeoutPolicy,
                processIdentifier: processIdentifier,
                onDiagnostics: onDiagnostics,
                onStopped: onStopped
            )

            switch directAttempt {
            case .finished(let result):
                return result
            case .fallBackToAudioQueue(let reason):
                // Every direct-path resource is already torn down (its defer ran). The AudioQueue
                // path is the long-standing one, so a device it cannot handle directly still plays.
                AppLogger.processTap.warning("Live control direct output unavailable, falling back to AudioQueue app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) reason=\(reason, privacy: .public)")
            }
        }

        return attemptAudioQueueStart(
            target: target,
            gain: gain,
            timeoutPolicy: timeoutPolicy,
            processIdentifier: processIdentifier,
            onDiagnostics: onDiagnostics,
            onStopped: onStopped
        )
    }

    /// Direct aggregate output (`ProcessTapLiveOutputMode.directAggregateOutput`): one private
    /// aggregate = default output device (main/clock sub-device) + the tap, and one IOProc that
    /// reads the tap from `inInputData` and writes the faded/gained samples to `outOutputData` in
    /// the same callback. Input and output share the device clock and there is no buffer hand-off
    /// to a second thread, which removes the random underruns of the tap→AudioQueue path.
    /// Returns `.fallBackToAudioQueue` (after tearing everything down) when this device/format
    /// cannot be rendered directly; tap-level failures (permission, process) finish here.
    @available(macOS 14.2, *)
    private func attemptDirectOutputStart(
        target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        processIdentifier: Int32,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) -> ProcessTapDirectOutputStartAttempt {
        let pid = pid_t(processIdentifier)
        AppLogger.processTap.info("Live control start requested app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) gain=\(gain.percentLabel, privacy: .public) output=direct")
        let resources = ProcessTapResourceContext()
        var didActivateSession = false
        let gainState = ProcessTapLiveGainState(gain: gain)

        defer {
            if !didActivateSession {
                _ = resources.cleanup(statusFormatter: { "\($0)" })
            }
        }

        guard let startDefaultOutputDeviceID = ProcessTapCoreAudio.defaultOutputDeviceID() else {
            AppLogger.processTap.error("Live control setup failed: missing default output device app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return .finished(ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Could not read default output device",
                severity: .warning
            ))
        }

        guard let outputDeviceUID = ProcessTapCoreAudio.stringProperty(
            kAudioDevicePropertyDeviceUID,
            for: startDefaultOutputDeviceID
        ) else {
            return .fallBackToAudioQueue(reason: "output device UID unavailable")
        }

        // The aggregate's input list holds the output device's own input streams (a headset or
        // interface microphone) as well as the tap stream, and their order is not documented.
        // Rendering the wrong one would play the microphone, so only output-only devices (built-in
        // speakers, HDMI/DisplayPort, USB DACs) use the direct path; the input list is then the tap.
        let outputDeviceInputStreamCount = ProcessTapCoreAudio.streamCount(
            for: startDefaultOutputDeviceID,
            scope: kAudioObjectPropertyScopeInput
        )
        guard outputDeviceInputStreamCount == 0 else {
            return .fallBackToAudioQueue(
                reason: "output device has input streams (\(outputDeviceInputStreamCount.map { String($0) } ?? "unknown"))"
            )
        }

        let tapUID: String
        switch createLiveTap(target: target, processIdentifier: processIdentifier, resources: resources) {
        case .created(let createdTapUID):
            tapUID = createdTapUID
        case .failed(let result):
            return .finished(result)
        }

        let createAggregateStatus = resources.createPrivateOutputAggregateDevice(
            name: "MacMiniMixer Process Tap Live Output",
            uidPrefix: "com.macminimixer.process-tap-live-output",
            tapUID: tapUID,
            outputDeviceUID: outputDeviceUID
        )
        guard createAggregateStatus == noErr, resources.aggregateDeviceID != kAudioObjectUnknown else {
            return .fallBackToAudioQueue(
                reason: "create aggregate status=\(ProcessTapCoreAudio.formatOSStatus(createAggregateStatus))"
            )
        }

        let aggregateDeviceID = resources.aggregateDeviceID
        guard (ProcessTapCoreAudio.streamCount(for: aggregateDeviceID, scope: kAudioObjectPropertyScopeInput) ?? 0) > 0,
              (ProcessTapCoreAudio.streamCount(for: aggregateDeviceID, scope: kAudioObjectPropertyScopeOutput) ?? 0) > 0 else {
            return .fallBackToAudioQueue(reason: "aggregate is missing its tap input or device output streams")
        }

        guard let inputFormat = ProcessTapCoreAudio.streamDescription(
                for: aggregateDeviceID,
                scope: kAudioObjectPropertyScopeInput
              ),
              let outputFormat = ProcessTapCoreAudio.streamDescription(
                for: aggregateDeviceID,
                scope: kAudioObjectPropertyScopeOutput
              ) else {
            return .fallBackToAudioQueue(reason: "could not read aggregate stream formats")
        }

        if let incompatibility = ProcessTapDirectOutputCopier.formatIncompatibility(
            input: inputFormat,
            output: outputFormat,
            allowsSampleRateConversion: directResampleMode == .on
        ) {
            return .fallBackToAudioQueue(reason: incompatibility)
        }

        // Equal rates keep the frame-for-frame copy (no resampler). Differing rates (e.g. tap
        // 48 kHz, built-in speakers at 44.1 kHz) convert inside the IOProc; everything the
        // converter needs is created here, off the audio thread.
        let resampler: ProcessTapDirectOutputResampler?
        if ProcessTapDirectOutputCopier.requiresSampleRateConversion(input: inputFormat, output: outputFormat) {
            let bufferFrameSize = Int(ProcessTapCoreAudio.bufferFrameSize(for: aggregateDeviceID) ?? 0)
            guard let createdResampler = ProcessTapDirectOutputResampler(
                inputSampleRate: inputFormat.mSampleRate,
                outputSampleRate: outputFormat.mSampleRate,
                channelCount: Int(inputFormat.mChannelsPerFrame),
                maxOutputFramesPerCycle: max(
                    ProcessTapDirectOutputResampler.minimumOutputFrameCapacity,
                    bufferFrameSize * 2
                )
            ) else {
                return .fallBackToAudioQueue(
                    reason: "could not create sample rate converter (tap \(inputFormat.mSampleRate) Hz, output \(outputFormat.mSampleRate) Hz)"
                )
            }
            resampler = createdResampler
        } else {
            resampler = nil
        }

        let renderer = ProcessTapDirectOutputRenderer(
            sampleRate: outputFormat.mSampleRate,
            channelCount: Int(outputFormat.mChannelsPerFrame),
            gain: gain.scalar,
            resampler: resampler
        )
        let accumulator = ProcessTapDiagnosticsAccumulator()
        let timingAccumulator = ProcessTapCallbackTimingAccumulator()
        let callbackQueue = DispatchQueue(label: "com.macminimixer.process-tap-live-output.callback")
        let ioBlock: AudioDeviceIOBlock = { _, inputData, inputTime, outputData, _ in
            timingAccumulator.record(hostTime: inputTime.pointee.mHostTime)
            accumulator.observe(inputData)
            renderer.render(inputData, into: outputData)
        }

        let createIOProcStatus = resources.createIOProc(
            queue: callbackQueue,
            block: ioBlock
        )
        guard createIOProcStatus == noErr, resources.ioProcID != nil else {
            return .fallBackToAudioQueue(
                reason: "create IOProc status=\(ProcessTapCoreAudio.formatOSStatus(createIOProcStatus))"
            )
        }

        let startStatus = resources.startIO()
        guard startStatus == noErr else {
            return .fallBackToAudioQueue(
                reason: "start IO status=\(ProcessTapCoreAudio.formatOSStatus(startStatus))"
            )
        }

        let session = ProcessTapLiveSession(
            pid: pid,
            targetName: target.appName,
            gainState: gainState,
            startDefaultOutputDeviceID: startDefaultOutputDeviceID,
            resources: resources,
            output: .directAggregate(renderer),
            accumulator: accumulator,
            timingAccumulator: timingAccumulator,
            publishGate: ProcessTapDiagnosticsPublishGate(),
            onDiagnostics: onDiagnostics,
            onStopped: onStopped
        )

        guard activate(session, timeoutPolicy: timeoutPolicy) else {
            return .finished(ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Live control is already active",
                severity: .warning
            ))
        }

        didActivateSession = true
        let isResampling = resampler != nil
        AppLogger.processTap.info("Live control started app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) outputDeviceID=\(startDefaultOutputDeviceID, privacy: .public) output=direct rate=\(outputFormat.mSampleRate, privacy: .public) outChannels=\(outputFormat.mChannelsPerFrame, privacy: .public) tapRate=\(inputFormat.mSampleRate, privacy: .public) resample=\(isResampling, privacy: .public)")
        if let resampler {
            scheduleDirectResampleReport(resampler, appName: target.appName, processIdentifier: processIdentifier)
        }

        return .finished(ProcessTapTestResult(
            outcome: .liveControlStarted,
            message: "Live control started",
            detail: startDetail(gain: gain, timeoutPolicy: timeoutPolicy),
            severity: .info
        ))
    }

    /// Publishes `session` as the active one and starts its timers, unless another start won the
    /// race (returns false; the caller then tears its resources down).
    func activate(_ session: ProcessTapLiveSession, timeoutPolicy: ProcessTapLiveTimeoutPolicy) -> Bool {
        sessionLock.lock()
        guard activeSession == nil else {
            sessionLock.unlock()
            return false
        }

        activeSession = session
        sessionLock.unlock()

        startTimers(for: session, timeoutPolicy: timeoutPolicy)
        // First publish is forced (and seeds the gate so the imminent first timer tick does not
        // immediately re-publish within the throttle interval).
        let initialDiagnostics = session.diagnostics()
        _ = session.publishGate.shouldPublish(initialDiagnostics, force: true)
        session.onDiagnostics(initialDiagnostics)
        return true
    }

    /// Logs once, `directResampleReportDelay` after start and off the audio thread, what a direct
    /// session with differing tap/output rates measured: the reported rates, the path the resampler
    /// chose, average tap/output frames per IOProc cycle and their ratio, and FIFO underruns /
    /// overflows. measuredRatio ≈ expectedRatio means the HAL delivers tap frames at the tap's own
    /// rate; ≈ 1 means it already resampled them. Logs even if the session stopped meanwhile.
    /// Notice level (one line per session) so it is kept without `--info` log capture.
    private func scheduleDirectResampleReport(
        _ resampler: ProcessTapDirectOutputResampler,
        appName: String,
        processIdentifier: Int32
    ) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.directResampleReportDelay) {
            let snapshot = resampler.snapshot()
            AppLogger.processTap.notice("Live control direct resample report app=\(appName, privacy: .public) pid=\(processIdentifier, privacy: .public) tapRate=\(snapshot.inputSampleRate, privacy: .public) outputRate=\(snapshot.outputSampleRate, privacy: .public) path=\(snapshot.path.rawValue, privacy: .public) avgTapFramesPerCycle=\(String(format: "%.2f", snapshot.averageInputFramesPerCycle), privacy: .public) avgOutputFramesPerCycle=\(String(format: "%.2f", snapshot.averageOutputFramesPerCycle), privacy: .public) measuredRatio=\(String(format: "%.5f", snapshot.measuredRatio), privacy: .public) expectedRatio=\(String(format: "%.5f", snapshot.expectedRatio), privacy: .public) cycles=\(snapshot.cycleCount, privacy: .public) underruns=\(snapshot.underrunCount, privacy: .public) overflows=\(snapshot.overflowCount, privacy: .public)")
        }
    }

    /// Maps the target's processes to Core Audio process objects and creates the muted process
    /// tap over them (shared by both live output paths).
    @available(macOS 14.2, *)
    func createLiveTap(
        target: ProcessTapTarget,
        processIdentifier: Int32,
        resources: ProcessTapResourceContext
    ) -> ProcessTapLiveTapCreation {
        // A multi-process target (the app plus its audio helpers) becomes one tap over every process
        // that still maps to a Core Audio process object. Processes that do not (e.g. a browser's
        // main process that never used audio, or a helper that just exited) are skipped; the start
        // only fails when none of them maps. A single-process target behaves exactly as before.
        let requestedProcessIdentifiers = target.allProcessIdentifiers
        var processObjectIDs: [AudioObjectID] = []
        var unmappedProcessIdentifiers: [Int32] = []
        for requestedProcessIdentifier in requestedProcessIdentifiers {
            guard let processObjectID = ProcessTapCoreAudio.processObjectID(for: pid_t(requestedProcessIdentifier)) else {
                unmappedProcessIdentifiers.append(requestedProcessIdentifier)
                continue
            }

            if !processObjectIDs.contains(processObjectID) {
                processObjectIDs.append(processObjectID)
            }
        }

        guard !processObjectIDs.isEmpty else {
            AppLogger.processTap.warning("Live control setup failed: Core Audio process not found app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) requestedCount=\(requestedProcessIdentifiers.count, privacy: .public)")
            let detail = requestedProcessIdentifiers.count > 1
                ? "None of PIDs \(requestedProcessIdentifiers.map { String($0) }.joined(separator: ", ")) mapped to a Core Audio process object."
                : "PID \(processIdentifier) did not map to a Core Audio process object."
            return .failed(ProcessTapTestResult(
                outcome: .processNotFound,
                message: "Could not find Core Audio process",
                detail: detail,
                severity: .warning
            ))
        }

        if requestedProcessIdentifiers.count > 1 {
            let unmappedDescription = unmappedProcessIdentifiers.map { String($0) }.joined(separator: ",")
            AppLogger.processTap.info("Live control multi-process tap app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) requested=\(requestedProcessIdentifiers.count, privacy: .public) mapped=\(processObjectIDs.count, privacy: .public) unmappedPIDs=\(unmappedDescription, privacy: .public)")
        }

        let createStatus = resources.createProcessTap(
            processObjectIDs: processObjectIDs,
            name: "MacMiniMixer Live Control - \(target.appName)",
            muteBehavior: .mutedWhenTapped
        )
        guard createStatus == noErr, resources.tapID != kAudioObjectUnknown else {
            AppLogger.processTap.error("Live control setup failed: create tap status=\(ProcessTapCoreAudio.formatOSStatus(createStatus), privacy: .public) app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return .failed(ProcessTapTestResult(
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
            ))
        }

        guard let tapUID = resources.tapUID else {
            AppLogger.processTap.error("Live control setup failed: missing tap UID app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return .failed(ProcessTapTestResult(
                outcome: .liveControlSetupFailed,
                message: "Could not read process tap UID",
                severity: .warning
            ))
        }

        return .created(tapUID: tapUID)
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

            // Throttle the routine UI publish: the accumulators keep measuring every audio callback,
            // but the SwiftUI-facing diagnostics only refresh ~4 Hz (failures/starvation still publish
            // immediately). Final values are published unthrottled via `onStopped` at teardown.
            let diagnostics = session.diagnostics()
            if session.publishGate.shouldPublish(diagnostics, force: false) {
                session.onDiagnostics(diagnostics)
            }
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

    func startDetail(gain: ProcessTapReplayGainOption, timeoutPolicy: ProcessTapLiveTimeoutPolicy) -> String {
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

/// Result of a direct-output start attempt: either a final start result (started, or a tap-level
/// failure the AudioQueue path would hit too), or a reason to retry on the AudioQueue path.
private enum ProcessTapDirectOutputStartAttempt {
    case finished(ProcessTapTestResult)
    case fallBackToAudioQueue(reason: String)
}

enum ProcessTapLiveTapCreation {
    case created(tapUID: String)
    case failed(ProcessTapTestResult)
}

/// Where a live session's audio goes: the legacy AudioQueue, or straight out of the aggregate's
/// own IOProc output (direct mode).
enum ProcessTapLiveOutputBackend {
    case audioQueue(ProcessTapLiveOutputQueue)
    case directAggregate(ProcessTapDirectOutputRenderer)
}

final class ProcessTapLiveSession: @unchecked Sendable {
    let pid: pid_t
    let targetName: String
    let gainState: ProcessTapLiveGainState
    let startDefaultOutputDeviceID: AudioDeviceID
    let resources: ProcessTapResourceContext
    let output: ProcessTapLiveOutputBackend
    let accumulator: ProcessTapDiagnosticsAccumulator
    let timingAccumulator: ProcessTapCallbackTimingAccumulator
    let publishGate: ProcessTapDiagnosticsPublishGate
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
        output: ProcessTapLiveOutputBackend,
        accumulator: ProcessTapDiagnosticsAccumulator,
        timingAccumulator: ProcessTapCallbackTimingAccumulator,
        publishGate: ProcessTapDiagnosticsPublishGate,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) {
        self.pid = pid
        self.targetName = targetName
        self.gainState = gainState
        self.startDefaultOutputDeviceID = startDefaultOutputDeviceID
        self.resources = resources
        self.output = output
        self.accumulator = accumulator
        self.timingAccumulator = timingAccumulator
        self.publishGate = publishGate
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
                switch self.output {
                case .audioQueue(let outputQueue):
                    // Ramp the gain to silence while the output queue is still live and the IOProc is
                    // still feeding it, so the fade is smooth and no buffers are dropped during it.
                    outputQueue.beginFadeOut()
                    Thread.sleep(forTimeInterval: AppConstants.processTapLiveFadeOutDuration)
                case .directAggregate(let renderer):
                    // The IOProc renders the fade itself; stop it only once it has rendered the
                    // whole ramp (bounded wait), so the device never stops on a non-zero sample.
                    renderer.beginFadeOut()
                    Thread.sleep(forTimeInterval: AppConstants.processTapLiveFadeOutDuration)
                    renderer.waitForFadeOutToRender()
                }
            },
            afterDestroyingIOProc: {
                // Dispose the output queue only after the IOProc has been stopped and destroyed.
                // The IOProc's audio callback enqueues into this queue; stopping the queue while
                // the IOProc is still running (the previous order) made every in-flight enqueue
                // hit the stopped-queue guard and count as a dropped buffer — the Drops/Fail spike
                // seen when tearing down during an output-device route change. With the producer
                // already gone, this dispose drops nothing. Direct mode has no queue to dispose.
                if case .audioQueue(let outputQueue) = self.output {
                    outputQueue.stop()
                }
            },
            statusFormatter: { "\($0)" }
        )
    }

    func updateGain(_ gain: ProcessTapReplayGainOption) {
        gainState.update(gain)
        if case .directAggregate(let renderer) = output {
            renderer.updateTargetGain(gain.scalar)
        }
    }

    func diagnostics() -> ProcessTapLiveDiagnostics {
        let inputSnapshot = accumulator.snapshot()
        let outputSnapshot: ProcessTapLiveOutputSnapshot
        var resampleSnapshot: ProcessTapDirectResampleSnapshot?
        switch output {
        case .audioQueue(let outputQueue):
            outputSnapshot = outputQueue.snapshot()
        case .directAggregate(let renderer):
            // No queue in direct mode: the queue-only counters (enqueued/failures) and the queue
            // warmup state do not apply and report zero/false. With sample-rate conversion, the
            // resampler's FIFO underruns report as starvation and its overflows as drops; both stay
            // zero on the equal-rate path.
            resampleSnapshot = renderer.resampleSnapshot()
            outputSnapshot = ProcessTapLiveOutputSnapshot(
                enqueuedBufferCount: 0,
                droppedBufferCount: resampleSnapshot?.overflowCount ?? 0,
                enqueueFailureCount: 0,
                copyFailureCount: 0,
                outputStarvationCount: resampleSnapshot?.underrunCount ?? 0,
                isWithinStartupWarmup: false
            )
        }
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
            outputStarvationCount: outputSnapshot.outputStarvationCount,
            isWarmingUpOutput: outputSnapshot.isWithinStartupWarmup,
            averageTapFramesPerCycle: resampleSnapshot?.averageInputFramesPerCycle ?? 0,
            averageOutputFramesPerCycle: resampleSnapshot?.averageOutputFramesPerCycle ?? 0
        )
    }
}

final class ProcessTapLiveGainState: @unchecked Sendable {
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

struct ProcessTapLiveOutputFormat {
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

/// Audio-thread side of the direct aggregate output path. `render` runs only in the IOProc (which
/// Core Audio calls serially) and owns the gain ramp and the other render-only fields. Other
/// threads only post a new target gain or the fade-out request under `controlLock`; the IOProc
/// reads them with a non-blocking `try()` and, if the lock is momentarily held, keeps last cycle's
/// values and picks the change up on the next cycle. So the callback never blocks, allocates or
/// logs. Fade semantics are `ProcessTapLiveGainRamp`'s: fade-in from silence on start, fade-out
/// before stop.
///
/// With a `resampler` (tap rate ≠ output rate), each cycle's tap frames go through it first and the
/// copier renders its output (same channel mapping and per-output-frame gain); until it has audio
/// to give (start-up prefill) the output is written silent without advancing the fade-in, so the
/// fade-in still starts with the audio. Without one, the cycle is rendered exactly as before.
final class ProcessTapDirectOutputRenderer: @unchecked Sendable {
    /// Teardown waits at most this many extra polls (beyond the fade-out duration) for the IOProc
    /// to finish rendering the ramp — bounded so a stalled device cannot hang a stop.
    private static let fadeOutRenderedPollInterval: TimeInterval = 0.005
    private static let fadeOutRenderedMaxPolls = 8

    private let controlLock = NSLock()
    // Guarded by `controlLock`.
    private var requestedTargetGain: Float
    private var isFadeOutRequested = false
    private var isFadeOutRendered = false

    // IOProc only.
    private var gainRamp: ProcessTapLiveGainRamp
    private var renderTargetGain: Float
    private var isRenderingFadeOut = false
    private var fadeOutFramesRendered = 0
    private var hasPublishedFadeOutRendered = false
    private let fadeOutFrameCount: Int
    private let resampler: ProcessTapDirectOutputResampler?

    /// `sampleRate` / `channelCount` are the output device's (the side the gain ramp runs on).
    init(
        sampleRate: Double,
        channelCount: Int,
        gain: Float,
        resampler: ProcessTapDirectOutputResampler? = nil
    ) {
        let format = ProcessTapLiveOutputFormat(sampleRate: sampleRate, channelCount: channelCount)
        let rampSampleRate = sampleRate > 0 ? sampleRate : AppConstants.processTapReplayFallbackSampleRate
        gainRamp = ProcessTapLiveGainRamp(format: format)
        requestedTargetGain = gain
        renderTargetGain = gain
        // Same frame count the ramp uses for its fade-out.
        fadeOutFrameCount = max(1, Int((AppConstants.processTapLiveFadeOutDuration * rampSampleRate).rounded()))
        self.resampler = resampler
    }

    /// The resampler's published diagnostics, or nil on the equal-rate path. Any thread.
    func resampleSnapshot() -> ProcessTapDirectResampleSnapshot? {
        resampler?.snapshot()
    }

    func updateTargetGain(_ gain: Float) {
        controlLock.lock()
        requestedTargetGain = gain
        controlLock.unlock()
    }

    func beginFadeOut() {
        controlLock.lock()
        isFadeOutRequested = true
        controlLock.unlock()
    }

    /// Teardown only (never the audio thread): after the fade-out sleep, polls until the IOProc has
    /// rendered the whole fade-out ramp, for at most `fadeOutRenderedMaxPolls` short polls.
    func waitForFadeOutToRender() {
        var polls = 0
        while !hasRenderedFadeOut(), polls < Self.fadeOutRenderedMaxPolls {
            Thread.sleep(forTimeInterval: Self.fadeOutRenderedPollInterval)
            polls += 1
        }
    }

    /// IOProc only. Writes every output frame (silence where there is no tap input).
    func render(
        _ inputData: UnsafePointer<AudioBufferList>,
        into outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        if controlLock.`try`() {
            renderTargetGain = requestedTargetGain
            let fadeOutRequested = isFadeOutRequested
            controlLock.unlock()

            if fadeOutRequested, !isRenderingFadeOut {
                isRenderingFadeOut = true
                gainRamp.beginFadeOut()
            }
        }

        var gainProvider = ProcessTapLiveFrameGainProvider(
            gainRamp: gainRamp,
            targetGain: renderTargetGain
        )
        let result: ProcessTapDirectOutputRenderResult
        if let resampler {
            let outputFrameCount = ProcessTapDirectOutputCopier.outputFrameCount(in: outputData)
            if let resampledData = resampler.process(inputData, outputFrameCount: outputFrameCount) {
                result = ProcessTapDirectOutputCopier.render(
                    resampledData,
                    into: outputData,
                    gainProvider: &gainProvider
                )
            } else {
                result = ProcessTapDirectOutputCopier.renderSilence(into: outputData)
            }
        } else {
            result = ProcessTapDirectOutputCopier.render(
                inputData,
                into: outputData,
                gainProvider: &gainProvider
            )
        }
        gainRamp = gainProvider.gainRamp

        guard isRenderingFadeOut, !hasPublishedFadeOutRendered else {
            return
        }

        fadeOutFramesRendered += result.outputFrameCount
        if fadeOutFramesRendered >= fadeOutFrameCount, controlLock.`try`() {
            isFadeOutRendered = true
            controlLock.unlock()
            hasPublishedFadeOutRendered = true
        }
    }

    private func hasRenderedFadeOut() -> Bool {
        controlLock.lock()
        defer {
            controlLock.unlock()
        }

        return isFadeOutRendered
    }
}

struct ProcessTapLiveFrameGainProvider: ProcessTapOutputFrameGainProviding {
    var gainRamp: ProcessTapLiveGainRamp
    let targetGain: Float

    mutating func gain(forFrame frame: Int) -> Float {
        gainRamp.nextGain(targetGain: targetGain)
    }
}

struct ProcessTapLiveGainRamp {
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

struct ProcessTapLiveOutputSnapshot {
    let enqueuedBufferCount: Int
    let droppedBufferCount: Int
    let enqueueFailureCount: Int
    let copyFailureCount: Int
    let outputStarvationCount: Int
    let isWithinStartupWarmup: Bool
}
