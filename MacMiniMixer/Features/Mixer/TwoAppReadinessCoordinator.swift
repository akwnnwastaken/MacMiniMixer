import Foundation

@MainActor
final class TwoAppReadinessCoordinator {
    private(set) var selectedAppAID: MixerAppItem.ID?
    private(set) var selectedAppBID: MixerAppItem.ID?
    private(set) var selectedGain: ProcessTapReplayGainOption
    private(set) var selectedDuration: ProcessTapTwoAppReadinessDurationOption
    private(set) var eligibilityByAppID: [MixerAppItem.ID: ProcessTapProcessEligibility]
    private(set) var snapshot: ProcessTapTwoAppReadinessSnapshot
    private(set) var result: ProcessTapTwoAppReadinessResult?
    private(set) var isRunning: Bool

    nonisolated private let tester: ProcessTapTwoAppReadinessTesting
    private let processTapEligibility: @Sendable (Int32?) -> ProcessTapProcessEligibility
    private var onWillChange: (@MainActor () -> Void)?

    init(
        tester: ProcessTapTwoAppReadinessTesting,
        initialApps: [MixerAppItem],
        processTapEligibility: @escaping @Sendable (Int32?) -> ProcessTapProcessEligibility = {
            ProcessTapCoreAudio.processTapEligibility(for: $0)
        },
        onWillChange: (@MainActor () -> Void)? = nil
    ) {
        self.tester = tester
        self.processTapEligibility = processTapEligibility
        self.onWillChange = onWillChange

        let initialEligibility = TwoAppReadinessState.eligibilityByAppID(
            for: initialApps,
            processTapEligibility: processTapEligibility
        )
        self.eligibilityByAppID = initialEligibility
        self.selectedAppAID = TwoAppReadinessState.preferredAppIDs(
            in: initialApps,
            eligibilityByAppID: initialEligibility
        ).appAID
        self.selectedAppBID = TwoAppReadinessState.preferredAppIDs(
            in: initialApps,
            eligibilityByAppID: initialEligibility
        ).appBID
        self.selectedGain = .defaultOption
        self.selectedDuration = .defaultOption
        self.snapshot = .empty
        self.result = nil
        self.isRunning = false
    }

    func setOnWillChange(_ onWillChange: (@MainActor () -> Void)?) {
        self.onWillChange = onWillChange
    }

    func targetOptions(
        apps: [MixerAppItem],
        advancedTarget: AdvancedProcessTapTarget?
    ) -> [TwoAppReadinessTargetOption] {
        TwoAppReadinessState.targetOptions(
            apps: apps,
            eligibilityByAppID: eligibilityByAppID,
            advancedProcessTapTarget: advancedTarget,
            processTapEligibility: processTapEligibility
        )
    }

    func selectAppA(_ appID: MixerAppItem.ID, targets: [TwoAppReadinessTargetOption]) {
        guard !isRunning,
              targets.contains(where: { $0.id == appID }) else {
            return
        }

        sendWillChange()
        selectedAppAID = appID
        result = nil
    }

    func selectAppB(_ appID: MixerAppItem.ID, targets: [TwoAppReadinessTargetOption]) {
        guard !isRunning,
              targets.contains(where: { $0.id == appID }) else {
            return
        }

        sendWillChange()
        selectedAppBID = appID
        result = nil
    }

    func selectGain(_ gain: ProcessTapReplayGainOption) {
        guard !isRunning else {
            return
        }

        sendWillChange()
        selectedGain = gain
        result = nil
    }

    func selectDuration(_ duration: ProcessTapTwoAppReadinessDurationOption) {
        guard !isRunning else {
            return
        }

        sendWillChange()
        selectedDuration = duration
        result = nil
    }

    func refreshEligibility(apps: [MixerAppItem]) {
        sendWillChange()
        eligibilityByAppID = TwoAppReadinessState.eligibilityByAppID(
            for: apps,
            processTapEligibility: processTapEligibility
        )
    }

    func refreshSelectionsAfterAppRefresh(targets: [TwoAppReadinessTargetOption]) {
        let targetIDs = Set(targets.map(\.id))
        let preferredIDs = TwoAppReadinessState.preferredTargetIDs(in: targets)

        if isRunning {
            if selectedAppAID.map({ !targetIDs.contains($0) }) == true ||
                selectedAppBID.map({ !targetIDs.contains($0) }) == true {
                stop(reason: .targetAppExited)
            }
            return
        }

        sendWillChange()
        if selectedAppAID.map({ !targetIDs.contains($0) }) != false {
            selectedAppAID = preferredIDs.appAID
        }

        if selectedAppBID.map({ !targetIDs.contains($0) }) != false ||
            selectedTargetsUseSameProcess(targets: targets) {
            selectedAppBID = preferredIDs.appBID
        }
    }

    func handleRemovedTarget(id removedTargetID: String?, targets: [TwoAppReadinessTargetOption]) {
        if let removedTargetID {
            sendWillChange()
            if selectedAppAID == removedTargetID {
                selectedAppAID = nil
            }

            if selectedAppBID == removedTargetID {
                selectedAppBID = nil
            }
        }

        guard !isRunning else {
            if removedTargetID != nil {
                stop(reason: .userStopped)
            }
            return
        }

        refreshSelectionsAfterAppRefresh(targets: targets)
    }

