import AppKit
import Foundation

struct TwoAppReadinessTargetOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let target: ProcessTapTarget
    let eligibility: ProcessTapProcessEligibility
    let isHelper: Bool

    var processIdentifier: Int32? {
        target.processIdentifier
    }
}

@MainActor
final class MixerViewModel: ObservableObject {
    @Published private(set) var apps: [MixerAppItem]
    @Published private(set) var statusMessage: MixerStatusMessage?
    @Published private(set) var processTapLiveDiagnostics: ProcessTapLiveDiagnostics?
    @Published private(set) var isProcessTapLiveControlActive = false
    @Published private(set) var selectedTwoAppReadinessAppAID: MixerAppItem.ID?
    @Published private(set) var selectedTwoAppReadinessAppBID: MixerAppItem.ID?
    @Published private(set) var selectedTwoAppReadinessGain: ProcessTapReplayGainOption
    @Published private(set) var twoAppReadinessEligibilityByAppID: [MixerAppItem.ID: ProcessTapProcessEligibility]
    @Published private(set) var twoAppReadinessSnapshot = ProcessTapTwoAppReadinessSnapshot.empty
    @Published private(set) var twoAppReadinessResult: ProcessTapTwoAppReadinessResult?
    @Published private(set) var isTwoAppReadinessRunning = false
    @Published private(set) var appAudioResolutionStateByAppID: [MixerAppItem.ID: AppAudioResolutionState] = [:]
    @Published private(set) var activeExperimentalAppID: MixerAppItem.ID?
    @Published private(set) var activeLiveControlAppName: String?
    @Published private(set) var showAllApps = false
    @Published private(set) var isExperimentalRealAppControlEnabled = false

    private let applicationLister: ApplicationListing
    private let audioController: AudioControlling
    private let systemOutput: SystemOutputCoordinator
    private let advancedProcessTapDiagnostics: AdvancedProcessTapDiagnosticsCoordinator
    private let processTapLiveController: ProcessTapLiveControlling
    private let twoAppReadinessTester: ProcessTapTwoAppReadinessTesting
    private let helperProcessAudioProbe: ProcessTapCandidateAudioProbing
    private let advancedHelperDiscovery: AdvancedHelperDiscoveryCoordinator
    private let appAudioTargetResolver: AppAudioTargetResolving
    private let processTapEligibility: @Sendable (Int32?) -> ProcessTapProcessEligibility
    private var appAudioResolutionTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    init(
        applicationLister: ApplicationListing,
        audioController: AudioControlling,
        outputDeviceLister: OutputDeviceListing,
        outputDeviceController: OutputDeviceControlling,
        systemVolumeReader: SystemVolumeReading,
        systemVolumeController: SystemVolumeControlling,
        processTapTester: ProcessTapTesting,
        processTapReplayProbe: ProcessTapReplayProbing,
        processTapLiveController: ProcessTapLiveControlling,
        twoAppReadinessTester: ProcessTapTwoAppReadinessTesting,
        helperProcessAudioProbe: ProcessTapCandidateAudioProbing,
        appAudioTargetResolver: AppAudioTargetResolving,
        processLister: ProcessListing,
        processTapEligibility: @escaping @Sendable (Int32?) -> ProcessTapProcessEligibility = {
            ProcessTapCoreAudio.processTapEligibility(for: $0)
        }
    ) {
        self.applicationLister = applicationLister
        self.audioController = audioController
        self.processTapLiveController = processTapLiveController
        self.twoAppReadinessTester = twoAppReadinessTester
        self.helperProcessAudioProbe = helperProcessAudioProbe
        self.appAudioTargetResolver = appAudioTargetResolver
        self.processTapEligibility = processTapEligibility

        let initialApps = applicationLister.listApplications()
        let initialTwoAppReadinessEligibility = Self.twoAppReadinessEligibility(
            for: initialApps,
            processTapEligibility: processTapEligibility
        )
        self.systemOutput = SystemOutputCoordinator(
            audioController: audioController,
            outputDeviceLister: outputDeviceLister,
            outputDeviceController: outputDeviceController,
            systemVolumeReader: systemVolumeReader,
            systemVolumeController: systemVolumeController
        )
        self.advancedProcessTapDiagnostics = AdvancedProcessTapDiagnosticsCoordinator(
            processTapTester: processTapTester,
            processTapReplayProbe: processTapReplayProbe,
            initialApps: initialApps,
            processTapEligibility: processTapEligibility
        )
        self.advancedHelperDiscovery = AdvancedHelperDiscoveryCoordinator(
            processLister: processLister,
            helperProcessAudioProbe: helperProcessAudioProbe,
            initialApps: initialApps,
            processTapEligibility: { processTapEligibility($0) }
        )
        self.apps = initialApps
        self.twoAppReadinessEligibilityByAppID = initialTwoAppReadinessEligibility
        self.selectedTwoAppReadinessAppAID = Self.preferredTwoAppReadinessAppIDs(
            in: initialApps,
            eligibilityByAppID: initialTwoAppReadinessEligibility
        ).appAID
        self.selectedTwoAppReadinessAppBID = Self.preferredTwoAppReadinessAppIDs(
            in: initialApps,
            eligibilityByAppID: initialTwoAppReadinessEligibility
        ).appBID
        self.selectedTwoAppReadinessGain = .defaultOption

        systemOutput.setOnWillChange { [weak self] in
            self?.objectWillChange.send()
        }
        advancedProcessTapDiagnostics.setOnWillChange { [weak self] in
            self?.objectWillChange.send()
        }
        advancedHelperDiscovery.setOnWillChange { [weak self] in
            self?.objectWillChange.send()
        }
        advancedHelperDiscovery.setOnAdvancedTargetChanged { [weak self] removedTargetID in
            self?.advancedProcessTapDiagnostics.clearResultAndProgress()
            self?.refreshTwoAppReadinessSelectionsAfterTargetChange(removedTargetID: removedTargetID)
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopProcessTapLiveControlForTermination()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }

        _ = processTapLiveController.stopLiveControlNow(reason: .appTerminating)
        _ = twoAppReadinessTester.stopAllNow(reason: .appTerminating)
        appAudioResolutionTask?.cancel()
        appAudioTargetResolver.cancelCurrentResolution(reason: .userStopped)
        appAudioTargetResolver.invalidateAllCachedTargets()
        helperProcessAudioProbe.stopCurrentProbe(reason: .userStopped)
        advancedProcessTapDiagnostics.stopReplayProbe(reason: .userStopped)
    }

