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
    private weak var sideEffects: ProductRealControlSideEffects?
    private weak var context: ProductRealControlContext?
    private var appAudioResolutionTask: Task<Void, Never>?

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
        context: ProductRealControlContext
    ) {
        self.stateStore = stateStore
        self.liveSessionManager = liveSessionManager
        self.appAudioTargetResolver = appAudioTargetResolver
        self.startSettleGate = startSettleGate
        self.processTapEligibility = processTapEligibility
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
}
