import AppKit
import Foundation

/// Owns the Product Real **start + resolution** path — extracted from `ProductRealControlCoordinator`.
/// Resolution and start live together because they are bidirectionally coupled (a resolved target
/// launches the start body; a cached-helper start failure re-enters resolution) and share per-app
/// start-request tokens plus the single `appAudioResolutionTask`.
///
/// It shares the one `ProductRealControlStateStore` **by reference** (so `onWillChange` fires exactly
/// once per write) and holds the same injected engine / settle-gate / resolver dependencies the facade
/// previously stored. The seam references are held **weakly** (the view model transitively owns this
/// coordinator, so a strong back reference would form a retain cycle).
///
/// It has **no** reference to the stop side. The two start→stop edges — the engine `onStopped`
/// callback and the shared active-name refresh — are narrow closures the facade wires
/// (`onEngineStopped` / `refreshActiveName`), so no Start↔Stop ownership cycle exists.
@MainActor
final class ProductRealStartCoordinator {
    private let stateStore: ProductRealControlStateStore
    private let liveSessionManager: ProcessTapLiveControlling & ProcessTapLiveSessionManaging
    private let appAudioTargetResolver: AppAudioTargetResolving
    private let startSettleGate: ProductRealStartSettling
    private let processTapEligibility: @Sendable (Int32?) -> ProcessTapProcessEligibility
    /// Optional concurrent Product Real session cap for the start preflight; `nil` = unlimited (the
    /// product default, `AppConstants.maxConcurrentLiveSessions`). Injectable so tests can prove the
    /// cap mechanism and its message with an explicit value.
    private let maxConcurrentSessions: Int?
    private weak var sideEffects: ProductRealControlSideEffects?
    private weak var context: ProductRealControlContext?
    private var appAudioResolutionTask: Task<Void, Never>?

    /// Diagnostics-only, per-live-session bookkeeping for starvation-escalation attribution logging.
    /// **Not** a source of truth: it never drives audio, UI, `ProductRealControlState`, or any published
    /// value — it only decides whether a session's `outputStarvationCount` has risen enough to warrant
    /// one debug log so an intermittent Starv spike can be attributed to a specific session/app. See
    /// `ProductRealStarvationAttributionLog`.
    private var starvationAttribution = ProductRealStarvationAttributionLog()

    /// The app whose Product Real session owns the single shared Advanced live-diagnostics surface
    /// (`setProcessTapLiveDiagnostics` / `setLiveControlDiagnosticProgress`), so concurrent sessions
    /// do not interleave their values there. The newest start takes it; when the focused app no
    /// longer has a session, the next accepted callback from a surviving session adopts it (see
    /// `shouldPublishLiveDiagnostics(for:)`), so the stop side needs no bookkeeping. Display-only:
    /// it never affects audio, `ProductRealControlState`, or attribution logging.
    private var liveDiagnosticsFocusAppID: MixerAppItem.ID?

