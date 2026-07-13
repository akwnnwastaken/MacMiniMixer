import AppKit
import Foundation

/// Owns Product Real Control's state and product-only start/stop logic.
///
/// This type owns the Product Real **start and stop** paths and calls out through the injected
/// `ProductRealControlSideEffects` / `ProductRealControlContext` seam instead of touching the view
/// model directly. It owns: `ProductRealControlState`; app-audio resolution and the resolution task;
/// the async start body (both `startExperimentalControl` overloads); stale-start cleanup; the per-app
/// stop leaf (`stopExperimentalControl`); the Stop All core (`stopProductLiveSessions`); engine
/// stop-callback handling (`handleProductLiveControlStopped`, invoked **locally** from the start
/// body's `onStopped`); the app-exit cleanup slice (`stopRealControlForExitedTargetApps`); and the
/// hard-teardown Product Real state reset (`tearDownProductStateForHardStop`).
///
/// `MixerViewModel` still owns only the cross-subsystem / UI orchestration: the row
/// `toggleExperimentalControl` entry point, the product-vs-advanced-manual `stopProcessTapLiveControl`
/// router, the shared display cleanup helper (`applyLiveControlStoppedDisplay`, reached through the
/// seam and also used by advanced-manual stop), and the lifecycle / output-device-change / global
/// teardown fan-out.
///
/// The seam references are held **weakly**: the view model owns this coordinator, so a strong back
/// reference would form a retain cycle.
///
/// The coordinator **owns `ProductRealControlState`** (the Product Real session/pending/resolution
/// state). The view model reaches the state through the `productRealControlState` get/set forwarding
/// property below; the state's previous `@Published` change notification is preserved via
/// `onWillChange` (the view model forwards it to `objectWillChange`).
@MainActor
final class ProductRealControlCoordinator {
    private let liveSessionManager: ProcessTapLiveControlling & ProcessTapLiveSessionManaging
    private let appAudioTargetResolver: AppAudioTargetResolving
    private let startSettleGate: ProductRealStartSettling
    private let processTapEligibility: @Sendable (Int32?) -> ProcessTapProcessEligibility
    private weak var sideEffects: ProductRealControlSideEffects?
    private weak var context: ProductRealControlContext?
    private let stateStore = ProductRealControlStateStore()
    private let stopCoordinator: ProductRealStopCoordinator
    private var appAudioResolutionTask: Task<Void, Never>?

    deinit {
        // Cancel the in-flight resolution task on dealloc (the view model that owns this coordinator
        // is being torn down). Mirrors the cancel the view model's own `deinit` used to perform.
        appAudioResolutionTask?.cancel()
    }

    init(
        liveSessionManager: ProcessTapLiveControlling & ProcessTapLiveSessionManaging,
        appAudioTargetResolver: AppAudioTargetResolving,
        startSettleGate: ProductRealStartSettling,
        processTapEligibility: @escaping @Sendable (Int32?) -> ProcessTapProcessEligibility,
        sideEffects: ProductRealControlSideEffects,
        context: ProductRealControlContext
    ) {
        self.liveSessionManager = liveSessionManager
        self.appAudioTargetResolver = appAudioTargetResolver
        self.startSettleGate = startSettleGate
        self.processTapEligibility = processTapEligibility
        self.sideEffects = sideEffects
        self.context = context
        // The stop coordinator shares the single state store, the same injected engine/settle/resolver
        // dependencies, and the same weak seam. It has no reference back to the start/resolution side.
        self.stopCoordinator = ProductRealStopCoordinator(
            stateStore: stateStore,
            liveSessionManager: liveSessionManager,
            startSettleGate: startSettleGate,
            appAudioTargetResolver: appAudioTargetResolver,
            sideEffects: sideEffects,
            context: context
        )
        // All stored properties are now initialized, so `self` is usable: wire the one stop→resolution
        // edge (the app-exit path cancelling an in-flight resolution) as a narrow closure rather than a
        // sibling reference. `[weak self]` keeps the facade→stopCoordinator→closure chain cycle-free.
        stopCoordinator.setCancelResolution { [weak self] reason in
            self?.cancelAppAudioTargetResolution(reason: reason)
        }
    }

    /// Registers a handler fired immediately before every `productRealControlState` mutation, so the
    /// owning view model can forward it to `objectWillChange` — preserving the notification the
    /// state's previous `@Published` wrapper provided. Forwards to the shared `stateStore`.
    func setOnWillChange(_ onWillChange: @escaping () -> Void) {
        stateStore.setOnWillChange(onWillChange)
    }

