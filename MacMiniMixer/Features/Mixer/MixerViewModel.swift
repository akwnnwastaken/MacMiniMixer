import AppKit
import Foundation

@MainActor
final class MixerViewModel: ObservableObject {
    @Published private(set) var apps: [MixerAppItem]
    @Published private(set) var statusMessage: MixerStatusMessage?
    @Published private(set) var processTapLiveDiagnostics: ProcessTapLiveDiagnostics?
    @Published private(set) var isProcessTapLiveControlActive = false
    @Published private(set) var activeLiveControlAppName: String?
    @Published private var productRealControlState = ProductRealControlState()
    @Published private(set) var showAllApps = false
    @Published private(set) var isExperimentalRealAppControlEnabled = false

    private let applicationLister: ApplicationListing
    private let audioController: AudioControlling
    private let systemOutput: SystemOutputCoordinator
    private let advancedProcessTapDiagnostics: AdvancedProcessTapDiagnosticsCoordinator
    private let advancedLiveControl: AdvancedLiveControlCoordinator
    private let processTapLiveController: ProcessTapLiveControlling
    private let twoAppReadiness: TwoAppReadinessCoordinator
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
        self.helperProcessAudioProbe = helperProcessAudioProbe
        self.appAudioTargetResolver = appAudioTargetResolver
        self.processTapEligibility = processTapEligibility