    func startTest(
        apps: [MixerAppItem],
        advancedTarget: AdvancedProcessTapTarget?,
        isProcessTapTesting: Bool,
        isLiveControlActive: Bool,
        isAppAudioTargetResolving: Bool,
        onWarning: @escaping @MainActor (String) -> Void
    ) {
        guard !isRunning else {
            return
        }

        guard !isProcessTapTesting,
              !isLiveControlActive,
              !isAppAudioTargetResolving else {
            setResult(
                ProcessTapTwoAppReadinessResult(
                    outcome: .setupFailed,
                    message: "Stop active Process Tap work first",
                    severity: .warning
                )
            )
            return
        }

        let targets = targetOptions(apps: apps, advancedTarget: advancedTarget)
        guard let appA = selectedTargetA(in: targets),
              let appB = selectedTargetB(in: targets) else {
            setResult(
                ProcessTapTwoAppReadinessResult(
                    outcome: .invalidTarget,
                    message: "Select two targets",
                    severity: .warning
                )
            )
            return
        }

        guard appA.id != appB.id else {
            setResult(
                ProcessTapTwoAppReadinessResult(
                    outcome: .invalidTarget,
                    message: "Choose two different apps",
                    severity: .warning
                )
            )
            return
        }

        guard TwoAppReadinessState.validProcessIdentifier(appA.processIdentifier),
              TwoAppReadinessState.validProcessIdentifier(appB.processIdentifier) else {
            setResult(
                ProcessTapTwoAppReadinessResult(
                    outcome: .invalidTarget,
                    message: "Both apps need valid processes",
                    severity: .warning
                )
            )
            return
        }

        guard appA.processIdentifier != appB.processIdentifier else {
            setResult(
                ProcessTapTwoAppReadinessResult(
                    outcome: .invalidTarget,
                    message: "Choose two different process targets",
                    severity: .warning
                )
            )
            return
        }

        let appAEligibility = processTapEligibility(appA.processIdentifier)
        let appBEligibility = processTapEligibility(appB.processIdentifier)
        guard appAEligibility.isEligible,
              appBEligibility.isEligible else {
            let reason = [appAEligibility.reason, appBEligibility.reason]
                .compactMap { $0 }
                .first
            setResult(
                ProcessTapTwoAppReadinessResult(
                    outcome: .setupFailed,
                    message: ProcessTapPermissionMessage.message(
                        forEligibilityReason: reason,
                        fallback: reason == ProcessTapCoreAudio.unsupportedOSMessage
                            ? "Process Tap is not available"
                            : "Core Audio process unavailable"
                    ),
                    detail: ProcessTapPermissionMessage.detail(forEligibilityReason: reason),
                    severity: .warning
                )
            )
            return
        }

        let targetA = appA.target
        let targetB = appB.target
        let gain = selectedGain
        let duration = selectedDuration

        sendWillChange()
        isRunning = true
        result = ProcessTapTwoAppReadinessResult(
            outcome: .starting,
            message: "Starting two-app test...",
            detail: "Gain \(gain.percentLabel), duration \(duration.label).",
            severity: .info
        )
        snapshot = TwoAppReadinessState.startingSnapshot(
            appA: targetA,
            appB: targetB,
            gain: gain
        )

        Task {
            let result = await tester.startTest(
                appA: targetA,
                appB: targetB,
                gain: gain,
                duration: duration.duration
            ) { [weak self] snapshot in
                Task { @MainActor in
                    self?.setSnapshot(snapshot)
                }
            } onFinished: { [weak self] result, snapshot in
                Task { @MainActor in
                    self?.handleFinished(result, snapshot: snapshot, onWarning: onWarning)
                }
            }

            await MainActor.run {
                self.result = result
                if result.outcome != .running {
                    self.isRunning = false
                }
                self.sendWillChange()
            }
        }
    }

    func stop(reason: ProcessTapLiveStopReason) {
        guard isRunning else {
            return
        }

        Task {
            let result = await tester.stopAll(reason: reason)

            await MainActor.run {
                if result.outcome == .notRunning {
                    self.handleFinished(result, snapshot: self.snapshot, onWarning: { _ in })
                }
            }
        }
    }

    @discardableResult
    func stopNow(reason: ProcessTapLiveStopReason) -> ProcessTapTwoAppReadinessResult? {
        let result = tester.stopAllNow(reason: reason)
        guard result != nil else {
            return nil
        }

        sendWillChange()
        isRunning = false
        return result
    }

    @discardableResult
    nonisolated func stopNowForTermination(reason: ProcessTapLiveStopReason) -> ProcessTapTwoAppReadinessResult? {
        tester.stopAllNow(reason: reason)
    }

    private func handleFinished(
        _ result: ProcessTapTwoAppReadinessResult,
        snapshot: ProcessTapTwoAppReadinessSnapshot,
        onWarning: @MainActor (String) -> Void
    ) {
        sendWillChange()
        self.result = result
        self.snapshot = snapshot
        isRunning = false

        if result.severity == .warning {
            onWarning(result.message)
        }
    }

    private func setResult(_ result: ProcessTapTwoAppReadinessResult) {
        sendWillChange()
        self.result = result
    }

    private func setSnapshot(_ snapshot: ProcessTapTwoAppReadinessSnapshot) {
        sendWillChange()
        self.snapshot = snapshot
    }

    private func selectedTargetA(in targets: [TwoAppReadinessTargetOption]) -> TwoAppReadinessTargetOption? {
        guard let selectedAppAID else {
            return nil
        }

        return targets.first { $0.id == selectedAppAID }
    }

    private func selectedTargetB(in targets: [TwoAppReadinessTargetOption]) -> TwoAppReadinessTargetOption? {
        guard let selectedAppBID else {
            return nil
        }

        return targets.first { $0.id == selectedAppBID }
    }

    private func selectedTargetsUseSameProcess(targets: [TwoAppReadinessTargetOption]) -> Bool {
        TwoAppReadinessState.targetsUseSameProcess(
            selectedTargetA(in: targets),
            selectedTargetB(in: targets)
        )
    }

    private func sendWillChange() {
        onWillChange?()
    }
}