    /// The Product Real session/pending/resolution state, owned by the shared `stateStore`. Reads
    /// return the current value; a write fires `onWillChange` *before* applying, so a mutating call
    /// routed through this property notifies exactly once — matching the old `@Published` `willSet`
    /// timing. This facade property remains the mutation path for every coordinator method and keeps
    /// `MixerViewModel`'s existing call sites unchanged (its own `productRealControlState` computed
    /// property forwards here).
    var productRealControlState: ProductRealControlState {
        get { stateStore.productRealControlState }
        set { stateStore.productRealControlState = newValue }
    }

    /// Tears down a stale/orphaned Product Real start's just-created session by its own session id.
    /// Called by the coordinator's async start body after it rejects a superseded
    /// start. Stateless: reads only the start result and the held live-session manager, and uses the
    /// same `.userStopped` stop reason as before. No-op when the start did not actually start a live
    /// session, or when it started without a session-specific cleanup handle.
    func cleanupStaleProductLiveStart(_ startResult: ProcessTapLiveSessionStartResult) async {
        guard startResult.result.outcome == .liveControlStarted else {
            return
        }

        guard let sessionID = startResult.sessionID else {
            AppLogger.processTap.warning("Stale Product Real Control start succeeded without a session-specific cleanup handle")
            return
        }

        _ = await liveSessionManager.stopSession(id: sessionID, reason: .userStopped)
    }

    // MARK: - App-audio resolution slice
    //
    // Moved from `MixerViewModel` (Phase C). When a target is ready these methods call the async
    // start body (`startExperimentalControl`, now also on this coordinator). State mutations go
    // through the `productRealControlState` property so its `onWillChange` still fires.

    /// Starts Product Real for `app`, resolving an audio-helper target first when the visible process
    /// is not directly eligible. Preserves the previous eligibility/permission/helper checks and
    /// status messages verbatim.
    func startResolvedExperimentalControl(for app: MixerAppItem, allowsCachedLookup: Bool = true) {
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
            sideEffects?.showProductRealStatus(
                ProcessTapPermissionMessage.message(
                    forEligibilityReason: visibleEligibility.reason,
                    fallback: visibleEligibility.reason ?? "Process Tap is unavailable"
                ),
                style: .warning,
                action: nil
            )
            return
        }

        guard HelperProcessCandidateDiscovery.isLikelyHelperResolvable(app.helperProcessDiscoveryTarget) else {
            sideEffects?.showProductRealStatus("This app is not available for real app control", style: .warning, action: nil)
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

    /// Handles the async resolution result: accepts it only while still resolving for `appID`, clears
    /// the resolving state, and — for a resolved target — re-runs the start preflight before kicking
    /// off the async start body. Same status messages and cancellation behavior as before.
    func handleAppAudioTargetResolution(_ result: AppAudioTargetResolutionResult?, for appID: MixerAppItem.ID) {
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
            guard let app = context?.apps.first(where: { $0.id == resolvedTarget.visibleAppID }) else {
                sideEffects?.showProductRealStatus("This app is not available for real app control", style: .warning, action: nil)
                return
            }

            guard context?.isTwoAppReadinessRunning != true else {
                sideEffects?.showProductRealStatus("Stop two-app test first", style: .warning, action: nil)
                return
            }

            if let blockReason = productSessionStartBlockReason(for: app.id) {
                sideEffects?.showProductRealStatus(blockReason, style: .warning, action: nil)
                return
            }

            startExperimentalControl(
                for: app,
                target: resolvedTarget.target,
                resolutionSource: resolvedTarget.source
            )

        case .unavailable(let reason):
            sideEffects?.showProductRealStatus(reason, style: .warning, action: nil)

        case .cancelled:
            break
        }
    }

    /// Cancels an in-flight resolution and clears resolving state (guarded on actually resolving), the
    /// same as the view model's previous `cancelAppAudioTargetResolution`.
    func cancelAppAudioTargetResolution(reason: ProcessTapCandidateProbeStopReason) {
        guard productRealControlState.isResolving else {
            return
        }

        appAudioResolutionTask?.cancel()
        appAudioResolutionTask = nil
        productRealControlState.clearAllResolutions()
        appAudioTargetResolver.cancelCurrentResolution(reason: reason)
    }