    var systemVolume: Double {
        systemOutput.systemVolume
    }

    var outputDevices: [OutputDeviceItem] {
        systemOutput.outputDevices
    }

    var selectedOutputDeviceID: OutputDeviceItem.ID {
        systemOutput.selectedOutputDeviceID
    }

    var isSystemOutputMuted: Bool {
        systemOutput.isSystemOutputMuted
    }

    var selectedOutputDeviceName: String {
        systemOutput.selectedOutputDeviceName
    }

    var selectedProcessTapAppID: MixerAppItem.ID? {
        advancedProcessTapDiagnostics.selectedAppID
    }

    var selectedProcessTapReplayGain: ProcessTapReplayGainOption {
        advancedProcessTapDiagnostics.selectedReplayGain
    }

    var processTapTestResult: ProcessTapTestResult? {
        advancedProcessTapDiagnostics.result
    }

    var processTapDiagnosticProgress: ProcessTapDiagnosticProgress? {
        advancedProcessTapDiagnostics.progress
    }

    var isProcessTapTesting: Bool {
        advancedProcessTapDiagnostics.isRunningDiagnostics
    }

    var selectedHelperDiscoveryAppID: MixerAppItem.ID? {
        advancedHelperDiscovery.selectedAppID
    }

    var helperProcessCandidates: [HelperProcessCandidate] {
        advancedHelperDiscovery.candidates
    }

    var helperProcessDiscoveryMessage: String? {
        advancedHelperDiscovery.message
    }

    var isHelperProcessDiscoveryScanning: Bool {
        advancedHelperDiscovery.isScanning
    }

    var isHelperProcessAutoDetectRunning: Bool {
        advancedHelperDiscovery.isAutoDetectRunning
    }

    var helperProcessAutoDetectProgressText: String? {
        advancedHelperDiscovery.autoDetectProgressText
    }

    var advancedProcessTapTarget: AdvancedProcessTapTarget? {
        advancedHelperDiscovery.advancedTarget
    }

    var helperProcessProbeResultsByPID: [Int32: ProcessTapTestResult] {
        advancedHelperDiscovery.probeResultsByPID
    }

    var helperProcessProbeProgressByPID: [Int32: ProcessTapDiagnosticProgress] {
        advancedHelperDiscovery.probeProgressByPID
    }

    var helperProcessProbeRunningPID: Int32? {
        advancedHelperDiscovery.runningProbePID
    }

    var visibleMixerApps: [MixerAppItem] {
        if showAllApps {
            return apps
        }

        return apps.filter { app in
            app.isLikelyAudioRelevant ||
                isActiveLiveControlTarget(app.id) ||
                isResolvingExperimentalControl(for: app.id)
        }
    }

    var twoAppReadinessTargets: [TwoAppReadinessTargetOption] {
        let appTargets = apps.compactMap { app -> TwoAppReadinessTargetOption? in
            guard twoAppReadinessEligibilityByAppID[app.id]?.isEligible == true else {
                return nil
            }

            return TwoAppReadinessTargetOption(
                id: app.id,
                title: app.name,
                detail: app.processIdentifier.map { "PID \($0)" },
                target: ProcessTapTarget(
                    appID: app.id,
                    appName: app.name,
                    processIdentifier: app.processIdentifier
                ),
                eligibility: twoAppReadinessEligibilityByAppID[app.id] ?? .unavailable("Core Audio process unavailable"),
                isHelper: false
            )
        }

        guard let advancedProcessTapTarget else {
            return appTargets
        }

        let helperEligibility = processTapEligibility(advancedProcessTapTarget.target.processIdentifier)
        guard helperEligibility.isEligible else {
            return appTargets
        }

        let helperTarget = TwoAppReadinessTargetOption(
            id: advancedProcessTapTarget.id,
            title: advancedProcessTapTarget.twoAppReadinessTitle,
            detail: advancedProcessTapTarget.detail,
            target: ProcessTapTarget(
                appID: advancedProcessTapTarget.target.appID,
                appName: advancedProcessTapTarget.twoAppReadinessTitle,
                processIdentifier: advancedProcessTapTarget.target.processIdentifier
            ),
            eligibility: helperEligibility,
            isHelper: true
        )

        return appTargets + [helperTarget]
    }

    func setShowAllApps(_ showAllApps: Bool) {
        self.showAllApps = showAllApps
    }

    func setExperimentalRealAppControlEnabled(_ isEnabled: Bool) {
        isExperimentalRealAppControlEnabled = isEnabled

        if !isEnabled, isProcessTapLiveControlActive {
            stopProcessTapLiveControl()
        }

        if !isEnabled {
            cancelAppAudioTargetResolution(reason: .userStopped)
            appAudioTargetResolver.invalidateAllCachedTargets()
        }
    }

    private func isActiveLiveControlTarget(_ appID: MixerAppItem.ID) -> Bool {
        appID == activeExperimentalAppID ||
            (isProcessTapLiveControlActive && appID == selectedProcessTapAppID)
    }

    func setSystemVolume(_ volume: Double) {
        systemOutput.setSystemVolume(volume)
    }

    func finishSystemVolumeEditing() {
        if let message = systemOutput.finishSystemVolumeEditing() {
            showStatus(message, style: .warning)
        }
    }

    func toggleSystemOutputMuted() {
        if let message = systemOutput.toggleSystemOutputMuted() {
            showStatus(message, style: .warning)
        }
    }

