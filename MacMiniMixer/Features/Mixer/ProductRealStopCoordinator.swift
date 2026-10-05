import Foundation

/// Owns the Product Real **stop** path — the cohesive teardown logic extracted from
/// `ProductRealControlCoordinator`: the per-app stop leaf, the Stop All core, the engine
/// stop-callback handler, the app-exit cleanup slice, the hard-teardown Product Real state reset,
/// and the shared active-name helper.
///
/// It shares the single `ProductRealControlStateStore` (so `onWillChange` fires exactly once per
/// write) and holds the same injected `liveSessionManager` / `startSettleGate` / `appAudioTargetResolver`
/// as the facade. The seam references are held **weakly** (the view model transitively owns this
/// coordinator, so a strong back reference would form a retain cycle).
///
/// It has **no** reference to the start/resolution side. The one stop→resolution edge (the app-exit
/// path cancelling an in-flight resolution) is a narrow `cancelResolution` closure the facade wires to
/// its own resolution-cancellation, so no Start↔Stop ownership cycle exists.
@MainActor
final class ProductRealStopCoordinator {
    private let stateStore: ProductRealControlStateStore
    private let liveSessionManager: ProcessTapLiveControlling & ProcessTapLiveSessionManaging
    private let startSettleGate: ProductRealStartSettling
    private let appAudioTargetResolver: AppAudioTargetResolving
    private weak var sideEffects: ProductRealControlSideEffects?
    private weak var context: ProductRealControlContext?
    private var cancelResolution: @MainActor (ProcessTapCandidateProbeStopReason) -> Void

    init(
        stateStore: ProductRealControlStateStore,
        liveSessionManager: ProcessTapLiveControlling & ProcessTapLiveSessionManaging,
        startSettleGate: ProductRealStartSettling,
        appAudioTargetResolver: AppAudioTargetResolving,
        sideEffects: ProductRealControlSideEffects,
        context: ProductRealControlContext,
        cancelResolution: @escaping @MainActor (ProcessTapCandidateProbeStopReason) -> Void = { _ in }
    ) {
        self.stateStore = stateStore
        self.liveSessionManager = liveSessionManager
        self.startSettleGate = startSettleGate
        self.appAudioTargetResolver = appAudioTargetResolver
        self.sideEffects = sideEffects
        self.context = context
        self.cancelResolution = cancelResolution
    }

    /// Narrow post-init setter for the app-exit resolution-cancel edge. Used by the facade to wire the
    /// closure after both the facade and this coordinator are fully initialized, avoiding a self-capture
    /// during the facade's initializer.
    func setCancelResolution(_ cancelResolution: @escaping @MainActor (ProcessTapCandidateProbeStopReason) -> Void) {
        self.cancelResolution = cancelResolution
    }

    /// The Product Real session/pending/resolution state, read/written through the shared
    /// `stateStore` so a mutating call still fires `onWillChange` exactly once (willSet-style timing).
    private var productRealControlState: ProductRealControlState {
        get { stateStore.productRealControlState }
        set { stateStore.productRealControlState = newValue }
    }

    // MARK: - Per-app stop leaf
    //
    // Behavior, ordering, default stop reason, pending-operation semantics, and settle-gate
    // registration are preserved verbatim; the terminal pending-flag clear is owned by the stop
    // callback (`handleProductLiveControlStopped`, also on this coordinator).

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
        // `clearStartRequest` also drops this app's queued start (if it is still waiting for the
        // start lane), so a queued row never starts after being stopped.
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
    // Behavior, ordering, session-ID matching, pending-operation clearing, active-name refresh, and
    // diagnostics/display handling are preserved verbatim; state via `productRealControlState` (so
    // `onWillChange` still fires), reads via the weak `context`, and the shared display cleanup via the
    // `sideEffects` seam callback (`applyLiveControlStoppedDisplay`, whose implementation stays in the
    // view model because advanced-manual stop uses it too). The outer product-vs-advanced router, the
    // global/lifecycle fan-out entry points, and the shared display helper remain in `MixerViewModel`.

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
    // Called by the view model's `refreshApplications` (via the facade) after it refreshes the
    // running-app list (that orchestration stays in the view model). Behavior is preserved verbatim;
    // the running-app list is read via `context`, the per-app stop goes through this coordinator's own
    // leaf, and the resolution cancel goes through the narrow `cancelResolution` closure the facade
    // wired to its resolution slice.

    /// After an app-list refresh, tears down Product Real Control work whose target app is
    /// no longer running: a live-controlled app that exited stops its session, a queued start for a
    /// vanished app is dropped, and a pending helper resolution for a vanished app is cancelled.
    func stopRealControlForExitedTargetApps() {
        let runningApps = context?.apps ?? []
        let exitedActiveAppIDs = productRealControlState.activeVisibleAppIDs.filter { activeAppID in
            !runningApps.contains(where: { $0.id == activeAppID })
        }
        // Tear down only the exited apps' sessions/requests; surviving apps keep running.
        for exitedAppID in exitedActiveAppIDs {
            stopExperimentalControl(for: exitedAppID, reason: .targetAppExited)
        }

        // Drop queued (not yet started) starts whose app exited; surviving apps keep their place.
        if !productRealControlState.queuedStarts.isEmpty {
            productRealControlState.removeQueuedStarts(notIn: Set(runningApps.map(\.id)))
        }

        if let resolvingAppID = productRealControlState.resolvingAppIDs.first,
           !runningApps.contains(where: { $0.id == resolvingAppID }) {
            cancelResolution(.targetExited)
        }
    }

    // MARK: - Hard-teardown state reset
    //
    // Only the Product Real-owned *state* reset block of `tearDownAllProcessTapWork` — the engine hard
    // stop, two-app readiness, helper/probe, resolver invalidation, diagnostics/replay cleanup,
    // advanced-manual reset, and the resolution-task cancel all stay in the view model's teardown at
    // their existing positions. No engine `stopSession` is issued here.

    /// Clears all Product Real session/request/resolution/operation state (queued starts included, via
    /// the start-request/operation clears) and resets the shared active-name display, for the
    /// synchronous hard teardown (sleep / termination). Mutates state via
    /// the `productRealControlState` property so `onWillChange` still fires. The view model's
    /// `tearDownAllProcessTapWork` calls this (via the facade) in place of its previous inline resets.
    func tearDownProductStateForHardStop() {
        productRealControlState.clearAllStartRequests()
        productRealControlState.clearAllResolutions()
        productRealControlState.clearActiveSession()
        // Synchronous hard teardown uses `stopLiveControlNow`, which does not fire the per-session
        // onStopped callbacks that normally clear pending flags, so clear them here directly.
        productRealControlState.clearAllOperations()
        sideEffects?.setActiveLiveControlAppName(nil)
    }

    // MARK: - Shared active-name helper

    /// Sets the shared "active live-control app" name from the current product sessions, unless the
    /// Advanced manual session owns the display. The facade's start body routes its active-name
    /// refreshes here so the algorithm is not duplicated.
    func updateActiveLiveControlAppNameAfterProductChange() {
        if context?.advancedManualLiveControlActive == true {
            return
        }
        sideEffects?.setActiveLiveControlAppName(productRealControlState.activeSessions.first?.displayName)
    }
}