    /// Cancels only the resolution task, for the synchronous sleep/termination teardown path where the
    /// view model already performs the resolver cancel and state clears alongside its other teardown.
    func cancelResolutionTask() {
        appAudioResolutionTask?.cancel()
        appAudioResolutionTask = nil
    }

    /// Whether a new product real-control session may start for `appID`. Returns a warning message
    /// when blocked, or nil when allowed. Multiple product sessions are permitted up to
    /// `maxConcurrentLiveSessions`; Advanced manual control and diagnostics remain mutually exclusive
    /// with product control. Callers handle "already active for this app" separately.
    func productSessionStartBlockReason(for appID: MixerAppItem.ID) -> String? {
        if context?.isProcessTapTesting == true {
            return "Stop active live control first"
        }

        if context?.advancedManualLiveControlActive == true {
            return "Stop the active live control first"
        }

        if productRealControlState.wouldExceedConcurrentSessionCap(
            for: appID,
            cap: AppConstants.maxConcurrentLiveSessions
        ) {
            return "Real app control supports \(AppConstants.maxConcurrentLiveSessions) apps at a time"
        }

        return nil
    }

    // MARK: - Async start body
    //
    // Moved from `MixerViewModel` (Phase C). Conditions, ordering, strings, stop reason, timeout
    // policy, settle-gate ordering, pending-operation and diagnostics behavior are all preserved
    // verbatim; only the receivers changed (state via the `productRealControlState` property so
    // `onWillChange` still fires, side effects/reads via the weak seam). The engine `onStopped`
    // callback is handled locally by this coordinator's `handleProductLiveControlStopped`.

    /// Synchronous start preflight for the row toggle: validates busy/cap/eligibility and builds the
    /// direct-PID target, then hands off to the async start body.
    func startExperimentalControl(for appID: MixerAppItem.ID) {
        guard context?.isTwoAppReadinessRunning != true else {
            sideEffects?.showProductRealStatus("Stop two-app test first", style: .warning, action: nil)
            return
        }

        guard context?.isProcessTapTesting != true,
              context?.isAppAudioTargetResolving != true else {
            sideEffects?.showProductRealStatus("Process Tap is already busy", style: .warning, action: nil)
            return
        }

        if let blockReason = productSessionStartBlockReason(for: appID) {
            sideEffects?.showProductRealStatus(blockReason, style: .warning, action: nil)
            return
        }

        guard let app = context?.apps.first(where: { $0.id == appID }) else {
            sideEffects?.showProductRealStatus("This app is not available for live control", style: .warning, action: nil)
            return
        }

        guard app.isEligibleForExperimentalLiveControl else {
            sideEffects?.showProductRealStatus("No valid process found", style: .warning, action: nil)
            return
        }

        guard let processIdentifier = app.processIdentifier,
              NSRunningApplication(processIdentifier: pid_t(processIdentifier)) != nil else {
            sideEffects?.showProductRealStatus("This app is not available for live control", style: .warning, action: nil)
            return
        }

        let target = ProcessTapTarget(
            appID: app.id,
            appName: app.name,
            processIdentifier: app.processIdentifier
        )
        startExperimentalControl(for: app, target: target)
    }

