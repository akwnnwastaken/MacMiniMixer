import AppKit
import Foundation

@MainActor
final class MixerViewModel: ObservableObject {
    @Published private(set) var apps: [MixerAppItem]
    @Published private(set) var statusMessage: MixerStatusMessage?
    @Published private(set) var processTapLiveDiagnostics: ProcessTapLiveDiagnostics?
    @Published private(set) var advancedManualLiveControlActive = false
    @Published private(set) var activeLiveControlAppName: String?
    /// Product Real state now lives in `productRealControlCoordinator`; this forwards reads and
    /// writes to it. Product-only start/stop logic is delegated to that coordinator; the view model
    /// remains the cross-subsystem / UI orchestration hub (router, shared display, lifecycle, and
    /// global fan-out). The coordinator fires `objectWillChange` on every write via the
    /// `setOnWillChange` wiring in `init`, replacing the previous `@Published` behavior.
    private var productRealControlState: ProductRealControlState {
        get { productRealControlCoordinator.productRealControlState }
        set { productRealControlCoordinator.productRealControlState = newValue }
    }

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
    private let statusMessageController = MixerStatusMessageController()
    /// Product Real dependency container; **owns `ProductRealControlState`**. Orchestration still
    /// lives in this view model and reaches the state through the `productRealControlState`
    /// forwarding property. Assigned at the end of `init` once `self` (the seam) is fully
    /// initialized. The implicitly-unwrapped `!` is deliberate and now load-bearing: eager
    /// end-of-`init` assignment guarantees `setOnWillChange` is wired before any state mutation can
    /// occur (a `lazy` alternative could create the coordinator on first state access *before* the
    /// change handler is installed, dropping a UI update). Nothing reads the state during `init`, so
    /// the IUO is never accessed while nil.
    private var productRealControlCoordinator: ProductRealControlCoordinator!
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

