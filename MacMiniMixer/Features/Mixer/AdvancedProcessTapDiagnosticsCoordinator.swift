import Foundation

@MainActor
final class AdvancedProcessTapDiagnosticsCoordinator {
    private let processTapTester: ProcessTapTesting
    nonisolated private let processTapReplayProbe: ProcessTapReplayProbing
    private let processTapEligibility: @Sendable (Int32?) -> ProcessTapProcessEligibility
    private var onWillChange: (@MainActor () -> Void)?

    private(set) var selectedAppID: MixerAppItem.ID?
    private(set) var selectedReplayGain: ProcessTapReplayGainOption
    private(set) var result: ProcessTapTestResult?
    private(set) var progress: ProcessTapDiagnosticProgress?
    private(set) var isRunningDiagnostics = false
    private(set) var isReplayProbeRunning = false

    init(
        processTapTester: ProcessTapTesting,
        processTapReplayProbe: ProcessTapReplayProbing,
        initialApps: [MixerAppItem],
        processTapEligibility: @escaping @Sendable (Int32?) -> ProcessTapProcessEligibility = {
            ProcessTapCoreAudio.processTapEligibility(for: $0)
        },
        onWillChange: (@MainActor () -> Void)? = nil
    ) {
        self.processTapTester = processTapTester
        self.processTapReplayProbe = processTapReplayProbe
        self.processTapEligibility = processTapEligibility
        self.onWillChange = onWillChange
        self.selectedAppID = Self.preferredProcessTapAppID(in: initialApps)
        self.selectedReplayGain = .defaultOption
    }

    func setOnWillChange(_ onWillChange: (@MainActor () -> Void)?) {
        self.onWillChange = onWillChange
    }

    @discardableResult
    func selectApp(
        _ appID: MixerAppItem.ID,
        apps: [MixerAppItem],
        isLiveControlActive: Bool,
        isAppAudioTargetResolving: Bool
    ) -> Bool {
        guard !isLiveControlActive,
              !isAppAudioTargetResolving,
              apps.contains(where: { $0.id == appID }) else {
            return false
        }

        sendWillChange()
        selectedAppID = appID
        clearResultAndProgress(sendChange: false)
        return true
    }

    func selectPreferredAppAfterAppRefresh(apps: [MixerAppItem]) {
        sendWillChange()
        selectedAppID = Self.preferredProcessTapAppID(in: apps)
        clearResultAndProgress(sendChange: false)
    }

    func testSelectedProcessTapApp(
        apps: [MixerAppItem],
        advancedTarget: AdvancedProcessTapTarget?,
        isLiveControlActive: Bool,
        isTwoAppReadinessRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) {
        Task {
            await testSelectedProcessTapAppNow(
                apps: apps,
                advancedTarget: advancedTarget,
                isLiveControlActive: isLiveControlActive,
                isTwoAppReadinessRunning: isTwoAppReadinessRunning,
                isAppAudioTargetResolving: isAppAudioTargetResolving
            )
        }
    }

    func testSelectedProcessTapAppNow(
        apps: [MixerAppItem],
        advancedTarget: AdvancedProcessTapTarget?,
        isLiveControlActive: Bool,
        isTwoAppReadinessRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) async {
        await startProcessTapTest(
            mode: .diagnostics,
            apps: apps,
            advancedTarget: advancedTarget,
            isLiveControlActive: isLiveControlActive,
            isTwoAppReadinessRunning: isTwoAppReadinessRunning,
            isAppAudioTargetResolving: isAppAudioTargetResolving
        )
    }

    func testSelectedProcessTapMuteProbe(
        apps: [MixerAppItem],
        isLiveControlActive: Bool,
        isTwoAppReadinessRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) {
        Task {
            await testSelectedProcessTapMuteProbeNow(
                apps: apps,
                isLiveControlActive: isLiveControlActive,
                isTwoAppReadinessRunning: isTwoAppReadinessRunning,
                isAppAudioTargetResolving: isAppAudioTargetResolving
            )
        }
    }

    func testSelectedProcessTapMuteProbeNow(
        apps: [MixerAppItem],
        isLiveControlActive: Bool,
        isTwoAppReadinessRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) async {
        await startProcessTapTest(
            mode: .muteBehaviorProbe,
            apps: apps,
            advancedTarget: nil,
            isLiveControlActive: isLiveControlActive,
            isTwoAppReadinessRunning: isTwoAppReadinessRunning,
            isAppAudioTargetResolving: isAppAudioTargetResolving
        )
    }