        let initialApps = applicationLister.listApplications()
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
        self.advancedLiveControl = AdvancedLiveControlCoordinator(
            liveController: processTapLiveController,
            diagnostics: advancedProcessTapDiagnostics
        )
        self.twoAppReadiness = TwoAppReadinessCoordinator(
            tester: twoAppReadinessTester,
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

        systemOutput.setOnWillChange { [weak self] in
            self?.objectWillChange.send()
        }
        advancedProcessTapDiagnostics.setOnWillChange { [weak self] in
            self?.objectWillChange.send()
        }
        advancedHelperDiscovery.setOnWillChange { [weak self] in
            self?.objectWillChange.send()
        }
        twoAppReadiness.setOnWillChange { [weak self] in
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
        _ = twoAppReadiness.stopNowForTermination(reason: .appTerminating)
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

    var appAudioResolutionStateByAppID: [MixerAppItem.ID: AppAudioResolutionState] {
        productRealControlState.resolutionStateByAppID
    }

    var activeExperimentalAppID: MixerAppItem.ID? {
        productRealControlState.activeVisibleAppID
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

    var selectedTwoAppReadinessAppAID: MixerAppItem.ID? {
        twoAppReadiness.selectedAppAID
    }

    var selectedTwoAppReadinessAppBID: MixerAppItem.ID? {
        twoAppReadiness.selectedAppBID
    }

    var selectedTwoAppReadinessGain: ProcessTapReplayGainOption {
        twoAppReadiness.selectedGain
    }

    var twoAppReadinessEligibilityByAppID: [MixerAppItem.ID: ProcessTapProcessEligibility] {
        twoAppReadiness.eligibilityByAppID
    }

    var twoAppReadinessSnapshot: ProcessTapTwoAppReadinessSnapshot {
        twoAppReadiness.snapshot
    }

    var twoAppReadinessResult: ProcessTapTwoAppReadinessResult? {
        twoAppReadiness.result
    }

    var isTwoAppReadinessRunning: Bool {
        twoAppReadiness.isRunning
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
        twoAppReadiness.targetOptions(
            apps: apps,
            advancedTarget: advancedProcessTapTarget
        )
    }

    func setShowAllApps(_ showAllApps: Bool) {
        self.showAllApps = showAllApps
    }

    func setExperimentalRealAppControlEnabled(_ isEnabled: Bool) {
        isExperimentalRealAppControlEnabled = isEnabled

        if !isEnabled {
            invalidateProductStartRequest(clearPendingState: true)
        }

        if !isEnabled, isProcessTapLiveControlActive {
            stopProcessTapLiveControl()
        }

        if !isEnabled {
            cancelAppAudioTargetResolution(reason: .userStopped)
            appAudioTargetResolver.invalidateAllCachedTargets()
        }
    }

    private func isActiveLiveControlTarget(_ appID: MixerAppItem.ID) -> Bool {
        appID == productRealControlState.activeVisibleAppID ||
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

        if refreshResult.didOutputDeviceChange {
            invalidateProductStartRequest(clearPendingState: true)
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
        twoAppReadiness.selectAppA(appID, targets: twoAppReadinessTargets)
    }

    func selectTwoAppReadinessAppB(_ appID: MixerAppItem.ID) {
        twoAppReadiness.selectAppB(appID, targets: twoAppReadinessTargets)
    }

    func selectTwoAppReadinessGain(_ gain: ProcessTapReplayGainOption) {
        twoAppReadiness.selectGain(gain)
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
        processTapLiveDiagnostics = nil
        advancedLiveControl.startLiveControl(
            apps: apps,
            selectedAppID: selectedProcessTapAppID,
            gain: selectedProcessTapReplayGain,
            isLiveControlActive: isProcessTapLiveControlActive,
            isTwoAppReadinessRunning: isTwoAppReadinessRunning,
            isAppAudioTargetResolving: isAppAudioTargetResolving
        ) { [weak self] diagnostics in
            self?.processTapLiveDiagnostics = diagnostics
        } onStarted: { [weak self] appName in
            self?.isProcessTapLiveControlActive = true
            self?.activeLiveControlAppName = appName
        } onFailed: { [weak self] result in
            self?.processTapLiveDiagnostics = nil
            self?.activeLiveControlAppName = nil
            self?.showLiveControlWarningIfNeeded(for: result)
        } onStopped: { [weak self] result, diagnostics in
            self?.handleLiveControlStopped(result, diagnostics: diagnostics)
        }
    }

    func stopProcessTapLiveControl() {
        stopProcessTapLiveControl(reason: .userStopped)
    }

    private func stopProcessTapLiveControl(reason: ProcessTapLiveStopReason) {
        invalidateProductStartRequest(clearPendingState: !isProcessTapLiveControlActive)
        advancedLiveControl.stopLiveControl(
            reason: reason,
            isLiveControlActive: isProcessTapLiveControlActive,
            currentDiagnostics: processTapLiveDiagnostics
        ) { [weak self] result, diagnostics in
            self?.handleLiveControlStopped(result, diagnostics: diagnostics)
        }
    }

    func stopProcessTapLiveControlForTermination() {
        invalidateProductStartRequest(clearPendingState: true)
        _ = processTapLiveController.stopLiveControlNow(reason: .appTerminating)
        _ = twoAppReadiness.stopNow(reason: .appTerminating)
        advancedHelperDiscovery.stopAutoDetect(reason: .userStopped)
        appAudioResolutionTask?.cancel()
        appAudioTargetResolver.cancelCurrentResolution(reason: .userStopped)
        appAudioTargetResolver.invalidateAllCachedTargets()
        advancedHelperDiscovery.stopProbe(reason: .userStopped)
        advancedProcessTapDiagnostics.stopReplayProbeForTermination()
        isProcessTapLiveControlActive = false
        productRealControlState.clearAllResolutions()
        productRealControlState.clearActiveSession()
        activeLiveControlAppName = nil
    }

    func startTwoAppReadinessTest() {
        twoAppReadiness.startTest(
            apps: apps,
            advancedTarget: advancedProcessTapTarget,
            isProcessTapTesting: isProcessTapTesting,
            isLiveControlActive: isProcessTapLiveControlActive,
            isAppAudioTargetResolving: isAppAudioTargetResolving
        ) { [weak self] message in
            self?.showStatus(message, style: .warning)
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
        productRealControlState.isActive(appID: appID, isLiveControlActive: isProcessTapLiveControlActive)
    }

    func isResolvingExperimentalControl(for appID: MixerAppItem.ID) -> Bool {
        productRealControlState.isResolving(appID: appID)
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

        if let activeExperimentalAppID = productRealControlState.activeVisibleAppID,
           !apps.contains(where: { $0.id == activeExperimentalAppID }) {
            stopProcessTapLiveControl(reason: .targetAppExited)
        }

        if let resolvingAppID = productRealControlState.resolvingAppIDs.first,
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

        productRealControlState.beginResolution(for: app.id)
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

        let gain = ProductRealControlState.gainOption(for: app)
        let startRequestID = productRealControlState.beginStartRequest()

        productRealControlState.beginSession(
            visibleAppID: app.id,
            displayName: app.name,
            controlledProcessIdentifier: target.processIdentifier,
            source: ProductRealControlStartSource(resolutionSource: resolutionSource),
            startRequestID: startRequestID
        )
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
            let startResult = await processTapLiveController.startLiveControlSession(
                for: target,
                gain: gain,
                timeoutPolicy: .indefinite
            ) { diagnostics in
                Task { @MainActor in
                    guard self.shouldAcceptProductLiveCallback(startRequestID) else {
                        return
                    }
                    self.processTapLiveDiagnostics = diagnostics
                    self.advancedProcessTapDiagnostics.setProgress(diagnostics.progress)
                }
            } onStopped: { result, diagnostics in
                Task { @MainActor in
                    guard self.shouldAcceptProductLiveCallback(startRequestID) else {
                        return
                    }
                    self.invalidateProductStartRequestForAcceptedStopCallback(startRequestID)
                    self.handleLiveControlStopped(result, diagnostics: diagnostics)
                }
            }

            let accepted = await MainActor.run {
                guard productRealControlState.isCurrentStartRequest(startRequestID) else {
                    return false
                }

                productRealControlState.clearStartRequest(startRequestID)
                let result = startResult.result
                advancedProcessTapDiagnostics.setResult(result)
                advancedProcessTapDiagnostics.setRunning(false)

                if result.outcome == .liveControlStarted {
                    isProcessTapLiveControlActive = true
                    productRealControlState.beginSession(
                        visibleAppID: app.id,
                        displayName: app.name,
                        controlledProcessIdentifier: target.processIdentifier,
                        source: ProductRealControlStartSource(resolutionSource: resolutionSource),
                        startRequestID: startRequestID
                    )
                    activeLiveControlAppName = app.name
                } else {
                    if resolutionSource == .cachedHelper {
                        appAudioTargetResolver.invalidateCachedTarget(for: app.appAudioTargetRequest)
                    }

                    productRealControlState.clearActiveSession()
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

                return true
            }

            if !accepted {
                await cleanupStaleProductLiveStart(startResult)
            }
        }
    }

    private func handleLiveControlStopped(
        _ result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?
    ) {
        let stoppedAppID = productRealControlState.activeVisibleAppID
        advancedProcessTapDiagnostics.setResult(result)
        processTapLiveDiagnostics = diagnostics
        advancedProcessTapDiagnostics.setProgress(diagnostics?.progress)
        isProcessTapLiveControlActive = false
        advancedProcessTapDiagnostics.setRunning(false)
        productRealControlState.clearActiveSession()
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

    private func shouldAcceptProductLiveCallback(_ requestID: ProductRealControlStartRequestID) -> Bool {
        productRealControlState.isCurrentStartRequest(requestID) ||
            productRealControlState.activeStartRequestID == requestID
    }

    private func invalidateProductStartRequestForAcceptedStopCallback(_ requestID: ProductRealControlStartRequestID) {
        if productRealControlState.isCurrentStartRequest(requestID) {
            productRealControlState.invalidateCurrentStartRequest()
        }
    }

    private func invalidateProductStartRequest(clearPendingState: Bool) {
        productRealControlState.invalidateCurrentStartRequest()

        guard clearPendingState,
              !isProcessTapLiveControlActive else {
            return
        }

        productRealControlState.clearActiveSession()
        activeLiveControlAppName = nil
        processTapLiveDiagnostics = nil
        advancedProcessTapDiagnostics.setRunning(false)
        advancedProcessTapDiagnostics.setProgress(nil)
    }

    private func cleanupStaleProductLiveStart(_ startResult: ProcessTapLiveSessionStartResult) async {
        guard startResult.result.outcome == .liveControlStarted else {
            return
        }

        guard let sessionID = startResult.sessionID else {
            AppLogger.processTap.warning("Stale Product Real Control start succeeded without a session-specific cleanup handle")
            return
        }

        _ = await processTapLiveController.stopLiveControlSession(id: sessionID, reason: .userStopped)
    }

    private func handleAppAudioTargetResolution(
        _ result: AppAudioTargetResolutionResult?,
        for appID: MixerAppItem.ID
    ) {
        guard productRealControlState.shouldAcceptResolutionResult(for: appID) else {
            return
        }

        productRealControlState.clearResolution(for: appID)
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
        twoAppReadiness.stop(reason: reason)
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
        productRealControlState.clearAllResolutions()
        appAudioTargetResolver.cancelCurrentResolution(reason: reason)
    }

    private func refreshTwoAppReadinessSelectionsAfterAppRefresh() {
        twoAppReadiness.refreshSelectionsAfterAppRefresh(targets: twoAppReadinessTargets)
    }

    private func refreshTwoAppReadinessSelectionsAfterTargetChange(removedTargetID: String? = nil) {
        twoAppReadiness.handleRemovedTarget(id: removedTargetID, targets: twoAppReadinessTargets)
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
        twoAppReadiness.refreshEligibility(apps: apps)
    }

    private func updateExperimentalGainIfActive(for app: MixerAppItem) {
        guard isExperimentalControlActive(for: app.id) else {
            return
        }

        processTapLiveController.updateLiveControlGain(ProductRealControlState.gainOption(for: app))
    }

    private var isAppAudioTargetResolving: Bool {
        productRealControlState.isResolving
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