    func startExperimentalControl(
        for app: MixerAppItem,
        target: ProcessTapTarget,
        resolutionSource: ResolvedAppAudioTarget.Source? = nil
    ) {
        guard target.processIdentifier.map({ $0 > 0 }) == true else {
            sideEffects?.showProductRealStatus("This app is not available for live control", style: .warning, action: nil)
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
        sideEffects?.setActiveLiveControlAppName(app.name)
        sideEffects?.setLiveControlDiagnosticResult(
            ProcessTapTestResult(
                outcome: .liveControlStarting,
                message: "Starting experimental live control for \(app.name)...",
                detail: "This may affect real audio for this app only. Gain \(gain.percentLabel).",
                severity: .info
            )
        )
        sideEffects?.setLiveControlDiagnosticProgress(
            ProcessTapDiagnosticProgress(
                callbackCount: 0,
                peakLevel: 0,
                rmsLevel: 0,
                audioDetected: false
            )
        )
        sideEffects?.setProcessTapLiveDiagnostics(nil)
        sideEffects?.setLiveControlDiagnosticRunning(true)

        // Mark this row's start transition in flight so rapid re-toggles are ignored until the async
        // start below resolves (cleared at the top of the post-await block, for every outcome).
        productRealControlState.beginOperation(for: app.id)

        Task {
            // Teardown-settle gate: wait for any in-flight Product Real teardown to finish and for
            // coreaudiod to settle the shared output route before creating this session's Core
            // Audio objects. Suspends (does not block the main actor); no-op when nothing was torn
            // down. The optimistic "Starting…" row set above remains visible during the wait.
            await self.startSettleGate.waitForReadyToStart()

            let startResult = await liveSessionManager.startSession(
                for: target,
                gain: gain,
                timeoutPolicy: .indefinite
            ) { _, diagnostics in
                Task { @MainActor in
                    guard self.productRealControlState.shouldAcceptCallback(for: app.id, requestID: startRequestID) else {
                        return
                    }
                    self.sideEffects?.setProcessTapLiveDiagnostics(diagnostics)
                    self.sideEffects?.setLiveControlDiagnosticProgress(diagnostics.progress)
                }
            } onStopped: { sessionID, result, diagnostics in
                Task { @MainActor in
                    self.stopCoordinator.handleProductLiveControlStopped(sessionID: sessionID, result: result, diagnostics: diagnostics)
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
                        stopCoordinator.updateActiveLiveControlAppNameAfterProductChange()
                    }
                    // This start owned the "running" diagnostics flag (starts are serialised by
                    // the isProcessTapTesting guard), so clear it now that it is rejected.
                    sideEffects?.setLiveControlDiagnosticRunning(false)
                    sideEffects?.setLiveControlDiagnosticProgress(nil)
                    return false
                }

                productRealControlState.clearStartRequest(for: app.id)
                sideEffects?.setLiveControlDiagnosticResult(result)
                sideEffects?.setLiveControlDiagnosticRunning(false)

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
                    sideEffects?.setActiveLiveControlAppName(app.name)
                } else {
                    if resolutionSource == .cachedHelper {
                        appAudioTargetResolver.invalidateCachedTarget(for: app.appAudioTargetRequest)
                    }

                    productRealControlState.clearSession(for: app.id)
                    stopCoordinator.updateActiveLiveControlAppNameAfterProductChange()
                    sideEffects?.setProcessTapLiveDiagnostics(nil)
                    sideEffects?.setLiveControlDiagnosticProgress(nil)

                    if resolutionSource == .cachedHelper,
                       context?.isExperimentalRealAppControlEnabled == true,
                       context?.isTwoAppReadinessRunning != true,
                       context?.isProcessTapLiveControlActive != true,
                       context?.isAppAudioTargetResolving != true {
                        startResolvedExperimentalControl(for: app, allowsCachedLookup: false)
                    } else {
                        if resolutionSource == .discoveredHelper {
                            appAudioTargetResolver.invalidateCachedTarget(for: app.appAudioTargetRequest)
                        }
                        sideEffects?.showProductRealStatus(
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
                self.startSettleGate.registerStop(orphanCleanupTask)
                await orphanCleanupTask.value
            }
        }
    }

    // MARK: - Stop path (forwarded to ProductRealStopCoordinator)
    //
    // Thin facade forwards to `stopCoordinator`, which owns the cohesive Product Real stop logic.
    // `MixerViewModel` calls only these facade methods; it has no knowledge of the stop coordinator.
    // The start body above reaches the stop coordinator's `handleProductLiveControlStopped` and
    // `updateActiveLiveControlAppNameAfterProductChange` directly (both objects are owned by this
    // facade), so no Start<->Stop sibling reference exists.

    /// Stops Product Real Control for a single app. Forwards to the stop coordinator.
    func stopExperimentalControl(
        for appID: MixerAppItem.ID,
        reason: ProcessTapLiveStopReason = .userStopped
    ) {
        stopCoordinator.stopExperimentalControl(for: appID, reason: reason)
    }

    /// Stops every active Product Real session (Stop All product core). Forwards to the stop coordinator.
    func stopProductLiveSessions(reason: ProcessTapLiveStopReason) {
        stopCoordinator.stopProductLiveSessions(reason: reason)
    }

    /// Tears down Product Real work for apps that exited during an app-list refresh. Forwards to the
    /// stop coordinator (whose app-exit path cancels an in-flight resolution via the facade-wired closure).
    func stopRealControlForExitedTargetApps() {
        stopCoordinator.stopRealControlForExitedTargetApps()
    }

    /// Clears the Product Real state during hard teardown (sleep / termination). Forwards to the stop
    /// coordinator.
    func tearDownProductStateForHardStop() {
        stopCoordinator.tearDownProductStateForHardStop()
    }

}