    @discardableResult
    func selectReplayGain(
        _ gain: ProcessTapReplayGainOption,
        isLiveControlActive: Bool,
        isTwoAppReadinessRunning: Bool
    ) -> Bool {
        guard !isRunningDiagnostics,
              !isLiveControlActive,
              !isTwoAppReadinessRunning else {
            return false
        }

        sendWillChange()
        selectedReplayGain = gain
        clearResultAndProgress(sendChange: false)
        return true
    }

    func testSelectedReplayProbe(
        apps: [MixerAppItem],
        advancedTarget: AdvancedProcessTapTarget?,
        isLiveControlActive: Bool,
        isTwoAppReadinessRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) {
        Task {
            await testSelectedReplayProbeNow(
                apps: apps,
                advancedTarget: advancedTarget,
                isLiveControlActive: isLiveControlActive,
                isTwoAppReadinessRunning: isTwoAppReadinessRunning,
                isAppAudioTargetResolving: isAppAudioTargetResolving
            )
        }
    }

    func testSelectedReplayProbeNow(
        apps: [MixerAppItem],
        advancedTarget: AdvancedProcessTapTarget?,
        isLiveControlActive: Bool,
        isTwoAppReadinessRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) async {
        guard !isRunningDiagnostics,
              !isLiveControlActive,
              !isTwoAppReadinessRunning,
              !isAppAudioTargetResolving else {
            return
        }

        guard let target = replayProbeTarget(apps: apps, advancedTarget: advancedTarget) else {
            setResult(
                ProcessTapTestResult(
                    outcome: .invalidTarget,
                    message: "Select a running app or Advanced target",
                    severity: .warning
                )
            )
            return
        }

        if advancedTarget != nil {
            let eligibility = processTapEligibility(target.processIdentifier)
            guard eligibility.isEligible else {
                setResult(
                    ProcessTapTestResult(
                        outcome: .processNotFound,
                        message: "Advanced target unavailable",
                        detail: ProcessTapPermissionMessage.detail(forEligibilityReason: eligibility.reason)
                            ?? "Core Audio process unavailable",
                        severity: .warning
                    )
                )
                return
            }
        }

        beginRunningReplayProbe(for: target, advancedTarget: advancedTarget)

        let replayGain = selectedReplayGain
        let result = await processTapReplayProbe.runReplayProbe(for: target, gain: replayGain) { [weak self] progress in
            Task { @MainActor in
                self?.setProgress(progress)
            }
        }

        setResult(result.testResult)
        setProgress(nil)
        setRunning(false)
        setReplayProbeRunning(false)
    }

    nonisolated func stopReplayProbe(reason: ProcessTapReplayProbeStopReason) {
        processTapReplayProbe.stopCurrentReplayProbe(reason: reason)
    }

    func stopReplayProbeForTermination() {
        processTapReplayProbe.stopCurrentReplayProbe(reason: .userStopped)
        setReplayProbeRunning(false)
        setRunning(false)
    }

    func setResult(_ result: ProcessTapTestResult?) {
        sendWillChange()
        self.result = result
    }

    func setProgress(_ progress: ProcessTapDiagnosticProgress?) {
        sendWillChange()
        self.progress = progress
    }

    func setRunning(_ isRunning: Bool) {
        sendWillChange()
        isRunningDiagnostics = isRunning
    }

    func clearResultAndProgress() {
        sendWillChange()
        clearResultAndProgress(sendChange: false)
    }

    static func preferredProcessTapAppID(in apps: [MixerAppItem]) -> MixerAppItem.ID? {
        apps.first { $0.isEligibleForExperimentalLiveControl }?.id ?? apps.first?.id
    }

