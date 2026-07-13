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
    private var state = ProductRealControlState()
    private var onWillChange: (() -> Void)?
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
    }

    /// Registers a handler fired immediately before every `productRealControlState` mutation, so the
    /// owning view model can forward it to `objectWillChange` — preserving the notification the
    /// state's previous `@Published` wrapper provided.
    func setOnWillChange(_ onWillChange: @escaping () -> Void) {
        self.onWillChange = onWillChange
    }

    /// The Product Real session/pending/resolution state. Reads return the current value; a write
    /// fires `onWillChange` *before* applying, so a mutating call routed through this property
    /// notifies exactly once — matching the old `@Published` `willSet` timing. The get/set shape lets
    /// `MixerViewModel` keep calling the existing state operations unchanged during this ownership
    /// move (its own `productRealControlState` computed property forwards here).
    var productRealControlState: ProductRealControlState {
        get { state }
        set {
            onWillChange?()
            state = newValue
        }
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
                    updateActiveLiveControlAppNameAfterProductChange()
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

    // MARK: - Per-app stop leaf
    //
    // Moved from `MixerViewModel` (Phase C). Behavior, ordering, default stop reason,
    // pending-operation semantics, and settle-gate registration are preserved verbatim; only the
    // receivers changed — state via the `productRealControlState` property so `onWillChange` still
    // fires, and the live-session manager / settle gate are the same injected instances the view
    // model previously used. The terminal pending-flag clear is owned by the stop callback
    // (`handleProductLiveControlStopped`, also on this coordinator).

    /// Stops Product Real Control for a single app. Invalidates only this app's pending start, then
    /// reads its `liveSessionID` before clearing anything: with no live session (optimistic window or
    /// not active) it clears just this app locally and refreshes the active-name display without
    /// touching the engine; with a live session it marks the row's stop transition in flight and tears
    /// the session down through the settle gate.
    func stopExperimentalControl(
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
            _ = await liveSessionManager.stopSession(id: sessionID, reason: reason)
        }
        startSettleGate.registerStop(stopTask)
    }

    // MARK: - Stop-all core and engine stop-callback handling
    //
    // Moved from `MixerViewModel` (Phase C). Behavior, ordering, session-ID matching, pending-operation
    // clearing, active-name refresh, and diagnostics/display handling are preserved verbatim; only the
    // receivers changed — state via `productRealControlState` (so `onWillChange` still fires), reads via
    // the weak `context`, and the shared display cleanup via the `sideEffects` seam callback
    // (`applyLiveControlStoppedDisplay`, whose implementation stays in the view model because
    // advanced-manual stop uses it too). The outer product-vs-advanced router, the global/lifecycle
    // fan-out entry points, and the shared display helper remain in `MixerViewModel`.

    /// Stops every active Product Real session by its own engine session id, tracked with the settle
    /// gate so a new start waits for the teardown (and coreaudiod settle). In the optimistic window
    /// (no engine session id yet) it takes the same not-active local-cleanup path the compat stop used.
    /// Delegated to by the view model's `stopProcessTapLiveControl` router; it clears no advanced-manual
    /// state.
    func stopProductLiveSessions(reason: ProcessTapLiveStopReason) {
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
                diagnostics: context?.processTapLiveDiagnostics
            )
            return
        }

        // Track this teardown with the settle gate so any new Product Real start waits for it (and
        // a short coreaudiod settle window) before creating its own Core Audio objects.
        let stopTask = Task {
            for sessionID in sessionIDs {
                _ = await liveSessionManager.stopSession(id: sessionID, reason: reason)
            }
        }
        startSettleGate.registerStop(stopTask)
    }

    /// Handles a Product Real session's engine `onStopped` callback (and the optimistic-window
    /// no-session-id stop). Maps the session id to its app and clears only that app's session /
    /// pending start / operation state; an untracked (stale/orphan) session id leaves every other
    /// app's state and the shared display untouched. Then refreshes the active-name display and runs
    /// the shared stop/display cleanup through the seam.
    func handleProductLiveControlStopped(
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
               let stoppedApp = context?.apps.first(where: { $0.id == stoppedAppID }) {
                appAudioTargetResolver.invalidateCachedTarget(for: stoppedApp.appAudioTargetRequest)
            }
        } else {
            // No session id: an optimistic-window stop. Clear all product sessions and pending flags.
            productRealControlState.clearActiveSession()
            productRealControlState.clearAllOperations()
        }

        updateActiveLiveControlAppNameAfterProductChange()
        sideEffects?.applyLiveControlStoppedDisplay(result: result, diagnostics: diagnostics)
    }

    // MARK: - App-exit stop slice
    //
    // Moved from `MixerViewModel` (Phase C). Called by the view model's `refreshApplications` after
    // it refreshes the running-app list (that orchestration stays in the view model). Behavior is
    // preserved verbatim; only the receivers changed — the running-app list is read via `context`,
    // and the per-app stop / resolution-cancel go through the coordinator's own leaves (so
    // pending-operation and active-name behavior are unchanged).

    /// After an app-list refresh, tears down Product Real Control work whose target app is
    /// no longer running: a live-controlled app that exited stops its session, and a pending
    /// helper resolution for a vanished app is cancelled.
    func stopRealControlForExitedTargetApps() {
        let runningApps = context?.apps ?? []
        let exitedActiveAppIDs = productRealControlState.activeVisibleAppIDs.filter { activeAppID in
            !runningApps.contains(where: { $0.id == activeAppID })
        }
        // Tear down only the exited apps' sessions/requests; surviving apps keep running.
        for exitedAppID in exitedActiveAppIDs {
            stopExperimentalControl(for: exitedAppID, reason: .targetAppExited)
        }

        if let resolvingAppID = productRealControlState.resolvingAppIDs.first,
           !runningApps.contains(where: { $0.id == resolvingAppID }) {
            cancelAppAudioTargetResolution(reason: .targetExited)
        }
    }

    // MARK: - Hard-teardown state reset
    //
    // Moved from `MixerViewModel` (Phase C). This is only the Product Real-owned *state* reset block
    // of `tearDownAllProcessTapWork` — the engine hard stop (`stopLiveControlNow`), two-app readiness,
    // helper/probe, resolver invalidation, diagnostics/replay cleanup, advanced-manual reset, and the
    // resolution-task cancel all stay in the view model's teardown at their existing positions (the
    // resolution-task cancel is left in place rather than folded in here so the surrounding non-product
    // ordering is unchanged). No engine `stopSession` is issued here.

    /// Clears all Product Real session/request/resolution/operation state and resets the shared
    /// active-name display, for the synchronous hard teardown (sleep / termination). Mutates state via
    /// the `productRealControlState` property so `onWillChange` still fires. The view model's
    /// `tearDownAllProcessTapWork` calls this in place of its previous inline Product Real state resets.
    func tearDownProductStateForHardStop() {
        productRealControlState.clearAllStartRequests()
        productRealControlState.clearAllResolutions()
        productRealControlState.clearActiveSession()
        // Synchronous hard teardown uses `stopLiveControlNow`, which does not fire the per-session
        // onStopped callbacks that normally clear pending flags, so clear them here directly.
        productRealControlState.clearAllOperations()
        sideEffects?.setActiveLiveControlAppName(nil)
    }

    /// Sets the shared "active live-control app" name from the current product sessions, unless the
    /// Advanced manual session owns the display. Moved from `MixerViewModel`; the view model's
    /// remaining stop paths forward here.
    func updateActiveLiveControlAppNameAfterProductChange() {
        if context?.advancedManualLiveControlActive == true {
            return
        }
        sideEffects?.setActiveLiveControlAppName(productRealControlState.activeSessions.first?.displayName)
    }
}
