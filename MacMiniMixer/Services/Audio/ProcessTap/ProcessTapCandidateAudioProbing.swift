import CoreAudio
import Darwin
import Foundation

enum ProcessTapCandidateProbeStopReason: Sendable {
    case userStopped
    case outputDeviceChanged
    case targetExited
}

protocol ProcessTapCandidateAudioProbing: Sendable {
    func probeAudio(
        for target: ProcessTapTarget,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult

    func stopCurrentProbe(reason: ProcessTapCandidateProbeStopReason)
}

final class CoreAudioProcessTapCandidateAudioProbe: ProcessTapCandidateAudioProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = false
    private var requestedStopReason: ProcessTapCandidateProbeStopReason?

    func probeAudio(
        for target: ProcessTapTarget,
        duration: TimeInterval = AppConstants.processTapDiagnosticDuration,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult {
        await Task.detached(priority: .userInitiated) {
            self.runProbe(for: target, duration: duration, onProgress: onProgress)
        }.value
    }

    func stopCurrentProbe(reason: ProcessTapCandidateProbeStopReason) {
        lock.lock()
        if isRunning, requestedStopReason == nil {
            requestedStopReason = reason
        }
        lock.unlock()
    }

    private func runProbe(
        for target: ProcessTapTarget,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) -> ProcessTapTestResult {
        guard beginProbe() else {
            AppLogger.processTap.warning("Helper probe rejected: already running app=\(target.appName, privacy: .public) pid=\(target.processIdentifier ?? -1, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .helperProbeRunning,
                message: "A helper probe is already running",
                severity: .warning
            )
        }

        defer {
            finishProbe()
        }

        guard let processIdentifier = target.processIdentifier, processIdentifier > 0 else {
            AppLogger.processTap.warning("Helper probe rejected: invalid PID app=\(target.appName, privacy: .public) pid=\(target.processIdentifier ?? -1, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .invalidTarget,
                message: "Invalid helper process",
                severity: .warning
            )
        }

        if #available(macOS 14.2, *) {
            guard ProcessTapCoreAudio.hasAudioCaptureUsageDescription else {
                AppLogger.processTap.warning("Helper probe rejected: missing usage description app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
                return ProcessTapTestResult(
                    outcome: .missingUsageDescription,
                    message: ProcessTapPermissionMessage.missingUsageDescription,
                    detail: ProcessTapPermissionMessage.missingUsageDescriptionDetail,
                    severity: .warning
                )
            }

            return attemptProbe(
                for: target,
                processIdentifier: processIdentifier,
                duration: duration,
                onProgress: onProgress
            )
        } else {
            AppLogger.processTap.warning("Helper probe rejected: unsupported macOS app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .unsupportedOS,
                message: "Process Tap not available on this macOS version",
                detail: "Core Audio Process Tap diagnostics require macOS 14.2 or later.",
                severity: .warning
            )
        }
    }

    @available(macOS 14.2, *)
    private func attemptProbe(
        for target: ProcessTapTarget,
        processIdentifier: Int32,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) -> ProcessTapTestResult {
        let pid = pid_t(processIdentifier)
        AppLogger.processTap.info("Helper probe started app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) duration=\(duration, privacy: .public)")
        let resources = ProcessTapResourceContext()
        var didCleanUp = false

        defer {
            if !didCleanUp {
                _ = resources.cleanup()
            }
        }

        guard let processObjectID = ProcessTapCoreAudio.processObjectID(for: pid) else {
            AppLogger.processTap.warning("Helper probe setup failed: Core Audio process unavailable app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .processNotFound,
                message: "Core Audio process unavailable",
                detail: "PID \(processIdentifier) did not map to a Core Audio process object.",
                severity: .warning
            )
        }

        let createStatus = resources.createProcessTap(
            processObjectID: processObjectID,
            name: "MacMiniMixer Helper Audio Probe - \(target.appName)",
            muteBehavior: .unmuted
        )

        guard createStatus == noErr, resources.tapID != kAudioObjectUnknown else {
            AppLogger.processTap.error("Helper probe setup failed: create tap status=\(ProcessTapCoreAudio.formatOSStatus(createStatus), privacy: .public) app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: ProcessTapPermissionMessage.isPermissionDeniedStatus(createStatus) ? .permissionDenied : .tapSetupFailed,
                message: ProcessTapPermissionMessage.message(
                    forCreateStatus: createStatus,
                    fallback: "Could not create helper probe tap"
                ),
                detail: ProcessTapPermissionMessage.detail(
                    forCreateStatus: createStatus,
                    fallback: "Create failed with \(ProcessTapCoreAudio.formatOSStatus(createStatus)). No audio was replayed, saved, or modified."
                ),
                severity: .warning
            )
        }

        guard let tapUID = resources.tapUID else {
            AppLogger.processTap.error("Helper probe setup failed: missing tap UID app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .tapSetupFailed,
                message: "Could not read helper probe tap UID",
                detail: "The tap was created, but diagnostics could not attach it to a temporary aggregate device.",
                severity: .warning
            )
        }

        let createAggregateStatus = resources.createPrivateAggregateDevice(
            name: "MacMiniMixer Helper Audio Probe",
            uidPrefix: "com.macminimixer.helper-audio-probe",
            tapUID: tapUID
        )

        guard createAggregateStatus == noErr, resources.aggregateDeviceID != kAudioObjectUnknown else {
            AppLogger.processTap.error("Helper probe setup failed: create aggregate status=\(ProcessTapCoreAudio.formatOSStatus(createAggregateStatus), privacy: .public) app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .tapSetupFailed,
                message: "Could not create helper probe device",
                detail: "Aggregate setup failed with \(ProcessTapCoreAudio.formatOSStatus(createAggregateStatus)). No audio was replayed, saved, or modified.",
                severity: .warning
            )
        }

        let accumulator = ProcessTapDiagnosticsAccumulator()
        let callbackQueue = DispatchQueue(label: "com.macminimixer.helper-audio-probe.callback")
        let ioBlock: AudioDeviceIOBlock = { _, inputData, _, _, _ in
            accumulator.observe(inputData)
        }

        let createIOProcStatus = resources.createIOProc(
            queue: callbackQueue,
            block: ioBlock
        )

        guard createIOProcStatus == noErr, resources.ioProcID != nil else {
            AppLogger.processTap.error("Helper probe setup failed: create IOProc status=\(ProcessTapCoreAudio.formatOSStatus(createIOProcStatus), privacy: .public) app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .tapSetupFailed,
                message: "Could not attach helper probe callback",
                detail: "IOProc setup failed with \(ProcessTapCoreAudio.formatOSStatus(createIOProcStatus)). No audio was replayed, saved, or modified.",
                severity: .warning
            )
        }

        let startStatus = resources.startIO()
        guard startStatus == noErr else {
            AppLogger.processTap.error("Helper probe setup failed: start IO status=\(ProcessTapCoreAudio.formatOSStatus(startStatus), privacy: .public) app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
            return ProcessTapTestResult(
                outcome: .tapSetupFailed,
                message: "Could not start helper audio probe",
                detail: "Start failed with \(ProcessTapCoreAudio.formatOSStatus(startStatus)). No audio was replayed, saved, or modified.",
                severity: .warning
            )
        }

        if let stopReason = publishProgress(
            from: accumulator,
            targetPID: pid,
            duration: duration,
            onProgress: onProgress
        ) {
            let cleanupErrors = resources.cleanup()
            didCleanUp = true

            if !cleanupErrors.isEmpty {
                AppLogger.cleanup.warning("Helper probe cleanup warning app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) warnings=\(cleanupErrors.joined(separator: ", "), privacy: .public)")
                return cleanupWarningResult(cleanupErrors)
            }

            AppLogger.processTap.info("Helper probe stopped app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) reason=\(String(describing: stopReason), privacy: .public)")
            return stoppedResult(for: stopReason)
        }

        let snapshot = accumulator.snapshot()
        onProgress(snapshot.progress)
        let cleanupErrors = resources.cleanup()
        didCleanUp = true

        guard cleanupErrors.isEmpty else {
            AppLogger.cleanup.warning("Helper probe cleanup warning app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) warnings=\(cleanupErrors.joined(separator: ", "), privacy: .public)")
            return cleanupWarningResult(cleanupErrors)
        }

        let result = diagnosticResult(for: target, snapshot: snapshot, duration: duration)
        AppLogger.processTap.info("Helper probe finished app=\(target.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) outcome=\(String(describing: result.outcome), privacy: .public) callbacks=\(snapshot.callbackCount, privacy: .public) peak=\(snapshot.peakLevel, privacy: .public) rms=\(snapshot.rmsLevel, privacy: .public)")
        return result
    }

    private func beginProbe() -> Bool {
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

    private func finishProbe() {
        lock.lock()
        isRunning = false
        requestedStopReason = nil
        lock.unlock()
    }

    private func currentStopReason() -> ProcessTapCandidateProbeStopReason? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return requestedStopReason
    }

    private func publishProgress(
        from accumulator: ProcessTapDiagnosticsAccumulator,
        targetPID: pid_t,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) -> ProcessTapCandidateProbeStopReason? {
        let deadline = Date().addingTimeInterval(duration)

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

    private func cleanupWarningResult(_ cleanupErrors: [String]) -> ProcessTapTestResult {
        ProcessTapTestResult(
            outcome: .tapCleanupFailed,
            message: "Helper probe cleanup reported a warning",
            detail: cleanupErrors.joined(separator: ", "),
            severity: .warning
        )
    }

    private func stoppedResult(for reason: ProcessTapCandidateProbeStopReason) -> ProcessTapTestResult {
        switch reason {
        case .userStopped:
            return ProcessTapTestResult(
                outcome: .helperProbeStopped,
                message: "Helper probe stopped",
                detail: "No audio was replayed, saved, or modified.",
                severity: .info
            )
        case .outputDeviceChanged:
            return ProcessTapTestResult(
                outcome: .helperProbeOutputChanged,
                message: "Helper probe stopped: output changed",
                detail: "Temporary probe resources were cleaned up.",
                severity: .warning
            )
        case .targetExited:
            return ProcessTapTestResult(
                outcome: .helperProbeTargetExited,
                message: "Helper probe stopped: process exited",
                detail: "Temporary probe resources were cleaned up.",
                severity: .warning
            )
        }
    }

    private func diagnosticResult(
        for target: ProcessTapTarget,
        snapshot: ProcessTapDiagnosticsSnapshot,
        duration: TimeInterval
    ) -> ProcessTapTestResult {
        guard snapshot.callbackCount > 0 else {
            return ProcessTapTestResult(
                outcome: .streamDiagnosticsNoCallbacks,
                message: "Tap created but no callbacks received",
                detail: "Listened for \(formattedDuration(duration)). No audio was saved or modified.",
                severity: .warning
            )
        }

        guard snapshot.measuredSampleCount > 0 else {
            return ProcessTapTestResult(
                outcome: .streamDiagnosticsLevelUnavailable,
                message: "Callbacks received; level unavailable",
                detail: "\(snapshot.callbackCount) callbacks. No readable Float32 samples were observed.",
                severity: .info
            )
        }

        let detail = "\(snapshot.callbackCount) callbacks, peak \(formatLevel(snapshot.peakLevel)), RMS \(formatLevel(snapshot.rmsLevel))."

        if snapshot.detectedNonSilentAudio {
            return ProcessTapTestResult(
                outcome: .streamDiagnosticsDetectedAudio,
                message: "Audio detected from \(target.appName)",
                detail: detail,
                severity: .info
            )
        }

        return ProcessTapTestResult(
            outcome: .streamDiagnosticsNoAudio,
            message: "No audio detected",
            detail: detail,
            severity: .info
        )
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.1fs", duration)
    }

    private func formatLevel(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
