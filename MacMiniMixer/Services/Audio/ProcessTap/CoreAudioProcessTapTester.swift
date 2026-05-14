import CoreAudio
import Foundation

struct CoreAudioProcessTapTester: ProcessTapTesting {
    func testProcessTap(
        for target: ProcessTapTarget,
        mode: ProcessTapTestMode,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult {
        await Task.detached(priority: .userInitiated) {
            runProcessTapDiagnostics(for: target, mode: mode, onProgress: onProgress)
        }.value
    }

    private func runProcessTapDiagnostics(
        for target: ProcessTapTarget,
        mode: ProcessTapTestMode,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) -> ProcessTapTestResult {
        guard let processIdentifier = target.processIdentifier, processIdentifier > 0 else {
            return ProcessTapTestResult(
                outcome: .invalidTarget,
                message: "Select a real running app",
                detail: "Fallback/mock app rows do not have a process identifier.",
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

            return attemptTapSetup(
                for: target,
                mode: mode,
                processIdentifier: processIdentifier,
                onProgress: onProgress
            )
        } else {
            return ProcessTapTestResult(
                outcome: .unsupportedOS,
                message: "Process Tap not available on this macOS version",
                detail: "Core Audio Process Tap research requires macOS 14.2 or later.",
                severity: .warning
            )
        }
    }

    @available(macOS 14.2, *)
    private func attemptTapSetup(
        for target: ProcessTapTarget,
        mode: ProcessTapTestMode,
        processIdentifier: Int32,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) -> ProcessTapTestResult {
        let pid = pid_t(processIdentifier)
        let resources = ProcessTapResourceContext()

        defer {
            _ = resources.cleanup()
        }

        guard let processObjectID = ProcessTapCoreAudio.processObjectID(for: pid) else {
            return ProcessTapTestResult(
                outcome: .processNotFound,
                message: "Could not find Core Audio process",
                detail: "PID \(processIdentifier) did not map to a Core Audio process object.",
                severity: .warning
            )
        }

        let createStatus = resources.createProcessTap(
            processObjectID: processObjectID,
            name: mode.tapName(for: target.appName),
            muteBehavior: mode.tapMuteBehavior
        )

        guard createStatus == noErr, resources.tapID != kAudioObjectUnknown else {
            return ProcessTapTestResult(
                outcome: outcome(forCreateStatus: createStatus),
                message: message(forCreateStatus: createStatus),
                detail: "Create failed with \(ProcessTapCoreAudio.formatOSStatus(createStatus)). No audio was replayed, saved, or modified.",
                severity: .warning
            )
        }

        guard let tapUID = resources.tapUID else {
            return ProcessTapTestResult(
                outcome: .tapSetupFailed,
                message: "Could not read process tap UID",
                detail: "The tap was created, but diagnostics could not attach it to a temporary aggregate device.",
                severity: .warning
            )
        }

        let createAggregateStatus = resources.createPrivateAggregateDevice(
            name: mode.aggregateDeviceName,
            uidPrefix: mode.aggregateDeviceUIDPrefix,
            tapUID: tapUID
        )

        guard createAggregateStatus == noErr, resources.aggregateDeviceID != kAudioObjectUnknown else {
            return ProcessTapTestResult(
                outcome: .tapSetupFailed,
                message: "Could not create diagnostic tap device",
                detail: "Aggregate setup failed with \(ProcessTapCoreAudio.formatOSStatus(createAggregateStatus)). No audio was replayed, saved, or modified.",
                severity: .warning
            )
        }

        let accumulator = ProcessTapDiagnosticsAccumulator()
        let callbackQueue = DispatchQueue(label: "com.macminimixer.process-tap-diagnostic.callback")
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
                message: "Could not attach diagnostic callback",
                detail: "IOProc setup failed with \(ProcessTapCoreAudio.formatOSStatus(createIOProcStatus)). No audio was replayed, saved, or modified.",
                severity: .warning
            )
        }

        let startStatus = resources.startIO()
        guard startStatus == noErr else {
            return ProcessTapTestResult(
                outcome: .tapSetupFailed,
                message: mode.startFailureMessage,
                detail: "Start failed with \(ProcessTapCoreAudio.formatOSStatus(startStatus)). No audio was replayed, saved, or modified.",
                severity: .warning
            )
        }

        publishProgress(
            from: accumulator,
            duration: AppConstants.processTapDiagnosticDuration,
            onProgress: onProgress
        )

        let snapshot = accumulator.snapshot()
        onProgress(snapshot.progress)
        let cleanupErrors = resources.cleanup()

        guard cleanupErrors.isEmpty else {
            return ProcessTapTestResult(
                outcome: .tapCleanupFailed,
                message: "Diagnostics cleanup reported a warning",
                detail: cleanupErrors.joined(separator: ", "),
                severity: .warning
            )
        }

        return diagnosticResult(for: target, mode: mode, snapshot: snapshot)
    }

    private func outcome(forCreateStatus status: OSStatus) -> ProcessTapTestResult.Outcome {
        status == kAudioDevicePermissionsError ? .permissionDenied : .tapSetupFailed
    }