        // Build the Product Real dependency container now that `self` (the seam) is fully
        // initialized. It owns `ProductRealControlState`; orchestration still runs in this view
        // model and reaches the state through the `productRealControlState` forwarding property.
        productRealControlCoordinator = ProductRealControlCoordinator(
            liveSessionManager: processTapLiveController,
            appAudioTargetResolver: appAudioTargetResolver,
            startSettleGate: productRealStartSettleGate,
            processTapEligibility: processTapEligibility,
            sideEffects: self,
            context: self
        )
        // Forward the coordinator's state-change notifications to `objectWillChange`, replacing the
        // previous `@Published` behavior of the state. Wired eagerly here (see the IUO note on the
        // coordinator property) so the handler is installed before any state mutation can occur.
        productRealControlCoordinator.setOnWillChange { [weak self] in
            self?.objectWillChange.send()
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
        // The resolution task now lives in `productRealControlCoordinator`, whose own `deinit`
        // cancels it as it is released alongside this view model.
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
        MixerVisibleAppsFilter.visibleApps(
            apps: apps,
            showAllApps: showAllApps,
            activeVisibleAppIDs: Set(productRealControlState.activeVisibleAppIDs),
            resolvingAppIDs: Set(productRealControlState.resolvingAppIDs),
            selectedProcessTapAppID: selectedProcessTapAppID,
            isLiveControlActive: isProcessTapLiveControlActive
        )
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
            productRealControlCoordinator.cancelAppAudioTargetResolution(reason: .userStopped)
            appAudioTargetResolver.invalidateAllCachedTargets()
        }
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
            productRealControlCoordinator.cancelAppAudioTargetResolution(reason: .outputDeviceChanged)
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
            productRealControlCoordinator.stopProductLiveSessions(reason: reason)
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
        productRealControlCoordinator.cancelResolutionTask()
        appAudioTargetResolver.cancelCurrentResolution(reason: .userStopped)
        appAudioTargetResolver.invalidateAllCachedTargets()
        advancedHelperDiscovery.stopProbe(reason: .userStopped)
        advancedProcessTapDiagnostics.stopReplayProbeForTermination()
        advancedManualLiveControlActive = false
        // Product Real-owned state reset (clears sessions/requests/resolutions/pending ops and the
        // active-name display). `stopLiveControlNow` above does not fire the per-session onStopped
        // callbacks that normally clear pending flags, so this clears them directly.
        productRealControlCoordinator.tearDownProductStateForHardStop()
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
            productRealControlCoordinator.cancelAppAudioTargetResolution(reason: .userStopped)
            return
        }

        stopTwoAppReadiness(reason: .userStopped)
        stopHelperProcessAutoDetect(reason: .userStopped)
        productRealControlCoordinator.cancelAppAudioTargetResolution(reason: .userStopped)
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
            productRealControlCoordinator.stopExperimentalControl(for: appID)
            return
        }

        productRealControlCoordinator.startExperimentalControl(for: appID)
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
        productRealControlCoordinator.stopRealControlForExitedTargetApps()
        refreshProcessTapSelectionAfterAppRefresh(previousProcessTapAppID: previousProcessTapAppID)
        refreshTwoAppReadinessSelectionsAfterAppRefresh()
        refreshHelperDiscoverySelectionAfterAppRefresh()
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
        guard productRealContext.isExperimentalRealAppControlEnabled else {
            return
        }

        guard !productRealContext.isTwoAppReadinessRunning else {
            productRealSideEffects.showProductRealStatus("Stop two-app test first", style: .warning, action: nil)
            return
        }

        guard app.isEligibleForExperimentalLiveControl else {
            productRealSideEffects.showProductRealStatus("This app is not available for real app control", style: .warning, action: nil)
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

        if productRealContext.isAppAudioTargetResolving {
            productRealSideEffects.showProductRealStatus("Finish resolving app audio first", style: .warning, action: nil)
            return
        }

        if productRealContext.isHelperBusy {
            productRealSideEffects.showProductRealStatus("Stop helper probe first", style: .warning, action: nil)
            return
        }

        if isExperimentalControlActive(for: app.id) {
            return
        }

        if let blockReason = productRealControlCoordinator.productSessionStartBlockReason(for: app.id) {
            productRealSideEffects.showProductRealStatus(blockReason, style: .warning, action: nil)
            return
        }

        productRealControlCoordinator.startResolvedExperimentalControl(for: app)
    }


    // Witnesses `ProductRealControlSideEffects.applyLiveControlStoppedDisplay`, letting the coordinator
    // (which now owns `handleProductLiveControlStopped`) run the shared stop/display cleanup that stays
    // here because advanced-manual stop also uses it. Forwards to the existing private implementation.
    func applyLiveControlStoppedDisplay(
        result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?
    ) {
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

    var isAppAudioTargetResolving: Bool {
        productRealControlState.isResolving
    }

    private func showStatus(
        _ text: String,
        style: MixerStatusMessage.Style,
        action: MixerStatusMessage.Action? = nil
    ) {
        let message = MixerStatusMessage(text: text, style: style, action: action)
        statusMessageController.show(
            message,
            setMessage: { [weak self] in self?.statusMessage = $0 },
            currentMessageID: { [weak self] in self?.statusMessage?.id }
        )
    }

    /// The Product Real write/read seam, typed as the narrow protocols (see
    /// `ProductRealControlSideEffects`). Product Real code goes through these so a future
    /// `ProductRealControlCoordinator` can receive them as injected collaborators instead of the
    /// whole view model. Both are `self` today; no behavior change.
    private var productRealSideEffects: ProductRealControlSideEffects { self }
    private var productRealContext: ProductRealControlContext { self }

}

extension MixerViewModel: ProductRealControlSideEffects {
    func showProductRealStatus(
        _ text: String,
        style: MixerStatusMessage.Style,
        action: MixerStatusMessage.Action?
    ) {
        showStatus(text, style: style, action: action)
    }

    func setActiveLiveControlAppName(_ name: String?) {
        activeLiveControlAppName = name
    }

    func setProcessTapLiveDiagnostics(_ diagnostics: ProcessTapLiveDiagnostics?) {
        processTapLiveDiagnostics = diagnostics
    }

    func setLiveControlDiagnosticResult(_ result: ProcessTapTestResult) {
        advancedProcessTapDiagnostics.setResult(result)
    }

    func setLiveControlDiagnosticProgress(_ progress: ProcessTapDiagnosticProgress?) {
        advancedProcessTapDiagnostics.setProgress(progress)
    }

    func setLiveControlDiagnosticRunning(_ isRunning: Bool) {
        advancedProcessTapDiagnostics.setRunning(isRunning)
    }

}

extension MixerViewModel: ProductRealControlContext {
    /// `helperProcessProbeRunningPID != nil || isHelperProcessAutoDetectRunning`, surfaced as one
    /// flag for the Product Real start-block checks (unchanged condition, just named).
    var isHelperBusy: Bool {
        helperProcessProbeRunningPID != nil || isHelperProcessAutoDetectRunning
    }
}

extension MixerAppItem {
    var appAudioTargetRequest: AppAudioTargetRequest {
        AppAudioTargetRequest(
            appID: id,
            appName: name,
            processIdentifier: processIdentifier
        )
    }
}