    func selectOutputDevice(_ deviceID: OutputDeviceItem.ID) {
        switch systemOutput.selectOutputDevice(deviceID) {
        case .selected:
            refreshOutputDevices()
            refreshSystemOutputVolume()
        case .failed(let message):
            showStatus(message, style: .warning)
        case .notFound:
            return
        }
    }

    func refreshOutputDevices() {
        let refreshResult = systemOutput.refreshOutputDevices()

        if isProcessTapLiveControlActive,
           refreshResult.didOutputDeviceChange {
            AppLogger.audio.warning("Output device change stopping live control previousDefault=\(refreshResult.previousDefaultDeviceID ?? "none", privacy: .public) currentDefault=\(refreshResult.currentDefaultDeviceID ?? "none", privacy: .public)")
            stopProcessTapLiveControl(reason: .outputDeviceChanged)
        }

        if isTwoAppReadinessRunning,
           refreshResult.didOutputDeviceChange {
            AppLogger.audio.warning("Output device change stopping two-app readiness previousDefault=\(refreshResult.previousDefaultDeviceID ?? "none", privacy: .public) currentDefault=\(refreshResult.currentDefaultDeviceID ?? "none", privacy: .public)")
            stopTwoAppReadiness(reason: .outputDeviceChanged)
        }

        if (helperProcessProbeRunningPID != nil || isHelperProcessAutoDetectRunning),
           refreshResult.didOutputDeviceChange {
            AppLogger.audio.warning("Output device change stopping helper probe previousDefault=\(refreshResult.previousDefaultDeviceID ?? "none", privacy: .public) currentDefault=\(refreshResult.currentDefaultDeviceID ?? "none", privacy: .public)")
            stopHelperProcessProbe(reason: .outputDeviceChanged)
        }

        if isAppAudioTargetResolving,
           refreshResult.didOutputDeviceChange {
            AppLogger.audio.warning("Output device change cancelling app audio resolution previousDefault=\(refreshResult.previousDefaultDeviceID ?? "none", privacy: .public) currentDefault=\(refreshResult.currentDefaultDeviceID ?? "none", privacy: .public)")
            cancelAppAudioTargetResolution(reason: .outputDeviceChanged)
        }

        if advancedProcessTapDiagnostics.isReplayProbeRunning,
           refreshResult.didOutputDeviceChange {
            AppLogger.audio.warning("Output device change stopping replay probe previousDefault=\(refreshResult.previousDefaultDeviceID ?? "none", privacy: .public) currentDefault=\(refreshResult.currentDefaultDeviceID ?? "none", privacy: .public)")
            advancedProcessTapDiagnostics.stopReplayProbe(reason: .outputDeviceChanged)
        }

        if refreshResult.didOutputDeviceChange {
            appAudioTargetResolver.invalidateAllCachedTargets()
            refreshSystemOutputVolume()
        }
    }

    func refreshSystemOutputVolume() {
        systemOutput.refreshSystemOutputVolume()
    }

    func selectProcessTapApp(_ appID: MixerAppItem.ID) {
        guard advancedProcessTapDiagnostics.selectApp(
            appID,
            apps: apps,
            isLiveControlActive: isProcessTapLiveControlActive,
            isAppAudioTargetResolving: isAppAudioTargetResolving
        ) else {
            return
        }

        _ = advancedHelperDiscovery.clearAdvancedTarget(notify: false)
    }

    func selectTwoAppReadinessAppA(_ appID: MixerAppItem.ID) {
        guard !isTwoAppReadinessRunning,
              twoAppReadinessTargets.contains(where: { $0.id == appID }) else {
            return
        }

        selectedTwoAppReadinessAppAID = appID
        twoAppReadinessResult = nil
    }

    func selectTwoAppReadinessAppB(_ appID: MixerAppItem.ID) {
        guard !isTwoAppReadinessRunning,
              twoAppReadinessTargets.contains(where: { $0.id == appID }) else {
            return
        }

        selectedTwoAppReadinessAppBID = appID
        twoAppReadinessResult = nil
    }

    func selectTwoAppReadinessGain(_ gain: ProcessTapReplayGainOption) {
        guard !isTwoAppReadinessRunning else {
            return
        }

        selectedTwoAppReadinessGain = gain
        twoAppReadinessResult = nil
    }

    func selectHelperDiscoveryApp(_ appID: MixerAppItem.ID) {
        advancedHelperDiscovery.selectApp(
            appID,
            apps: apps,
            isAutoDetectRunning: isHelperProcessAutoDetectRunning,
            isAppAudioTargetResolving: isAppAudioTargetResolving
        )
    }

    func scanHelperProcesses() {
        advancedHelperDiscovery.scanHelperProcesses(
            apps: apps,
            isAutoDetectRunning: isHelperProcessAutoDetectRunning,
            isAppAudioTargetResolving: isAppAudioTargetResolving
        )
    }

    func useHelperCandidateAsAdvancedTarget(_ processIdentifier: Int32) {
        guard !isAppAudioTargetResolving else {
            return
        }

        _ = advancedHelperDiscovery.useCandidateAsAdvancedTarget(processIdentifier)
    }

    func clearAdvancedProcessTapTarget() {
        let removedTargetID = advancedProcessTapTarget?.id

        if isHelperProcessAutoDetectRunning {
            stopHelperProcessAutoDetect(reason: .userStopped)
        }

        if isTwoAppReadinessRunning {
            stopTwoAppReadiness(reason: .userStopped)
        }

        _ = advancedHelperDiscovery.clearAdvancedTarget(notify: false)
        advancedProcessTapDiagnostics.clearResultAndProgress()
        refreshTwoAppReadinessSelectionsAfterTargetChange(removedTargetID: removedTargetID)
    }

    func probeHelperProcessCandidate(_ processIdentifier: Int32) {
        advancedHelperDiscovery.probeHelperProcessCandidate(
            processIdentifier,
            isAutoDetectRunning: isHelperProcessAutoDetectRunning,
            isAppAudioTargetResolving: isAppAudioTargetResolving
        )
    }

    func autoDetectHelperProcessCandidate() {
        advancedHelperDiscovery.autoDetectHelperProcessCandidate(
            isAppAudioTargetResolving: isAppAudioTargetResolving
        )
    }

