import Foundation

/// Dependency container for Product Real Control orchestration.
///
/// **Phase C (in progress):** this type holds the collaborators the Product Real start/stop path
/// uses, plus the first migrated leaf — stale-start cleanup. The rest of the orchestration — the
/// async start body, per-app stop, resolution handling, and lifecycle/output-change teardown —
/// **still lives in `MixerViewModel`** during this phase and is not invoked through this coordinator
/// yet. Later phases move those methods here one at a time, calling out through the injected
/// `ProductRealControlSideEffects` / `ProductRealControlContext` seam instead of the view model
/// directly.
///
/// The seam references are held **weakly**: the view model owns this coordinator, so a strong back
/// reference would form a retain cycle.
///
/// As of this phase the coordinator **owns `ProductRealControlState`** (the Product Real
/// session/pending/resolution state). The orchestration that mutates it still lives in
/// `MixerViewModel`, which reaches the state through the `productRealControlState` get/set forwarding
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
    /// Called by the async start body (still in `MixerViewModel`) after it rejects a superseded
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
    // Moved from `MixerViewModel` (Phase C). The async Product Real start body still lives in the
    // view model; when a target is ready these methods call back through
    // `ProductRealControlSideEffects.startResolvedProductReal` to kick it off. State mutations go
    // through the `productRealControlState` property so its `onWillChange` still fires.

    /// Starts Product Real for `app`, resolving an audio-helper target first when the visible process
    /// is not directly eligible. Preserves the previous eligibility/permission/helper checks and
    /// status messages verbatim.
    func startResolvedExperimentalControl(for app: MixerAppItem, allowsCachedLookup: Bool = true) {
        let request = app.appAudioTargetRequest
        let visibleEligibility = processTapEligibility(app.processIdentifier)

        if visibleEligibility.isEligible {
            sideEffects?.startResolvedProductReal(
                app: app,
                target: ProcessTapTarget(
                    appID: app.id,
                    appName: app.name,
                    processIdentifier: app.processIdentifier
                ),
                resolutionSource: nil
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

            sideEffects?.startResolvedProductReal(
                app: app,
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
}