    private func message(forCreateStatus status: OSStatus) -> String {
        if status == kAudioDevicePermissionsError {
            return "Audio capture permission was denied"
        }

        return "Could not create process tap"
    }

    private func diagnosticResult(
        for target: ProcessTapTarget,
        mode: ProcessTapTestMode,
        snapshot: ProcessTapDiagnosticsSnapshot
    ) -> ProcessTapTestResult {
        guard snapshot.callbackCount > 0 else {
            return ProcessTapTestResult(
                outcome: mode.noCallbacksOutcome,
                message: mode.noCallbacksMessage,
                detail: mode.noCallbacksDetail(duration: formattedDuration),
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
                outcome: mode.audioDetectedOutcome,
                message: mode.audioDetectedMessage(for: target.appName),
                detail: mode.audioDetectedDetail(with: detail),
                severity: .info
            )
        }

        return ProcessTapTestResult(
            outcome: mode.noAudioOutcome,
            message: mode.noAudioMessage,
            detail: mode.noAudioDetail(with: detail),
            severity: .info
        )
    }

    private var formattedDuration: String {
        String(format: "%.1fs", AppConstants.processTapDiagnosticDuration)
    }

    private func formatLevel(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func publishProgress(
        from accumulator: ProcessTapDiagnosticsAccumulator,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) {
        let deadline = Date().addingTimeInterval(duration)

        while Date() < deadline {
            Thread.sleep(forTimeInterval: AppConstants.processTapLevelMeterUpdateInterval)
            onProgress(accumulator.snapshot().progress)
        }
    }
}

private extension ProcessTapTestMode {
    @available(macOS 14.2, *)
    var tapMuteBehavior: CATapMuteBehavior {
        switch self {
        case .diagnostics:
            return .unmuted
        case .muteBehaviorProbe:
            return .mutedWhenTapped
        }
    }

    func tapName(for appName: String) -> String {
        switch self {
        case .diagnostics:
            return "MacMiniMixer Process Tap Test - \(appName)"
        case .muteBehaviorProbe:
            return "MacMiniMixer Mute Probe - \(appName)"
        }
    }

    var aggregateDeviceName: String {
        switch self {
        case .diagnostics:
            return "MacMiniMixer Process Tap Diagnostic"
        case .muteBehaviorProbe:
            return "MacMiniMixer Process Tap Mute Probe"
        }
    }

    var aggregateDeviceUIDPrefix: String {
        switch self {
        case .diagnostics:
            return "com.macminimixer.process-tap-diagnostic"
        case .muteBehaviorProbe:
            return "com.macminimixer.process-tap-mute-probe"
        }
    }

    var startFailureMessage: String {
        switch self {
        case .diagnostics:
            return "Could not start Process Tap diagnostic"
        case .muteBehaviorProbe:
            return "Could not start mute behavior probe"
        }
    }

    var noCallbacksOutcome: ProcessTapTestResult.Outcome {
        switch self {
        case .diagnostics:
            return .streamDiagnosticsNoCallbacks
        case .muteBehaviorProbe:
            return .muteBehaviorProbeNoCallbacks
        }
    }

    var noCallbacksMessage: String {
        switch self {
        case .diagnostics:
            return "Tap created but no callbacks received"
        case .muteBehaviorProbe:
            return "Mute probe received no callbacks"
        }
    }

    func noCallbacksDetail(duration: String) -> String {
        switch self {
        case .diagnostics:
            return "Listened for \(duration). No audio was saved or modified."
        case .muteBehaviorProbe:
            return "Ran for \(duration). The selected app may have been briefly affected, then restored by cleanup."
        }
    }

    var audioDetectedOutcome: ProcessTapTestResult.Outcome {
        switch self {
        case .diagnostics:
            return .streamDiagnosticsDetectedAudio
        case .muteBehaviorProbe:
            return .muteBehaviorProbeDetectedAudio
        }
    }

    func audioDetectedMessage(for appName: String) -> String {
        switch self {
        case .diagnostics:
            return "Audio detected from \(appName)"
        case .muteBehaviorProbe:
            return "Mute probe completed; audio detected"
        }
    }

    func audioDetectedDetail(with diagnostics: String) -> String {
        switch self {
        case .diagnostics:
            return diagnostics
        case .muteBehaviorProbe:
            return "\(diagnostics) Original audio may have been suppressed while the tap was read."
        }
    }

    var noAudioOutcome: ProcessTapTestResult.Outcome {
        switch self {
        case .diagnostics:
            return .streamDiagnosticsNoAudio
        case .muteBehaviorProbe:
            return .muteBehaviorProbeNoAudio
        }
    }

    var noAudioMessage: String {
        switch self {
        case .diagnostics:
            return "No audio detected during test"
        case .muteBehaviorProbe:
            return "Mute probe completed; no audio detected"
        }
    }

    func noAudioDetail(with diagnostics: String) -> String {
        switch self {
        case .diagnostics:
            return diagnostics
        case .muteBehaviorProbe:
            return "\(diagnostics) No audio was replayed, saved, or modified."
        }
    }
}