    func testSelectedProcessTapApp() {
        advancedProcessTapDiagnostics.testSelectedProcessTapApp(
            apps: apps,
            advancedTarget: advancedProcessTapTarget,
            isLiveControlActive: isProcessTapLiveControlActive,
            isTwoAppReadinessRunning: isTwoAppReadinessRunning,
            isAppAudioTargetResolving: isAppAudioTargetResolving
        )
    }

    func testSelectedProcessTapMuteProbe() {
        advancedProcessTapDiagnostics.testSelectedProcessTapMuteProbe(
            apps: apps,
            isLiveControlActive: isProcessTapLiveControlActive,
            isTwoAppReadinessRunning: isTwoAppReadinessRunning,
            isAppAudioTargetResolving: isAppAudioTargetResolving
        )
    }

    func selectProcessTapReplayGain(_ gain: ProcessTapReplayGainOption) {
        advancedProcessTapDiagnostics.selectReplayGain(
            gain,
            isLiveControlActive: isProcessTapLiveControlActive,
            isTwoAppReadinessRunning: isTwoAppReadinessRunning
        )
    }

    func testSelectedProcessTapReplayProbe() {
        advancedProcessTapDiagnostics.testSelectedReplayProbe(
            apps: apps,
            advancedTarget: advancedProcessTapTarget,
            isLiveControlActive: isProcessTapLiveControlActive,
            isTwoAppReadinessRunning: isTwoAppReadinessRunning,
            isAppAudioTargetResolving: isAppAudioTargetResolving
        )
    }

    func startProcessTapLiveControl() {
        guard !isProcessTapTesting,
              !isProcessTapLiveControlActive,
              !isTwoAppReadinessRunning,
              !isAppAudioTargetResolving else {
            return
        }

        guard let app = selectedProcessTapApp else {
            advancedProcessTapDiagnostics.setResult(
                ProcessTapTestResult(
                    outcome: .invalidTarget,
                    message: "Select a running app",
                    severity: .warning
                )
            )
            return
        }

        let target = ProcessTapTarget(
            appID: app.id,
            appName: app.name,
            processIdentifier: app.processIdentifier
        )
        let gain = selectedProcessTapReplayGain

        advancedProcessTapDiagnostics.setResult(
            ProcessTapTestResult(
                outcome: .liveControlStarting,
                message: "Starting live control for \(app.name)...",
                detail: "Experimental: original output is suppressed and replayed with gain \(gain.percentLabel).",
                severity: .info
            )
        )
        advancedProcessTapDiagnostics.setProgress(
            ProcessTapDiagnosticProgress(
                callbackCount: 0,
                peakLevel: 0,
                rmsLevel: 0,
                audioDetected: false
            )
        )
        processTapLiveDiagnostics = nil
        advancedProcessTapDiagnostics.setRunning(true)

        Task {
            let result = await processTapLiveController.startLiveControl(
                for: target,
                gain: gain
            ) { diagnostics in
                Task { @MainActor in
                    self.processTapLiveDiagnostics = diagnostics
                    self.advancedProcessTapDiagnostics.setProgress(diagnostics.progress)
                }
            } onStopped: { result, diagnostics in
                Task { @MainActor in
                    self.handleLiveControlStopped(result, diagnostics: diagnostics)
                }
            }

            await MainActor.run {
                advancedProcessTapDiagnostics.setResult(result)
                advancedProcessTapDiagnostics.setRunning(false)

                if result.outcome == .liveControlStarted {
                    isProcessTapLiveControlActive = true
                    activeLiveControlAppName = app.name
                } else {
                    processTapLiveDiagnostics = nil
                    advancedProcessTapDiagnostics.setProgress(nil)
                    activeLiveControlAppName = nil
                    showLiveControlWarningIfNeeded(for: result)
                }
            }
        }
    }

    func stopProcessTapLiveControl() {
        stopProcessTapLiveControl(reason: .userStopped)
    }

    private func stopProcessTapLiveControl(reason: ProcessTapLiveStopReason) {
        guard isProcessTapLiveControlActive || isProcessTapTesting else {
            return
        }

        Task {
            let result = await processTapLiveController.stopLiveControl(reason: reason)

            await MainActor.run {
                if result.outcome == .liveControlNotActive {
                    handleLiveControlStopped(result, diagnostics: processTapLiveDiagnostics)
                }
            }
        }
    }

    func stopProcessTapLiveControlForTermination() {
        _ = processTapLiveController.stopLiveControlNow(reason: .appTerminating)
        _ = twoAppReadinessTester.stopAllNow(reason: .appTerminating)
        advancedHelperDiscovery.stopAutoDetect(reason: .userStopped)
        appAudioResolutionTask?.cancel()
        appAudioTargetResolver.cancelCurrentResolution(reason: .userStopped)
        appAudioTargetResolver.invalidateAllCachedTargets()
        advancedHelperDiscovery.stopProbe(reason: .userStopped)
        advancedProcessTapDiagnostics.stopReplayProbeForTermination()
        isProcessTapLiveControlActive = false
        appAudioResolutionStateByAppID = [:]
        activeExperimentalAppID = nil
        activeLiveControlAppName = nil
        isTwoAppReadinessRunning = false
    }

    func startTwoAppReadinessTest() {
        guard !isTwoAppReadinessRunning else {
            return
        }

        guard !isProcessTapTesting,
              !isProcessTapLiveControlActive,
              !isAppAudioTargetResolving else {
            twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
                outcome: .setupFailed,
                message: "Stop active Process Tap work first",
                severity: .warning
            )
            return
        }

