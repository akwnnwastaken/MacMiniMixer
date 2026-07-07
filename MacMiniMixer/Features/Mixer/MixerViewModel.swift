import AppKit
import Foundation

@MainActor
final class MixerViewModel: ObservableObject {
    @Published private(set) var apps: [MixerAppItem]
    @Published private(set) var statusMessage: MixerStatusMessage?
    @Published private(set) var processTapLiveDiagnostics: ProcessTapLiveDiagnostics?
    @Published private var advancedManualLiveControlActive = false
    @Published private(set) var activeLiveControlAppName: String?
    @Published private var productRealControlState = ProductRealControlState()

    /// Live control is active when the Advanced manual session is running or at least one
    /// product session has confirmed-started. Derived so product and Advanced manual no
    /// longer share a single stored flag (Phase 3d).
    var isProcessTapLiveControlActive: Bool {
        advancedManualLiveControlActive || productRealControlState.hasConfirmedLiveSession
    }
    @Published private(set) var showAllApps = false
    @Published private(set) var isExperimentalRealAppControlEnabled = false

    private let applicationLister: ApplicationListing
    private let audioController: AudioControlling
    private let systemOutput: SystemOutputCoordinator
    private let advancedProcessTapDiagnostics: AdvancedProcessTapDiagnosticsCoordinator
    private let advancedLiveControl: AdvancedLiveControlCoordinator
    private let processTapLiveController: ProcessTapLiveControlling & ProcessTapLiveSessionManaging
    private let twoAppReadiness: TwoAppReadinessCoordinator
    private let helperProcessAudioProbe: ProcessTapCandidateAudioProbing
    private let advancedHelperDiscovery: AdvancedHelperDiscoveryCoordinator
    private let appAudioTargetResolver: AppAudioTargetResolving
    private let productRealStartSettleGate: ProductRealStartSettling
    private let processTapEligibility: @Sendable (Int32?) -> ProcessTapProcessEligibility
    private var appAudioResolutionTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init(
        applicationLister: ApplicationListing,
        audioController: AudioControlling,
        outputDeviceLister: OutputDeviceListing,
        outputDeviceController: OutputDeviceControlling,
        systemVolumeReader: SystemVolumeReading,
        systemVolumeController: SystemVolumeControlling,
        processTapTester: ProcessTapTesting,
        processTapReplayProbe: ProcessTapReplayProbing,
        processTapLiveController: ProcessTapLiveControlling & ProcessTapLiveSessionManaging,
        twoAppReadinessTester: ProcessTapTwoAppReadinessTesting,
        helperProcessAudioProbe: ProcessTapCandidateAudioProbing,
        appAudioTargetResolver: AppAudioTargetResolving,
        processLister: ProcessListing,
        productRealStartSettleGate: ProductRealStartSettling = ProductRealStartSettleGate(),
        processTapEligibility: @escaping @Sendable (Int32?) -> ProcessTapProcessEligibility = {
            ProcessTapCoreAudio.processTapEligibility(for: $0)
        }
    ) {
        self.applicationLister = applicationLister
        self.audioController = audioController
        self.processTapLiveController = processTapLiveController
        self.helperProcessAudioProbe = helperProcessAudioProbe
        self.appAudioTargetResolver = appAudioTargetResolver
        self.productRealStartSettleGate = productRealStartSettleGate
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

        // `willSleep` is posted by AppKit on the main thread, and `queue: .main` runs this block on
        // the main thread too. Tear down synchronously (not a deferred `Task`) so the Core Audio
        // tap/aggregate is gone before the system sleeps and cannot resume stale on wake. The
        // observer lives for the view model's lifetime (an app-lifetime `@StateObject`), so it fires
        // whether or not the menu-bar panel is open.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }

            // `MainActor.assumeIsolated` is macOS 14.0+; Process Tap itself requires macOS 14.2+, so
            // on older systems there is no live audio work to tear down and the deferred no-op is
            // safe. On supported systems this runs the cleanup synchronously on the main thread.
            if #available(macOS 14.0, *) {
                MainActor.assumeIsolated {
                    self.handleSystemWillSleep()
                }
            } else {
                Task { @MainActor in
                    self.handleSystemWillSleep()
                }
            }
        }

        // `didWake` only refreshes device/app state — it is not time-critical (sessions were torn
        // down at sleep and are not restored), so a deferred main-actor hop is fine. Same owner and
        // lifetime as the sleep observer; fires regardless of panel state.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemDidWake()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
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

    var isSystemOutputVolumeWritable: Bool {
        systemOutput.isSystemOutputVolumeWritable
    }

    var appAudioResolutionStateByAppID: [MixerAppItem.ID: AppAudioResolutionState] {
        productRealControlState.resolutionStateByAppID
    }

    var activeExperimentalAppID: MixerAppItem.ID? {
        productRealControlState.activeVisibleAppID
    }

    /// Visible app display names for every *confirmed* Product Real Control session (one whose
    /// engine `liveSessionID` is set), in the stable order they appear in `apps`. Helper-controlled
    /// sessions surface the visible app's name only — the helper process/PID never reaches the UI.
    /// Pending (optimistic, not-yet-confirmed) starts are excluded, and dictionary iteration order
    /// is never used. Backs the multi-app banner (Phase 3d-iii); presentation/summary lives in the
    /// view layer in a later step.
    var confirmedProductRealControlAppNames: [String] {
        apps.compactMap { app in
            productRealControlState.activeSessionsByAppID[app.id]?.liveSessionID != nil ? app.name : nil
        }
    }

    /// Number of confirmed Product Real Control sessions reflected in the banner. Equal to
    /// `confirmedProductRealControlAppNames.count`, so name list and count never disagree.
    var confirmedProductRealControlSessionCount: Int {
        confirmedProductRealControlAppNames.count
    }

    /// Single source of truth for the Real Control banner's text, stop-button title, and
    /// accessibility wording. Delegates to the pure `RealControlBannerPresenter`; `nil` ⟺ the
    /// banner should be hidden, which is exactly `!isProcessTapLiveControlActive`.
    var realControlBannerPresentation: RealControlBannerPresentation? {
        RealControlBannerPresenter.make(
            confirmedProductRealControlAppNames: confirmedProductRealControlAppNames,
            isAdvancedManualLiveControlActive: advancedManualLiveControlActive,
            activeLiveControlAppName: activeLiveControlAppName,
            isLiveControlActive: isProcessTapLiveControlActive
        )
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

    var selectedTwoAppReadinessDuration: ProcessTapTwoAppReadinessDurationOption {
        twoAppReadiness.selectedDuration
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
            // Invalidate every pending start so any in-flight start that completes after the
            // toggle is rejected and its orphan session cleaned up (covers pending starts that
            // have no confirmed session yet, which the active-only stop below would miss).
            productRealControlState.clearAllStartRequests()
            productRealControlState.clearAllOperations()
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
        productRealControlState.activeVisibleAppIDs.contains(appID) ||
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

        guard refreshResult.didOutputDeviceChange else {
            return
        }

        // The output device changed under all taps: invalidate every pending Product start so
        // late completions cannot reactivate state on the previous device.
        productRealControlState.clearAllStartRequests()
        productRealControlState.clearAllOperations()
        stopActiveAudioWorkForOutputDeviceChange(refreshResult)
        appAudioTargetResolver.invalidateAllCachedTargets()
        refreshSystemOutputVolume()
    }

    /// Stops every in-flight Process Tap activity when the system output device changes,
    /// since tapped audio is tied to the previous device. Each subsystem is only asked to
    /// stop when it is actually running, preserving the previous per-feature guards.
    private func stopActiveAudioWorkForOutputDeviceChange(_ refreshResult: SystemOutputRefreshResult) {
        let logChange: (String) -> Void = { subsystem in
            AppLogger.audio.warning("Output device change \(subsystem, privacy: .public) previousDefault=\(refreshResult.previousDefaultDeviceID ?? "none", privacy: .public) currentDefault=\(refreshResult.currentDefaultDeviceID ?? "none", privacy: .public)")
        }

        if isProcessTapLiveControlActive {
            logChange("stopping live control")
            stopProcessTapLiveControl(reason: .outputDeviceChanged)
        }

        if isTwoAppReadinessRunning {
            logChange("stopping two-app readiness")
            stopTwoAppReadiness(reason: .outputDeviceChanged)
        }

        if helperProcessProbeRunningPID != nil || isHelperProcessAutoDetectRunning {
            logChange("stopping helper probe")
            stopHelperProcessProbe(reason: .outputDeviceChanged)
        }

        if isAppAudioTargetResolving {
            logChange("cancelling app audio resolution")
            cancelAppAudioTargetResolution(reason: .outputDeviceChanged)
        }

        if advancedProcessTapDiagnostics.isReplayProbeRunning {
            logChange("stopping replay probe")
            advancedProcessTapDiagnostics.stopReplayProbe(reason: .outputDeviceChanged)
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

    func selectTwoAppReadinessDuration(_ duration: ProcessTapTwoAppReadinessDurationOption) {
        twoAppReadiness.selectDuration(duration)
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
            self?.advancedManualLiveControlActive = true
            self?.activeLiveControlAppName = appName
        } onFailed: { [weak self] result in
            self?.processTapLiveDiagnostics = nil
            self?.activeLiveControlAppName = nil
            self?.showLiveControlWarningIfNeeded(for: result)
        } onStopped: { [weak self] result, diagnostics in
            self?.handleAdvancedManualLiveControlStopped(result, diagnostics: diagnostics)
        }
    }

    func stopProcessTapLiveControl() {
        stopProcessTapLiveControl(reason: .userStopped)
    }

    private func stopProcessTapLiveControl(reason: ProcessTapLiveStopReason) {
        // Global stop: cancel every pending Product start as well, so an in-flight start that
        // completes after this stop is rejected (and its orphan session cleaned up).
        productRealControlState.clearAllStartRequests()
        productRealControlState.clearAllOperations()

        // Product and Advanced manual control are mutually exclusive today. Route product
        // sessions to the per-session API; otherwise fall back to the Advanced manual compat
        // stop. Per-row stop arrives in Phase 3d when two product sessions can coexist.
        if !productRealControlState.activeSessions.isEmpty {
            stopProductLiveSessions(reason: reason)
            return
        }

        advancedLiveControl.stopLiveControl(
            reason: reason,
            isLiveControlActive: isProcessTapLiveControlActive,
            currentDiagnostics: processTapLiveDiagnostics
        ) { [weak self] result, diagnostics in
            self?.handleAdvancedManualLiveControlStopped(result, diagnostics: diagnostics)
        }
    }

    private func stopProductLiveSessions(reason: ProcessTapLiveStopReason) {
        let sessionIDs = productRealControlState.activeSessions.compactMap(\.liveSessionID)
        guard !sessionIDs.isEmpty else {
            // Optimistic window before the engine returned a session id: clean up locally,
            // matching the compat path's not-active handling.
            handleProductLiveControlStopped(
                sessionID: nil,
                result: ProcessTapTestResult(
                    outcome: .liveControlNotActive,
                    message: "Live control is not active",
                    severity: .info
                ),
                diagnostics: processTapLiveDiagnostics
            )
            return
        }

        // Track this teardown with the settle gate so any new Product Real start waits for it (and
        // a short coreaudiod settle window) before creating its own Core Audio objects.
        let stopTask = Task {
            for sessionID in sessionIDs {
                _ = await processTapLiveController.stopSession(id: sessionID, reason: reason)
            }
        }
        productRealStartSettleGate.registerStop(stopTask)
    }

    func stopProcessTapLiveControlForTermination() {
        tearDownAllProcessTapWork(liveStopReason: .appTerminating)
    }

    /// Synchronous, idempotent teardown of every active/pending Process Tap audio work item when
    /// the system is about to sleep. Reuses the same path as termination so logs/diagnostics carry
    /// the accurate `.systemSleep` reason while preserving the stale-start / session-ID guards: any
    /// pending start that completes after this is rejected (cleared token) and its orphan engine
    /// session torn down by its own id. No automatic restart — the user re-engages after wake; the
    /// global Real App Control toggle preference is left untouched. Surfaces no status/warning.
    func handleSystemWillSleep() {
        tearDownAllProcessTapWork(liveStopReason: .systemSleep)
    }

    /// Refresh-only reconciliation after the system wakes. Output device, default selection,
    /// system volume/mute, and the visible app list may all have changed during sleep, so this
    /// pulls them fresh through the existing refresh paths (which also invalidate helper cache for
    /// removed/changed app PIDs). It deliberately does NOT restart any Product session, resolve
    /// helpers, re-enable anything, or touch the Real App Control toggle — sessions stay torn down
    /// and the user re-engages. Idempotent and safe to call repeatedly; `refreshOutputDevices`
    /// surfaces no "output changed" teardown/warning here because nothing is active post-sleep.
    func handleSystemDidWake() {
        refreshOutputDevices()
        refreshSystemOutputVolume()
        refreshApplications()
    }

    /// Shared teardown body for termination and system sleep. The two differ only in the live stop
    /// reason forwarded to the engine (`.appTerminating` vs `.systemSleep`); the helper/probe and
    /// resolver cancellations use their own `.userStopped` reason (a normal controlled stop, not a
    /// failure), and the state clears are identical. Idempotent: every call clears already-clear
    /// state and stops already-stopped engines safely.
    private func tearDownAllProcessTapWork(liveStopReason: ProcessTapLiveStopReason) {
        _ = processTapLiveController.stopLiveControlNow(reason: liveStopReason)
        _ = twoAppReadiness.stopNow(reason: liveStopReason)
        advancedHelperDiscovery.stopAutoDetect(reason: .userStopped)
        appAudioResolutionTask?.cancel()
        appAudioTargetResolver.cancelCurrentResolution(reason: .userStopped)
        appAudioTargetResolver.invalidateAllCachedTargets()
        advancedHelperDiscovery.stopProbe(reason: .userStopped)
        advancedProcessTapDiagnostics.stopReplayProbeForTermination()
        advancedManualLiveControlActive = false
        productRealControlState.clearAllStartRequests()
        productRealControlState.clearAllResolutions()
        productRealControlState.clearActiveSession()
        // Synchronous hard teardown uses `stopLiveControlNow`, which does not fire the per-session
        // onStopped callbacks that normally clear pending flags, so clear them here directly.
        productRealControlState.clearAllOperations()
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

    /// Whether a Product Real start or stop transition is currently in flight for this row. The row
    /// UI uses this to show a disabled/pending state so the user cannot spam the toggle mid-operation.
    func isExperimentalControlPending(for appID: MixerAppItem.ID) -> Bool {
        productRealControlState.isOperationPending(for: appID)
    }

    func toggleExperimentalControl(for appID: MixerAppItem.ID) {
        // Rapid-toggle guard: while a start/stop for this row is still in flight, ignore further
        // toggles so a burst of clicks cannot pile up Core Audio create/destroy churn (crackle/Starv)
        // before it reaches the settle/lifecycle gates. The flag clears when the operation completes.
        guard !productRealControlState.isOperationPending(for: appID) else {
            return
        }

        if isExperimentalControlActive(for: appID) {
            stopExperimentalControl(for: appID)
            return
        }

        startExperimentalControl(for: appID)
    }

    private func stopExperimentalControl(
        for appID: MixerAppItem.ID,
        reason: ProcessTapLiveStopReason = .userStopped
    ) {
        // Per-app stop invalidates only this app's pending start, leaving other apps untouched.
        productRealControlState.clearStartRequest(for: appID)

        guard let sessionID = productRealControlState.activeSessionsByAppID[appID]?.liveSessionID else {
            // Optimistic window or not active: clear just this app locally.
            productRealControlState.clearSession(for: appID)
            updateActiveLiveControlAppNameAfterProductChange()
            return
        }

        // Mark this row's stop transition in flight so rapid re-toggles are ignored until the stop
        // callback (`handleProductLiveControlStopped`) clears it.
        productRealControlState.beginOperation(for: appID)

        // Track this per-app teardown with the settle gate (see stopProductLiveSessions).
        let stopTask = Task {
            _ = await processTapLiveController.stopSession(id: sessionID, reason: reason)
        }
        productRealStartSettleGate.registerStop(stopTask)
    }

    private func updateActiveLiveControlAppNameAfterProductChange() {
        if advancedManualLiveControlActive {
            return
        }
        activeLiveControlAppName = productRealControlState.activeSessions.first?.displayName
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
        stopRealControlForExitedTargetApps()
        refreshProcessTapSelectionAfterAppRefresh(previousProcessTapAppID: previousProcessTapAppID)
        refreshTwoAppReadinessSelectionsAfterAppRefresh()
        refreshHelperDiscoverySelectionAfterAppRefresh()
    }

    /// After an app-list refresh, tears down Product Real Control work whose target app is
    /// no longer running: a live-controlled app that exited stops its session, and a pending
    /// helper resolution for a vanished app is cancelled.
    private func stopRealControlForExitedTargetApps() {
        let exitedActiveAppIDs = productRealControlState.activeVisibleAppIDs.filter { activeAppID in
            !apps.contains(where: { $0.id == activeAppID })
        }
        // Tear down only the exited apps' sessions/requests; surviving apps keep running.
        for exitedAppID in exitedActiveAppIDs {
            stopExperimentalControl(for: exitedAppID, reason: .targetAppExited)
        }

        if let resolvingAppID = productRealControlState.resolvingAppIDs.first,
           !apps.contains(where: { $0.id == resolvingAppID }) {
            cancelAppAudioTargetResolution(reason: .targetExited)
        }
    }

    /// Preserves the Advanced diagnostic selection when the previously selected app survived
    /// the refresh; otherwise stops any active live control for the vanished app and falls
    /// back to a preferred selection.
    private func refreshProcessTapSelectionAfterAppRefresh(previousProcessTapAppID: MixerAppItem.ID?) {
        if let previousProcessTapAppID,
           apps.contains(where: { $0.id == previousProcessTapAppID }) {
            // Keep the existing diagnostic selection and result state when the selected app survived refresh.
            return
        }

        if isProcessTapLiveControlActive {
            stopProcessTapLiveControl(reason: .targetAppExited)
        }

        advancedProcessTapDiagnostics.selectPreferredAppAfterAppRefresh(apps: apps)
        processTapLiveDiagnostics = nil
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

        // Rapid-toggle guard also covers the slider-driven auto-start path: do not kick off a new
        // start while a start/stop for this row is already in flight.
        if productRealControlState.isOperationPending(for: app.id) {
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

        if let blockReason = productSessionStartBlockReason(for: app.id) {
            showStatus(blockReason, style: .warning)
            return
        }

        startResolvedExperimentalControl(for: app)
    }

    /// Whether a new product real-control session may start for `appID`. Returns a warning
    /// message when blocked, or nil when allowed. Multiple product sessions are permitted up
    /// to `maxConcurrentLiveSessions`; Advanced manual control and diagnostics remain mutually
    /// exclusive with product control. Callers handle "already active for this app" separately.
    private func productSessionStartBlockReason(for appID: MixerAppItem.ID) -> String? {
        if isProcessTapTesting {
            return "Stop active live control first"
        }

        if advancedManualLiveControlActive {
            return "Stop the active live control first"
        }

        let alreadyCountsTowardLimit = productRealControlState.activeSessionsByAppID[appID] != nil
        if !alreadyCountsTowardLimit,
           productRealControlState.activeSessions.count >= AppConstants.maxConcurrentLiveSessions {
            return "Real app control supports \(AppConstants.maxConcurrentLiveSessions) apps at a time"
        }

        return nil
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

        if let blockReason = productSessionStartBlockReason(for: appID) {
            showStatus(blockReason, style: .warning)
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
        // Per-app start-request token: a later start for this app, or any cancellation
        // (stop / output change / toggle off / termination), supersedes this token so the
        // async completion and callbacks below can be recognised as stale and rejected.
        let startRequestID = productRealControlState.beginStartRequest(for: app.id)

        // Optimistic/early session set: `activeVisibleAppID` is read by `visibleMixerApps`
        // independently of `isProcessTapLiveControlActive`, so setting it now keeps the row
        // visible during startup and lets `refreshApplications` detect a target-app exit
        // while the async `startSession` below is still in flight. The success branch
        // re-asserts this after the await (see below).
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

        // Mark this row's start transition in flight so rapid re-toggles are ignored until the async
        // start below resolves (cleared at the top of the post-await block, for every outcome).
        productRealControlState.beginOperation(for: app.id)

        Task {
            // Teardown-settle gate: wait for any in-flight Product Real teardown to finish and for
            // coreaudiod to settle the shared output route before creating this session's Core
            // Audio objects. Suspends (does not block the main actor); no-op when nothing was torn
            // down. The optimistic "Starting…" row set above remains visible during the wait.
            await self.productRealStartSettleGate.waitForReadyToStart()

            let startResult = await processTapLiveController.startSession(
                for: target,
                gain: gain,
                timeoutPolicy: .indefinite
            ) { _, diagnostics in
                Task { @MainActor in
                    guard self.shouldAcceptProductLiveCallback(appID: app.id, requestID: startRequestID) else {
                        return
                    }
                    self.processTapLiveDiagnostics = diagnostics
                    self.advancedProcessTapDiagnostics.setProgress(diagnostics.progress)
                }
            } onStopped: { sessionID, result, diagnostics in
                Task { @MainActor in
                    self.handleProductLiveControlStopped(sessionID: sessionID, result: result, diagnostics: diagnostics)
                }
            }
            let result = startResult.result

            let accepted = await MainActor.run { () -> Bool in
                // This start attempt has resolved (success, failure, or superseded): the row's start
                // transition is over, so clear its pending flag regardless of outcome. A cached-helper
                // retry below re-marks it when it kicks off a fresh attempt.
                productRealControlState.endOperation(for: app.id)

                // Reject a stale completion: a newer start for this app, or any cancellation,
                // has superseded this request. Leave current state untouched, but drop this
                // request's own lingering optimistic entry if a newer request has not already
                // replaced it (never touch a newer request's session).
                guard productRealControlState.isCurrentStartRequest(startRequestID, for: app.id) else {
                    if productRealControlState.activeSessionsByAppID[app.id]?.startRequestID == startRequestID,
                       productRealControlState.activeSessionsByAppID[app.id]?.liveSessionID == nil {
                        productRealControlState.clearSession(for: app.id)
                        updateActiveLiveControlAppNameAfterProductChange()
                    }
                    // This start owned the "running" diagnostics flag (starts are serialised by
                    // the isProcessTapTesting guard), so clear it now that it is rejected.
                    advancedProcessTapDiagnostics.setRunning(false)
                    advancedProcessTapDiagnostics.setProgress(nil)
                    return false
                }

                productRealControlState.clearStartRequest(for: app.id)
                advancedProcessTapDiagnostics.setResult(result)
                advancedProcessTapDiagnostics.setRunning(false)

                if result.outcome == .liveControlStarted {
                    // Re-assert the session after the await with the real engine session id
                    // and the owning request id, for per-app stop/gain and callback validation.
                    productRealControlState.beginSession(
                        visibleAppID: app.id,
                        displayName: app.name,
                        controlledProcessIdentifier: target.processIdentifier,
                        source: ProductRealControlStartSource(resolutionSource: resolutionSource),
                        liveSessionID: startResult.sessionID,
                        startRequestID: startRequestID
                    )
                    activeLiveControlAppName = app.name
                } else {
                    if resolutionSource == .cachedHelper {
                        appAudioTargetResolver.invalidateCachedTarget(for: app.appAudioTargetRequest)
                    }

                    productRealControlState.clearSession(for: app.id)
                    updateActiveLiveControlAppNameAfterProductChange()
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
                        showStatus(
                            "Could not start live control for this app",
                            style: .warning,
                            action: result.suggestsSystemAudioRecordingSettings ? .openSystemAudioRecordingSettings : nil
                        )
                    }
                }

                return true
            }

            if !accepted {
                // Stale start: only the just-started orphan session is torn down, by its own
                // session id. Current state and other apps' sessions are left untouched. Register
                // the orphan teardown with the settle gate so a concurrent new start waits for it
                // (and the settle window) before creating its own Core Audio objects.
                let orphanCleanupTask = Task { await self.cleanupStaleProductLiveStart(startResult) }
                self.productRealStartSettleGate.registerStop(orphanCleanupTask)
                await orphanCleanupTask.value
            }
        }
    }

    private func shouldAcceptProductLiveCallback(
        appID: MixerAppItem.ID,
        requestID: ProductRealControlStartRequestID
    ) -> Bool {
        if productRealControlState.isCurrentStartRequest(requestID, for: appID) {
            return true
        }

        // Otherwise only accept callbacks for a confirmed (started) session that this request
        // owns. A cancelled optimistic entry still carries the request id but has no live
        // session, so its stale callbacks must be rejected.
        guard let session = productRealControlState.activeSessionsByAppID[appID] else {
            return false
        }

        return session.startRequestID == requestID && session.liveSessionID != nil
    }

    private func cleanupStaleProductLiveStart(_ startResult: ProcessTapLiveSessionStartResult) async {
        guard startResult.result.outcome == .liveControlStarted else {
            return
        }

        guard let sessionID = startResult.sessionID else {
            AppLogger.processTap.warning("Stale Product Real Control start succeeded without a session-specific cleanup handle")
            return
        }

        _ = await processTapLiveController.stopSession(id: sessionID, reason: .userStopped)
    }

    private func handleProductLiveControlStopped(
        sessionID: ProcessTapLiveSessionID?,
        result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?
    ) {
        if let sessionID {
            guard let stoppedSession = productRealControlState.activeSessions.first(where: { $0.liveSessionID == sessionID }) else {
                // A session id we no longer track: a stale orphan that was already rejected
                // and is being torn down by its own id. Leave every other app's state and the
                // shared display untouched.
                return
            }

            let stoppedAppID = stoppedSession.visibleAppID
            // If this stop arrived while the same request was still pending (engine-side stop
            // before the post-await ran), invalidate it so its late success is rejected. A
            // newer request carries a different token and is left untouched.
            if let stoppedRequestID = stoppedSession.startRequestID,
               productRealControlState.isCurrentStartRequest(stoppedRequestID, for: stoppedAppID) {
                productRealControlState.clearStartRequest(for: stoppedAppID)
            }
            productRealControlState.clearSession(for: stoppedAppID)
            // The stop transition for this row is complete: clear its rapid-toggle pending flag.
            productRealControlState.endOperation(for: stoppedAppID)

            if result.outcome == .liveControlAppExited,
               let stoppedApp = apps.first(where: { $0.id == stoppedAppID }) {
                appAudioTargetResolver.invalidateCachedTarget(for: stoppedApp.appAudioTargetRequest)
            }
        } else {
            // No session id: an optimistic-window stop. Clear all product sessions and pending flags.
            productRealControlState.clearActiveSession()
            productRealControlState.clearAllOperations()
        }

        updateActiveLiveControlAppNameAfterProductChange()
        applyLiveControlStoppedDisplay(result, diagnostics: diagnostics)
    }

    private func handleAdvancedManualLiveControlStopped(
        _ result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?
    ) {
        advancedManualLiveControlActive = false
        activeLiveControlAppName = nil
        applyLiveControlStoppedDisplay(result, diagnostics: diagnostics)
    }

    private func applyLiveControlStoppedDisplay(
        _ result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?
    ) {
        advancedProcessTapDiagnostics.setResult(result)
        processTapLiveDiagnostics = diagnostics
        advancedProcessTapDiagnostics.setProgress(diagnostics?.progress)
        advancedProcessTapDiagnostics.setRunning(false)
        if result.outcome == .liveControlOutputChanged {
            appAudioTargetResolver.invalidateAllCachedTargets()
        }
        showLiveControlWarningIfNeeded(for: result)
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

            if let blockReason = productSessionStartBlockReason(for: app.id) {
                showStatus(blockReason, style: .warning)
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
        if let message = result.liveControlWarningMessage {
            showStatus(
                message,
                style: .warning,
                action: result.suggestsSystemAudioRecordingSettings ? .openSystemAudioRecordingSettings : nil
            )
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
        guard isExperimentalControlActive(for: app.id),
              let sessionID = productRealControlState.activeSessionsByAppID[app.id]?.liveSessionID else {
            return
        }

        processTapLiveController.updateGain(sessionID: sessionID, gain: ProductRealControlState.gainOption(for: app))
    }

    private var isAppAudioTargetResolving: Bool {
        productRealControlState.isResolving
    }

    private func showStatus(
        _ text: String,
        style: MixerStatusMessage.Style,
        action: MixerStatusMessage.Action? = nil
    ) {
        let message = MixerStatusMessage(text: text, style: style, action: action)
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