    private func startProcessTapTest(
        mode: ProcessTapTestMode,
        apps: [MixerAppItem],
        advancedTarget: AdvancedProcessTapTarget?,
        isLiveControlActive: Bool,
        isTwoAppReadinessRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) async {
        guard !isRunningDiagnostics,
              !isLiveControlActive,
              !isTwoAppReadinessRunning,
              !isAppAudioTargetResolving else {
            return
        }

        guard let target = processTapTarget(for: mode, apps: apps, advancedTarget: advancedTarget) else {
            setResult(
                ProcessTapTestResult(
                    outcome: .invalidTarget,
                    message: "Select a running app or Advanced target",
                    severity: .warning
                )
            )
            return
        }

        if mode == .diagnostics, advancedTarget != nil {
            let eligibility = processTapEligibility(target.processIdentifier)
            guard eligibility.isEligible else {
                setResult(
                    ProcessTapTestResult(
                        outcome: .processNotFound,
                        message: "Advanced target unavailable",
                        detail: ProcessTapPermissionMessage.detail(forEligibilityReason: eligibility.reason)
                            ?? "Core Audio process unavailable",
                        severity: .warning
                    )
                )
                return
            }
        }

        beginRunningTest(for: target, mode: mode)

        let result = await processTapTester.testProcessTap(for: target, mode: mode) { [weak self] progress in
            Task { @MainActor in
                self?.setProgress(progress)
            }
        }

        setResult(result)
        setProgress(nil)
        setRunning(false)
    }

    private func beginRunningTest(for target: ProcessTapTarget, mode: ProcessTapTestMode) {
        sendWillChange()
        result = ProcessTapTestResult(
            outcome: .streamDiagnosticsRunning,
            message: mode.runningMessage(for: target.appName),
            detail: mode.runningDetail,
            severity: .info
        )
        progress = ProcessTapDiagnosticProgress(
            callbackCount: 0,
            peakLevel: 0,
            rmsLevel: 0,
            audioDetected: false
        )
        isRunningDiagnostics = true
    }

    private func beginRunningReplayProbe(for target: ProcessTapTarget, advancedTarget: AdvancedProcessTapTarget?) {
        sendWillChange()
        result = ProcessTapTestResult(
            outcome: .replayProbeRunning,
            message: "Replay testing \(target.appName)...",
            detail: replayProbeRunningDetail(advancedTarget: advancedTarget),
            severity: .info
        )
        progress = ProcessTapDiagnosticProgress(
            callbackCount: 0,
            peakLevel: 0,
            rmsLevel: 0,
            audioDetected: false
        )
        isRunningDiagnostics = true
        isReplayProbeRunning = true
    }

    private func processTapTarget(
        for mode: ProcessTapTestMode,
        apps: [MixerAppItem],
        advancedTarget: AdvancedProcessTapTarget?
    ) -> ProcessTapTarget? {
        if mode == .diagnostics, let advancedTarget {
            return advancedTarget.target
        }

        guard let selectedApp = selectedProcessTapApp(in: apps) else {
            return nil
        }

        return ProcessTapTarget(
            appID: selectedApp.id,
            appName: selectedApp.name,
            processIdentifier: selectedApp.processIdentifier
        )
    }

    private func replayProbeTarget(
        apps: [MixerAppItem],
        advancedTarget: AdvancedProcessTapTarget?
    ) -> ProcessTapTarget? {
        if let advancedTarget {
            return advancedTarget.target
        }

        guard let selectedApp = selectedProcessTapApp(in: apps) else {
            return nil
        }

        return ProcessTapTarget(
            appID: selectedApp.id,
            appName: selectedApp.name,
            processIdentifier: selectedApp.processIdentifier
        )
    }

    private func replayProbeRunningDetail(advancedTarget: AdvancedProcessTapTarget?) -> String {
        if advancedTarget != nil {
            return "Experimental: may briefly mute/replay selected helper audio. Gain \(selectedReplayGain.percentLabel)."
        }

        return "Experimental: may briefly mute/replay selected app audio. Gain \(selectedReplayGain.percentLabel)."
    }

    private func selectedProcessTapApp(in apps: [MixerAppItem]) -> MixerAppItem? {
        guard let selectedAppID else {
            return nil
        }

        return apps.first { $0.id == selectedAppID }
    }

    private func clearResultAndProgress(sendChange: Bool) {
        if sendChange {
            sendWillChange()
        }
        result = nil
        progress = nil
    }

    private func setReplayProbeRunning(_ isRunning: Bool) {
        sendWillChange()
        isReplayProbeRunning = isRunning
    }

    private func sendWillChange() {
        onWillChange?()
    }
}

private extension ProcessTapTestMode {
    func runningMessage(for appName: String) -> String {
        switch self {
        case .diagnostics:
            return "Testing Process Tap for \(appName)..."
        case .muteBehaviorProbe:
            return "Running mute probe for \(appName)..."
        }
    }

    var runningDetail: String {
        switch self {
        case .diagnostics:
            return "Listening briefly for callbacks. No audio will be saved or modified."
        case .muteBehaviorProbe:
            return "This may briefly mute the selected app. No audio will be replayed or saved."
        }
    }
}
