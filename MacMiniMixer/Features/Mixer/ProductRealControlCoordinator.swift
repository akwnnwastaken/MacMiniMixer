import Foundation

/// Dependency container for Product Real Control orchestration.
///
/// **Phase C shell (inert):** this type currently only holds the collaborators the Product Real
/// start/stop path uses. The orchestration itself — the async start body, per-app stop, stale-start
/// cleanup, resolution handling, and lifecycle/output-change teardown — **still lives in
/// `MixerViewModel`** during this phase and is *not* invoked through this coordinator yet. Later
/// phases move those methods here one at a time, calling out through the injected
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
}