        guard let appA = selectedTwoAppReadinessTargetA,
              let appB = selectedTwoAppReadinessTargetB else {
            twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
                outcome: .invalidTarget,
                message: "Select two targets",
                severity: .warning
            )
            return
        }

        guard appA.id != appB.id else {
            twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
                outcome: .invalidTarget,
                message: "Choose two different apps",
                severity: .warning
            )
            return
        }

        guard validProcessIdentifier(appA.processIdentifier),
              validProcessIdentifier(appB.processIdentifier) else {
            twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
                outcome: .invalidTarget,
                message: "Both apps need valid processes",
                severity: .warning
            )
            return
        }

        guard appA.processIdentifier != appB.processIdentifier else {
            twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
                outcome: .invalidTarget,
                message: "Choose two different process targets",
                severity: .warning
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
            twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
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
            return
        }

        let targetA = appA.target
        let targetB = appB.target
        let gain = selectedTwoAppReadinessGain

        isTwoAppReadinessRunning = true
        twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
            outcome: .starting,
            message: "Starting two-app test...",
            detail: "Gain \(gain.percentLabel).",
            severity: .info
        )
        twoAppReadinessSnapshot = ProcessTapTwoAppReadinessSnapshot(
            sessions: [
                .starting(slot: .appA, target: targetA, gain: gain),
                .starting(slot: .appB, target: targetB, gain: gain)
            ]
        )

        Task {
            let result = await twoAppReadinessTester.startTest(
                appA: targetA,
                appB: targetB,
                gain: gain
            ) { snapshot in
                Task { @MainActor in
                    self.twoAppReadinessSnapshot = snapshot
                }
            } onFinished: { result, snapshot in
                Task { @MainActor in
                    self.handleTwoAppReadinessFinished(result, snapshot: snapshot)
                }
            }

            await MainActor.run {
                twoAppReadinessResult = result
                if result.outcome != .running {
                    isTwoAppReadinessRunning = false
                }
            }
        }
    }

    func stopTwoAppReadinessTest() {
        stopTwoAppReadiness(reason: .userStopped)
    }

    func stopTwoAppReadinessForPanelClose() {
        guard isTwoAppReadinessRunning else {
            stopHelperProcessAutoDetect(reason: .userStopped)
            cancelAppAudioTargetResolution(reason: .userStopped)
            return
        }

        stopTwoAppReadiness(reason: .userStopped)
        stopHelperProcessAutoDetect(reason: .userStopped)
        cancelAppAudioTargetResolution(reason: .userStopped)
    }

    func isExperimentalControlActive(for appID: MixerAppItem.ID) -> Bool {
        activeExperimentalAppID == appID && isProcessTapLiveControlActive
    }

    func isResolvingExperimentalControl(for appID: MixerAppItem.ID) -> Bool {
        appAudioResolutionStateByAppID[appID] != nil
    }

    func toggleExperimentalControl(for appID: MixerAppItem.ID) {
        if isExperimentalControlActive(for: appID) {
            stopProcessTapLiveControl()
            return
        }

        startExperimentalControl(for: appID)
    }

    func refreshApplications() {
        let previousProcessTapAppID = selectedProcessTapAppID
        let previousApps = apps
        let existingStates = Dictionary(
            uniqueKeysWithValues: apps.map { app in
                (app.id, (volume: app.volume, isMuted: app.isMuted))
            }
        )

        apps = applicationLister.listApplications().map { app in
            guard let existingState = existingStates[app.id] else {
                return app
            }

            var updatedApp = app
            updatedApp.volume = existingState.volume
            updatedApp.isMuted = existingState.isMuted
            return updatedApp
        }
        refreshTwoAppReadinessEligibility()
        invalidateCachedAudioTargetsForRemovedOrChangedApps(previousApps: previousApps, refreshedApps: apps)

        if let activeExperimentalAppID,
           !apps.contains(where: { $0.id == activeExperimentalAppID }) {
            stopProcessTapLiveControl(reason: .targetAppExited)
        }

        if let resolvingAppID = appAudioResolutionStateByAppID.keys.first,
           !apps.contains(where: { $0.id == resolvingAppID }) {
            cancelAppAudioTargetResolution(reason: .targetExited)
        }

        if let previousProcessTapAppID,
           apps.contains(where: { $0.id == previousProcessTapAppID }) {
            // Keep the existing diagnostic selection and result state when the selected app survived refresh.
        } else {
            if isProcessTapLiveControlActive {
                stopProcessTapLiveControl(reason: .targetAppExited)
            }

            advancedProcessTapDiagnostics.selectPreferredAppAfterAppRefresh(apps: apps)
            processTapLiveDiagnostics = nil
        }

        refreshTwoAppReadinessSelectionsAfterAppRefresh()
        refreshHelperDiscoverySelectionAfterAppRefresh()
    }

    func volume(for appID: MixerAppItem.ID) -> Double {
        apps.first { $0.id == appID }?.volume ?? 0
    }

    func isMuted(for appID: MixerAppItem.ID) -> Bool {
        apps.first { $0.id == appID }?.isMuted ?? false
    }

    func setAppVolume(_ volume: Double, for appID: MixerAppItem.ID) {
        guard let index = apps.firstIndex(where: { $0.id == appID }) else {
            return
        }

        let clampedVolume = volume.clamped(to: AppConstants.volumeRange)
        apps[index].volume = clampedVolume
        audioController.setVolume(clampedVolume, for: appID)

        startAutomaticRealControlIfNeeded(for: apps[index])
        updateExperimentalGainIfActive(for: apps[index])
    }

    func setMuted(_ isMuted: Bool, for appID: MixerAppItem.ID) {
        guard let index = apps.firstIndex(where: { $0.id == appID }) else {
            return
        }

        apps[index].isMuted = isMuted
        audioController.setMuted(isMuted, for: appID)
        startAutomaticRealControlIfNeeded(for: apps[index])
        updateExperimentalGainIfActive(for: apps[index])
    }

    private func startAutomaticRealControlIfNeeded(for app: MixerAppItem) {
        guard isExperimentalRealAppControlEnabled else {
            return
        }

        guard !isTwoAppReadinessRunning else {
            showStatus("Stop two-app test first", style: .warning)
            return
        }

        guard app.isEligibleForExperimentalLiveControl else {
            showStatus("This app is not available for real app control", style: .warning)
            return
        }

        if isResolvingExperimentalControl(for: app.id) {
            return
        }

        if isAppAudioTargetResolving {
            showStatus("Finish resolving app audio first", style: .warning)
            return
        }

        if helperProcessProbeRunningPID != nil || isHelperProcessAutoDetectRunning {
            showStatus("Stop helper probe first", style: .warning)
            return
        }

        if isExperimentalControlActive(for: app.id) {
            return
        }

        if isProcessTapLiveControlActive || isProcessTapTesting {
            showStatus("Stop active live control first", style: .warning)
            return
        }

        startResolvedExperimentalControl(for: app)
    }

    private func startExperimentalControl(for appID: MixerAppItem.ID) {
        guard !isTwoAppReadinessRunning else {
            showStatus("Stop two-app test first", style: .warning)
            return
        }

        guard !isProcessTapTesting,
              !isAppAudioTargetResolving else {
            showStatus("Process Tap is already busy", style: .warning)
            return
        }

        guard !isProcessTapLiveControlActive else {
            showStatus("Stop the active live control first", style: .warning)
            return
        }

        guard let app = apps.first(where: { $0.id == appID }) else {
            showStatus("This app is not available for live control", style: .warning)
            return
        }

        guard app.isEligibleForExperimentalLiveControl else {
            showStatus("No valid process found", style: .warning)
            return
        }

        guard let processIdentifier = app.processIdentifier,
              NSRunningApplication(processIdentifier: pid_t(processIdentifier)) != nil else {
            showStatus("This app is not available for live control", style: .warning)
            return
        }

        let target = ProcessTapTarget(
            appID: app.id,
            appName: app.name,
            processIdentifier: app.processIdentifier
        )
        startExperimentalControl(for: app, target: target)
    }

    private func startResolvedExperimentalControl(
        for app: MixerAppItem,
        allowsCachedLookup: Bool = true
    ) {
        let request = app.appAudioTargetRequest
        let visibleEligibility = processTapEligibility(app.processIdentifier)

        if visibleEligibility.isEligible {
            startExperimentalControl(
                for: app,
                target: ProcessTapTarget(
                    appID: app.id,
                    appName: app.name,
                    processIdentifier: app.processIdentifier
                )
            )
            return
        }

        if visibleEligibility.reason == ProcessTapCoreAudio.unsupportedOSMessage ||
            visibleEligibility.reason == ProcessTapPermissionMessage.missingUsageDescriptionReason {
            showStatus(
                ProcessTapPermissionMessage.message(
                    forEligibilityReason: visibleEligibility.reason,
                    fallback: visibleEligibility.reason ?? "Process Tap is unavailable"
                ),
                style: .warning
            )
            return
        }

        guard HelperProcessCandidateDiscovery.isLikelyHelperResolvable(app.helperProcessDiscoveryTarget) else {
            showStatus("This app is not available for real app control", style: .warning)
            return
        }

        appAudioResolutionStateByAppID = [app.id: .resolving]
        appAudioResolutionTask?.cancel()
        appAudioResolutionTask = Task { [weak self] in
            let result = await self?.appAudioTargetResolver.resolveTarget(
                for: request,
                allowsCachedLookup: allowsCachedLookup
            ) { _ in }

            await MainActor.run {
                self?.handleAppAudioTargetResolution(result, for: app.id)
            }
        }
    }

    private func startExperimentalControl(
        for app: MixerAppItem,
        target: ProcessTapTarget,
        resolutionSource: ResolvedAppAudioTarget.Source? = nil
    ) {
        guard target.processIdentifier.map({ $0 > 0 }) == true else {
            showStatus("This app is not available for live control", style: .warning)
            return
        }

        let gain = experimentalGainOption(for: app)

        activeExperimentalAppID = app.id
        activeLiveControlAppName = app.name
        advancedProcessTapDiagnostics.setResult(
            ProcessTapTestResult(
                outcome: .liveControlStarting,
                message: "Starting experimental live control for \(app.name)...",
                detail: "This may affect real audio for this app only. Gain \(gain.percentLabel).",
                severity: .info
            )
        )
        advancedProcessTapDiagnostics.setProgress(
            ProcessTapDiagnosticProgress(
                callbackCount: 0,
                peakLevel: 0,
                rmsLevel: 0,
                audioDetected: false
            )
        )
        processTapLiveDiagnostics = nil
        advancedProcessTapDiagnostics.setRunning(true)

        Task {
            let result = await processTapLiveController.startLiveControl(
                for: target,
                gain: gain
            ) { diagnostics in
                Task { @MainActor in
                    self.processTapLiveDiagnostics = diagnostics
                    self.advancedProcessTapDiagnostics.setProgress(diagnostics.progress)
                }
            } onStopped: { result, diagnostics in
                Task { @MainActor in
                    self.handleLiveControlStopped(result, diagnostics: diagnostics)
                }
            }

            await MainActor.run {
                advancedProcessTapDiagnostics.setResult(result)
                advancedProcessTapDiagnostics.setRunning(false)

                if result.outcome == .liveControlStarted {
                    isProcessTapLiveControlActive = true
                    activeExperimentalAppID = app.id
                    activeLiveControlAppName = app.name
                } else {
                    if resolutionSource == .cachedHelper {
                        appAudioTargetResolver.invalidateCachedTarget(for: app.appAudioTargetRequest)
                    }

                    activeExperimentalAppID = nil
                    activeLiveControlAppName = nil
                    processTapLiveDiagnostics = nil
                    advancedProcessTapDiagnostics.setProgress(nil)

                    if resolutionSource == .cachedHelper,
                       isExperimentalRealAppControlEnabled,
                       !isTwoAppReadinessRunning,
                       !isProcessTapLiveControlActive,
                       !isAppAudioTargetResolving {
                        startResolvedExperimentalControl(for: app, allowsCachedLookup: false)
                    } else {
                        if resolutionSource == .discoveredHelper {
                            appAudioTargetResolver.invalidateCachedTarget(for: app.appAudioTargetRequest)
                        }
                        showStatus("Could not start live control for this app", style: .warning)
                    }
                }
            }
        }
    }

    private func handleLiveControlStopped(
        _ result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?
    ) {
        let stoppedAppID = activeExperimentalAppID
        advancedProcessTapDiagnostics.setResult(result)
        processTapLiveDiagnostics = diagnostics
        advancedProcessTapDiagnostics.setProgress(diagnostics?.progress)
        isProcessTapLiveControlActive = false
        advancedProcessTapDiagnostics.setRunning(false)
        activeExperimentalAppID = nil
        activeLiveControlAppName = nil
        if result.outcome == .liveControlAppExited,
           let stoppedAppID,
           let stoppedApp = apps.first(where: { $0.id == stoppedAppID }) {
            appAudioTargetResolver.invalidateCachedTarget(for: stoppedApp.appAudioTargetRequest)
        }
        if result.outcome == .liveControlOutputChanged {
            appAudioTargetResolver.invalidateAllCachedTargets()
        }
        showLiveControlWarningIfNeeded(for: result)
    }

    private func handleAppAudioTargetResolution(
        _ result: AppAudioTargetResolutionResult?,
        for appID: MixerAppItem.ID
    ) {
        guard appAudioResolutionStateByAppID[appID] != nil else {
            return
        }

        appAudioResolutionStateByAppID[appID] = nil
        appAudioResolutionTask = nil

        guard let result else {
            return
        }

        switch result {
        case .resolved(let resolvedTarget):
            guard let app = apps.first(where: { $0.id == resolvedTarget.visibleAppID }) else {
                showStatus("This app is not available for real app control", style: .warning)
                return
            }

            guard !isTwoAppReadinessRunning else {
                showStatus("Stop two-app test first", style: .warning)
                return
            }

            guard !isProcessTapLiveControlActive, !isProcessTapTesting else {
                showStatus("Stop active live control first", style: .warning)
                return
            }

            startExperimentalControl(
                for: app,
                target: resolvedTarget.target,
                resolutionSource: resolvedTarget.source
            )

        case .unavailable(let reason):
            showStatus(reason, style: .warning)

        case .cancelled:
            break
        }
    }

    private func showLiveControlWarningIfNeeded(for result: ProcessTapTestResult) {
        switch result.outcome {
        case .tapCleanupFailed:
            showStatus("Live control cleanup warning", style: .warning)
        case .liveControlTimedOut:
            showStatus("Live control stopped: timeout", style: .warning)
        case .liveControlOutputChanged:
            showStatus("Live control stopped: output device changed", style: .warning)
        case .liveControlAppExited:
            showStatus("Live control stopped: app exited", style: .warning)
        case .liveControlSetupFailed:
            showStatus("Could not start live control", style: .warning)
        case .missingUsageDescription:
            showStatus(ProcessTapPermissionMessage.missingUsageDescription, style: .warning)
        case .permissionDenied:
            showStatus(ProcessTapPermissionMessage.permissionRequired, style: .warning)
        case .unsupportedOS:
            showStatus(ProcessTapCoreAudio.unsupportedOSMessage, style: .warning)
        default:
            break
        }
    }

    private func stopTwoAppReadiness(reason: ProcessTapLiveStopReason) {
        guard isTwoAppReadinessRunning else {
            return
        }

        Task {
            let result = await twoAppReadinessTester.stopAll(reason: reason)

            await MainActor.run {
                if result.outcome == .notRunning {
                    handleTwoAppReadinessFinished(result, snapshot: twoAppReadinessSnapshot)
                }
            }
        }
    }

    private func stopHelperProcessProbe(reason: ProcessTapCandidateProbeStopReason) {
        guard helperProcessProbeRunningPID != nil || isHelperProcessAutoDetectRunning else {
            return
        }

        if isHelperProcessAutoDetectRunning {
            stopHelperProcessAutoDetect(reason: reason)
        }

        advancedHelperDiscovery.stopProbe(reason: reason)
    }

    private func stopHelperProcessAutoDetect(reason: ProcessTapCandidateProbeStopReason) {
        advancedHelperDiscovery.stopAutoDetect(reason: reason)
    }

    private func cancelAppAudioTargetResolution(reason: ProcessTapCandidateProbeStopReason) {
        guard isAppAudioTargetResolving else {
            return
        }

        appAudioResolutionTask?.cancel()
        appAudioResolutionTask = nil
        appAudioResolutionStateByAppID = [:]
        appAudioTargetResolver.cancelCurrentResolution(reason: reason)
    }

    private func handleTwoAppReadinessFinished(
        _ result: ProcessTapTwoAppReadinessResult,
        snapshot: ProcessTapTwoAppReadinessSnapshot
    ) {
        twoAppReadinessResult = result
        twoAppReadinessSnapshot = snapshot
        isTwoAppReadinessRunning = false

        if result.severity == .warning {
            showStatus(result.message, style: .warning)
        }
    }

    private func refreshTwoAppReadinessSelectionsAfterAppRefresh() {
        let targetIDs = Set(twoAppReadinessTargets.map(\.id))
        let preferredIDs = Self.preferredTwoAppReadinessTargetIDs(in: twoAppReadinessTargets)

        if isTwoAppReadinessRunning {
            if selectedTwoAppReadinessAppAID.map({ !targetIDs.contains($0) }) == true ||
                selectedTwoAppReadinessAppBID.map({ !targetIDs.contains($0) }) == true {
                stopTwoAppReadiness(reason: .targetAppExited)
            }
            return
        }

        if selectedTwoAppReadinessAppAID.map({ !targetIDs.contains($0) }) != false {
            selectedTwoAppReadinessAppAID = preferredIDs.appAID
        }

        if selectedTwoAppReadinessAppBID.map({ !targetIDs.contains($0) }) != false ||
            selectedTwoAppReadinessTargetsUseSameProcess {
            selectedTwoAppReadinessAppBID = preferredIDs.appBID
        }
    }

    private func refreshTwoAppReadinessSelectionsAfterTargetChange(removedTargetID: String? = nil) {
        if let removedTargetID {
            if selectedTwoAppReadinessAppAID == removedTargetID {
                selectedTwoAppReadinessAppAID = nil
            }

            if selectedTwoAppReadinessAppBID == removedTargetID {
                selectedTwoAppReadinessAppBID = nil
            }
        }

        guard !isTwoAppReadinessRunning else {
            return
        }

        refreshTwoAppReadinessSelectionsAfterAppRefresh()
    }

    private func refreshHelperDiscoverySelectionAfterAppRefresh() {
        if selectedHelperDiscoveryAppID.map({ appID in apps.contains { $0.id == appID } }) != true {
            stopHelperProcessAutoDetect(reason: .targetExited)
        }

        advancedHelperDiscovery.refreshSelectionAfterAppRefresh(apps: apps)
    }

    private func invalidateCachedAudioTargetsForRemovedOrChangedApps(
        previousApps: [MixerAppItem],
        refreshedApps: [MixerAppItem]
    ) {
        let refreshedAppsByID = Dictionary(uniqueKeysWithValues: refreshedApps.map { ($0.id, $0) })

        for previousApp in previousApps {
            guard let refreshedApp = refreshedAppsByID[previousApp.id] else {
                appAudioTargetResolver.invalidateCachedTarget(for: previousApp.appAudioTargetRequest)
                continue
            }

            if previousApp.processIdentifier != refreshedApp.processIdentifier {
                appAudioTargetResolver.invalidateCachedTarget(for: previousApp.appAudioTargetRequest)
            }
        }
    }

    private func refreshTwoAppReadinessEligibility() {
        twoAppReadinessEligibilityByAppID = Self.twoAppReadinessEligibility(
            for: apps,
            processTapEligibility: processTapEligibility
        )
    }

    private func updateExperimentalGainIfActive(for app: MixerAppItem) {
        guard isExperimentalControlActive(for: app.id) else {
            return
        }

        processTapLiveController.updateLiveControlGain(experimentalGainOption(for: app))
    }

    private func experimentalGainOption(for app: MixerAppItem) -> ProcessTapReplayGainOption {
        let scalar: Float = app.isMuted
            ? 0
            : Float(app.volume.clamped(to: AppConstants.volumeRange) / AppConstants.volumeRange.upperBound)
        let percent = Int((Double(scalar) * 100).rounded())

        return ProcessTapReplayGainOption(
            scalar: scalar,
            label: "\(percent)%"
        )
    }

    private static func preferredTwoAppReadinessAppIDs(
        in apps: [MixerAppItem],
        eligibilityByAppID: [MixerAppItem.ID: ProcessTapProcessEligibility]
    ) -> (appAID: MixerAppItem.ID?, appBID: MixerAppItem.ID?) {
        let eligibleApps = apps.filter { app in
            eligibilityByAppID[app.id]?.isEligible == true
        }

        return (
            appAID: eligibleApps.first?.id,
            appBID: eligibleApps.dropFirst().first?.id
        )
    }

    private static func preferredTwoAppReadinessTargetIDs(
        in targets: [TwoAppReadinessTargetOption]
    ) -> (appAID: String?, appBID: String?) {
        let appA = targets.first
        let appB = targets.first { target in
            target.id != appA?.id && target.processIdentifier != appA?.processIdentifier
        }

        return (
            appAID: appA?.id,
            appBID: appB?.id
        )
    }

    private static func twoAppReadinessEligibility(
        for apps: [MixerAppItem],
        processTapEligibility: @Sendable (Int32?) -> ProcessTapProcessEligibility
    ) -> [MixerAppItem.ID: ProcessTapProcessEligibility] {
        Dictionary(
            uniqueKeysWithValues: apps.map { app in
                (app.id, processTapEligibility(app.processIdentifier))
            }
        )
    }

    private var selectedProcessTapApp: MixerAppItem? {
        guard let selectedProcessTapAppID else {
            return nil
        }

        return apps.first { $0.id == selectedProcessTapAppID }
    }

    private var selectedTwoAppReadinessTargetA: TwoAppReadinessTargetOption? {
        guard let selectedTwoAppReadinessAppAID else {
            return nil
        }

        return twoAppReadinessTargets.first { $0.id == selectedTwoAppReadinessAppAID }
    }

    private var selectedTwoAppReadinessTargetB: TwoAppReadinessTargetOption? {
        guard let selectedTwoAppReadinessAppBID else {
            return nil
        }

        return twoAppReadinessTargets.first { $0.id == selectedTwoAppReadinessAppBID }
    }

    private var selectedTwoAppReadinessTargetsUseSameProcess: Bool {
        guard let targetA = selectedTwoAppReadinessTargetA,
              let targetB = selectedTwoAppReadinessTargetB else {
            return false
        }

        return targetA.processIdentifier == targetB.processIdentifier
    }

    private func validProcessIdentifier(_ processIdentifier: Int32?) -> Bool {
        guard let processIdentifier else {
            return false
        }

        return processIdentifier > 0
    }

    private var selectedHelperDiscoveryApp: MixerAppItem? {
        advancedHelperDiscovery.selectedHelperDiscoveryApp(in: apps)
    }

    private var isAppAudioTargetResolving: Bool {
        !appAudioResolutionStateByAppID.isEmpty
    }

    private func showStatus(_ text: String, style: MixerStatusMessage.Style) {
        let message = MixerStatusMessage(text: text, style: style)
        statusMessage = message
        clearStatusAfterDelay(message.id)
    }

    private func clearStatusAfterDelay(_ messageID: MixerStatusMessage.ID) {
        statusClearTask?.cancel()

        statusClearTask = Task { [weak self] in
            let delayNanoseconds = UInt64(AppConstants.statusMessageAutoClearDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanoseconds)

            await MainActor.run {
                guard self?.statusMessage?.id == messageID else {
                    return
                }

                self?.statusMessage = nil
            }
        }
    }

}

private extension MixerAppItem {
    var appAudioTargetRequest: AppAudioTargetRequest {
        AppAudioTargetRequest(
            appID: id,
            appName: name,
            processIdentifier: processIdentifier
        )
    }
}