    /// Routes the engine `onStopped` callback to the stop side. No-op default so construction never
    /// captures the sibling before the facade wires it (post-init).
    private var onEngineStopped: @MainActor (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void = { _, _, _ in }
    /// Refreshes the shared active-name display. Wired by the facade to the stop coordinator's helper so
    /// the algorithm is not duplicated here. No-op default until wired.
    private var refreshActiveName: @MainActor () -> Void = {}

    init(
        stateStore: ProductRealControlStateStore,
        liveSessionManager: ProcessTapLiveControlling & ProcessTapLiveSessionManaging,
        appAudioTargetResolver: AppAudioTargetResolving,
        startSettleGate: ProductRealStartSettling,
        processTapEligibility: @escaping @Sendable (Int32?) -> ProcessTapProcessEligibility,
        sideEffects: ProductRealControlSideEffects,
        context: ProductRealControlContext,
        maxConcurrentSessions: Int? = AppConstants.maxConcurrentLiveSessions
    ) {
        self.stateStore = stateStore
        self.liveSessionManager = liveSessionManager
        self.appAudioTargetResolver = appAudioTargetResolver
        self.startSettleGate = startSettleGate
        self.processTapEligibility = processTapEligibility
        self.maxConcurrentSessions = maxConcurrentSessions
        self.sideEffects = sideEffects
        self.context = context
    }

    deinit {
        // Cancel the in-flight resolution task on dealloc (the facade that owns this coordinator is
        // being torn down). Preserves the cancellation the facade's own `deinit` performed.
        appAudioResolutionTask?.cancel()
    }

    /// Wires the engine-stop routing to the stop side (facade-installed, post-init).
    func setOnEngineStopped(_ onEngineStopped: @escaping @MainActor (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void) {
        self.onEngineStopped = onEngineStopped
    }

    /// Wires the shared active-name refresh to the stop side (facade-installed, post-init).
    func setRefreshActiveName(_ refreshActiveName: @escaping @MainActor () -> Void) {
        self.refreshActiveName = refreshActiveName
    }

    /// The Product Real session/pending/resolution state, read/written through the shared `stateStore`
    /// so a mutating call still fires `onWillChange` exactly once (willSet-style timing).
    private var productRealControlState: ProductRealControlState {
        get { stateStore.productRealControlState }
        set { stateStore.productRealControlState = newValue }
    }

    /// Tears down a stale/orphaned Product Real start's just-created session by its own session id.
    /// Called by the async start body after it rejects a superseded start. Stateless: reads only the
    /// start result and the held live-session manager, and uses the same `.userStopped` stop reason as
    /// before. No-op when the start did not actually start a live session, or when it started without a
    /// session-specific cleanup handle.
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
    // When a target is ready these methods call the async start body (`startExperimentalControl`, on
    // this coordinator). State mutations go through the `productRealControlState` property so its
    // `onWillChange` still fires.

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
    /// when blocked, or nil when allowed. Any number of product sessions may run concurrently by
    /// default (`maxConcurrentSessions == nil`); when a cap is configured, a new app is blocked once
    /// it is reached and the message names that configured count. Advanced manual control and
    /// diagnostics remain mutually exclusive with product control. Callers handle "already active
    /// for this app" separately.
    func productSessionStartBlockReason(for appID: MixerAppItem.ID) -> String? {
        if context?.isProcessTapTesting == true {
            return "Stop active live control first"
        }

        if context?.advancedManualLiveControlActive == true {
            return "Stop the active live control first"
        }

        if let cap = maxConcurrentSessions,
           productRealControlState.wouldExceedConcurrentSessionCap(for: appID, cap: cap) {
            return "Real app control supports \(cap) apps at a time"
        }

        return nil
    }

    // MARK: - Async start body
    //
    // Conditions, ordering, strings, stop reason, timeout policy, settle-gate ordering,
    // pending-operation and diagnostics behavior are all preserved verbatim; the engine `onStopped`
    // callback is routed to the stop side via the injected `onEngineStopped` closure and active-name
    // refreshes via `refreshActiveName`.

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
        // The newest start owns the shared live-diagnostics surface, matching its "Starting…" line.
        liveDiagnosticsFocusAppID = app.id
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
            ) { sessionID, diagnostics in
                Task { @MainActor in
                    guard self.productRealControlState.shouldAcceptCallback(for: app.id, requestID: startRequestID) else {
                        return
                    }
                    // Only the focused session publishes to the shared Advanced surface, and only
                    // while that surface is on screen. Checked after the accept guard, so a
                    // stale/rejected callback can never take the focus.
                    if self.shouldPublishLiveDiagnostics(for: app.id) {
                        self.sideEffects?.setProcessTapLiveDiagnostics(diagnostics)
                        self.sideEffects?.setLiveControlDiagnosticProgress(diagnostics.progress)
                    }
                    // Diagnostics-only attribution: emitted *after* the accept guard, so a
                    // stale/rejected callback returns above and never logs or moves the per-session
                    // baseline. It runs for every accepted callback, whether or not this session
                    // published above (non-focused session, or the display is hidden).
                    self.logDiagnosticsAttributionIfEscalated(
                        sessionID: sessionID,
                        appID: app.id,
                        appName: app.name,
                        diagnostics: diagnostics
                    )
                }
            } onStopped: { sessionID, result, diagnostics in
                Task { @MainActor in
                    // Drop this session's starvation-attribution baseline as it terminates so the map
                    // stays bounded to live sessions. Diagnostics-only; the stop routing below and its
                    // ordering are unchanged.
                    self.starvationAttribution.forget(sessionID: sessionID)
                    self.onEngineStopped(sessionID, result, diagnostics)
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
                        refreshActiveName()
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
                    refreshActiveName()
                    sideEffects?.setProcessTapLiveDiagnostics(nil)
                    sideEffects?.setLiveControlDiagnosticProgress(nil)

                    // Only the mutually exclusive Advanced manual session suppresses this helper-probe
                    // retry; other Product sessions run concurrently (a normal start resolves alongside them).
                    if resolutionSource == .cachedHelper,
                       context?.isExperimentalRealAppControlEnabled == true,
                       context?.isTwoAppReadinessRunning != true,
                       context?.advancedManualLiveControlActive != true,
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

    /// Diagnostics-only: emit at most one *bounded* debug log per escalation for a live Product Real
    /// session, tagging it with the session id, app id/name, and the Starv/Drops/Fail/enqueued/warmup
    /// context already carried in the diagnostics. Emission is rate-shaped by
    /// `ProductRealStarvationAttributionLog` (first nonzero Starv, then Starv 100-count bucket
    /// crossings; any Drops/Fail increase immediately), so a spike to ~1300 produces a handful of
    /// lines rather than hundreds. This changes nothing the app does or shows; it only makes an
    /// intermittent spike attributable to a specific session. Only reached for callbacks already
    /// accepted by `shouldAcceptCallback`, so a stale/rejected callback neither logs nor moves the
    /// per-session attribution state.
    private func logDiagnosticsAttributionIfEscalated(
        sessionID: ProcessTapLiveSessionID,
        appID: MixerAppItem.ID,
        appName: String,
        diagnostics: ProcessTapLiveDiagnostics
    ) {
        guard let decision = starvationAttribution.decision(
            sessionID: sessionID,
            outputStarvationCount: diagnostics.outputStarvationCount,
            droppedBufferCount: diagnostics.droppedBufferCount,
            totalFailureCount: diagnostics.totalFailureCount
        ) else {
            return
        }

        AppLogger.processTap.debug("Product Real diagnostics escalated reason=\(decision.reasonLabel, privacy: .public) sessionID=\(sessionID.rawValue.uuidString, privacy: .public) appID=\(appID, privacy: .public) app=\(appName, privacy: .public) starv=\(diagnostics.outputStarvationCount, privacy: .public) drops=\(diagnostics.droppedBufferCount, privacy: .public) fail=\(diagnostics.totalFailureCount, privacy: .public) enqueued=\(diagnostics.enqueuedBufferCount, privacy: .public) warmingUp=\(diagnostics.isWarmingUpOutput, privacy: .public)")
    }

    /// Whether an *accepted* live-diagnostics callback for `appID` should be published to the shared
    /// Advanced surface. Updates the focus first: `appID` adopts it when no app holds it or the
    /// focused app no longer has a session (stopped, failed, superseded) — so focus falls back to a
    /// surviving session without stop-side bookkeeping. Then only the focused app publishes, and
    /// only while the Advanced display is on screen (focus still moves while it is hidden).
    private func shouldPublishLiveDiagnostics(for appID: MixerAppItem.ID) -> Bool {
        if liveDiagnosticsFocusAppID != appID,
           liveDiagnosticsFocusAppID.map({ productRealControlState.activeSessionsByAppID[$0] == nil }) ?? true {
            liveDiagnosticsFocusAppID = appID
        }

        guard liveDiagnosticsFocusAppID == appID else {
            return false
        }

        return context?.isLiveDiagnosticsDisplayVisible ?? true
    }

    /// Test-only: whether a live session currently has starvation-attribution state, i.e. at least
    /// one of its diagnostics callbacks was accepted and reached the attribution logger.
    func hasStarvationAttributionBaseline(for sessionID: ProcessTapLiveSessionID) -> Bool {
        starvationAttribution.hasBaseline(for: sessionID)
    }
}

/// Diagnostics-only, per-session bookkeeping that *rate-shapes* Product Real attribution logging so a
/// starvation spike cannot flood the local log. It is **not** a source of truth for anything the app
/// does: it never drives audio, UI, or `ProductRealControlState`, and it is never published to the
/// view model; it exists solely so an intermittent spike can be attributed to a specific live session
/// without emitting hundreds of records. Kept internal (not `private`) only so it can be unit-tested
/// directly. Deterministic — no clocks, no sleeps.
struct ProductRealStarvationAttributionLog {
    /// Why an attribution log should be emitted (any combination). Returned so the log line can name
    /// the trigger; carries no session state.
    struct Decision: Equatable {
        var starvationBucketCrossed: Bool
        var dropsIncreased: Bool
        var failIncreased: Bool

        /// Compact, human-readable trigger label for the log line (e.g. `starv`, `drops`, `starv+fail`).
        var reasonLabel: String {
            var parts: [String] = []
            if starvationBucketCrossed { parts.append("starv") }
            if dropsIncreased { parts.append("drops") }
            if failIncreased { parts.append("fail") }
            return parts.joined(separator: "+")
        }
    }

    private struct SessionState: Equatable {
        /// Highest Starv seen; never moves backward, so a lower/out-of-order value cannot re-trigger.
        var starvationHighWater = 0
        /// Bucket (`Starv / 100`) of the last Starv value that logged; `nil` until the first nonzero
        /// Starv logs. Distinguishes "first nonzero" (always logs) from "already logged bucket 0".
        var loggedStarvationBucket: Int?
        var droppedBufferHighWater = 0
        var totalFailureHighWater = 0
    }

    private var stateBySession: [ProcessTapLiveSessionID: SessionState] = [:]

    /// Returns a `Decision` describing why a log should be emitted, or `nil` when this snapshot should
    /// not log. Emission policy (per session, diagnostics-only):
    ///   - **Starv** logs on the first nonzero value, then only when it crosses into a new 100-count
    ///     bucket (`1`→log, …, `99`→no, `100`→log, `199`→no, `200`→log, …); a first value of `1300`
    ///     logs once (not thirteen times), and `1301` does not re-log while `1400` does;
    ///   - **Drops** logs immediately on any increase, regardless of the current Starv bucket;
    ///   - **Fail** logs immediately on any increase, regardless of the current Starv bucket;
    ///   - identical or lower values never log and never move the stored high-water marks backward;
    ///   - each session id is tracked independently.
    /// Call this only for callbacks already accepted by `shouldAcceptCallback`, so a stale/rejected
    /// callback never reaches here and thus never logs or mutates the tracker.
    mutating func decision(
        sessionID: ProcessTapLiveSessionID,
        outputStarvationCount: Int,
        droppedBufferCount: Int,
        totalFailureCount: Int
    ) -> Decision? {
        var state = stateBySession[sessionID] ?? SessionState()

        var starvationBucketCrossed = false
        if outputStarvationCount > state.starvationHighWater {
            if let loggedBucket = state.loggedStarvationBucket {
                let newBucket = outputStarvationCount / 100
                if newBucket > loggedBucket {
                    starvationBucketCrossed = true
                    state.loggedStarvationBucket = newBucket
                }
            } else if outputStarvationCount > 0 {
                // First nonzero starvation for this session always logs once, whatever its value.
                starvationBucketCrossed = true
                state.loggedStarvationBucket = outputStarvationCount / 100
            }
            state.starvationHighWater = outputStarvationCount
        }

        var dropsIncreased = false
        if droppedBufferCount > state.droppedBufferHighWater {
            dropsIncreased = true
            state.droppedBufferHighWater = droppedBufferCount
        }

        var failIncreased = false
        if totalFailureCount > state.totalFailureHighWater {
            failIncreased = true
            state.totalFailureHighWater = totalFailureCount
        }

        stateBySession[sessionID] = state

        guard starvationBucketCrossed || dropsIncreased || failIncreased else {
            return nil
        }

        return Decision(
            starvationBucketCrossed: starvationBucketCrossed,
            dropsIncreased: dropsIncreased,
            failIncreased: failIncreased
        )
    }

    /// Drops a session's attribution state as it stops/cleans up, so the map stays bounded to live
    /// sessions and a later session (always a fresh id) starts clean. Safe for an unknown id.
    mutating func forget(sessionID: ProcessTapLiveSessionID) {
        stateBySession.removeValue(forKey: sessionID)
    }

    /// Test-only: whether a session currently has recorded attribution state.
    func hasBaseline(for sessionID: ProcessTapLiveSessionID) -> Bool {
        stateBySession[sessionID] != nil
    }
}
