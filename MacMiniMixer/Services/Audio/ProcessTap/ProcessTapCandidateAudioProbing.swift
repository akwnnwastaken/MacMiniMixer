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
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult {
        await Task.detached(priority: .userInitiated) {
            self.runProbe(for: target, onProgress: onProgress)
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
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) -> ProcessTapTestResult {
        guard beginProbe() else {
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
            return ProcessTapTestResult(
                outcome: .invalidTarget,
                message: "Invalid helper process",
                severity: .warning
            )
        }

        if #available(macOS 14.2, *) {
            guard ProcessTapCoreAudio.hasAudioCaptureUsageDescription else {
                return ProcessTapTestResult(
                    outcome: .missingUsageDescription,
                    message: "Missing audio capture usage description",
                    detail: "Add NSAudioCaptureUsageDescription before real tap setup.",
                    severity: .warning
                )
            }

            return attemptProbe(
                for: target,
                processIdentifier: processIdentifier,
                onProgress: onProgress
            )
        } else {
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
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) -> ProcessTapTestResult {
        let pid = pid_t(processIdentifier)
        let resources = ProcessTapResourceContext()
        var didCleanUp = false

        defer {
            if !didCleanUp {
                _ = resources.cleanup()
            }
        }

        guard let processObjectID = ProcessTapCoreAudio.processObjectID(for: pid) else {
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
            return ProcessTapTestResult(
                outcome: createStatus == kAudioDevicePermissionsError ? .permissionDenied : .tapSetupFailed,
                message: createStatus == kAudioDevicePermissionsError
                    ? "Audio capture permission was denied"
                    : "Could not create helper probe tap",
                detail: "Create failed with \(ProcessTapCoreAudio.formatOSStatus(createStatus)). No audio was replayed, saved, or modified.",
                severity: .warning
            )
        }

        guard let tapUID = resources.tapUID else {
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
            return ProcessTapTestResult(
                outcome: .tapSetupFailed,
                message: "Could not create helper probe device",
                detail: "Aggregate setup failed with \(ProcessTapCoreAudio.formatOSStatus(createAggregateStatus)). No audio was replayed, saved, or modified.",
                severity: .warning
            )
        }

        let accumulator = HelperProbeDiagnosticsAccumulator()
        let callbackQueue = DispatchQueue(label: "com.macminimixer.helper-audio-probe.callback")
        let ioBlock: AudioDeviceIOBlock = { _, inputData, _, _, _ in
            accumulator.observe(inputData)
        }

        let createIOProcStatus = resources.createIOProc(
            queue: callbackQueue,
            block: ioBlock
        )

        guard createIOProcStatus == noErr, resources.ioProcID != nil else {
            return ProcessTapTestResult(
                outcome: .tapSetupFailed,
                message: "Could not attach helper probe callback",
                detail: "IOProc setup failed with \(ProcessTapCoreAudio.formatOSStatus(createIOProcStatus)). No audio was replayed, saved, or modified.",
                severity: .warning
            )
        }

        let startStatus = resources.startIO()
        guard startStatus == noErr else {
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
            duration: AppConstants.processTapDiagnosticDuration,
            onProgress: onProgress
        ) {
            let cleanupErrors = resources.cleanup()
            didCleanUp = true

            if !cleanupErrors.isEmpty {
                return cleanupWarningResult(cleanupErrors)
            }

            return stoppedResult(for: stopReason)
        }

        let snapshot = accumulator.snapshot()
        onProgress(snapshot.progress)
        let cleanupErrors = resources.cleanup()
        didCleanUp = true

        guard cleanupErrors.isEmpty else {
            return cleanupWarningResult(cleanupErrors)
        }

        return diagnosticResult(for: target, snapshot: snapshot)
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
        from accumulator: HelperProbeDiagnosticsAccumulator,
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
        snapshot: HelperProbeDiagnosticsSnapshot
    ) -> ProcessTapTestResult {
        guard snapshot.callbackCount > 0 else {
            return ProcessTapTestResult(
                outcome: .streamDiagnosticsNoCallbacks,
                message: "Tap created but no callbacks received",
                detail: "Listened for \(formattedDuration). No audio was saved or modified.",
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

    private var formattedDuration: String {
        String(format: "%.1fs", AppConstants.processTapDiagnosticDuration)
    }

    private func formatLevel(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private struct HelperProbeDiagnosticsSnapshot {
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

private final class HelperProbeDiagnosticsAccumulator: @unchecked Sendable {
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

    func snapshot() -> HelperProbeDiagnosticsSnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }

        let rmsLevel = measuredSampleCount > 0
            ? sqrt(sumOfSquares / Double(measuredSampleCount))
            : 0

        return HelperProbeDiagnosticsSnapshot(
            callbackCount: callbackCount,
            measuredSampleCount: measuredSampleCount,
            peakLevel: peakLevel,
            rmsLevel: rmsLevel
        )
    }
}
