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
/// reference would form a retain cycle. `ProductRealControlState` is deliberately *not* held here
/// yet — it remains the view model's `@Published` value-type state this phase and moves in only when
/// the orchestration that mutates it moves.
@MainActor
final class ProductRealControlCoordinator {
    private let liveSessionManager: ProcessTapLiveControlling & ProcessTapLiveSessionManaging
    private let appAudioTargetResolver: AppAudioTargetResolving
    private let startSettleGate: ProductRealStartSettling
    private let processTapEligibility: @Sendable (Int32?) -> ProcessTapProcessEligibility
    private weak var sideEffects: ProductRealControlSideEffects?
    private weak var context: ProductRealControlContext?

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
}
