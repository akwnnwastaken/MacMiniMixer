import Foundation

/// Thin facade for Product Real Control. `MixerViewModel` knows only this type, and its public API is
/// unchanged across the internal split. The facade owns exactly three things — the single
/// `ProductRealControlStateStore`, a `ProductRealStartCoordinator` (start + resolution), and a
/// `ProductRealStopCoordinator` (stop path) — and does three jobs:
///
/// - **constructs** both sub-coordinators, threading the injected engine / settle-gate / resolver
///   dependencies and the weak seam straight through (the facade stores none of them itself), and
///   sharing the one state store by reference;
/// - **wires** the three Start↔Stop cross-edges as narrow `[weak self]` closures — stop→start
///   resolution cancellation, start→stop engine-stopped handling, and start→stop active-name refresh —
///   so neither sub-coordinator references the other (no sibling ownership, no retain cycle);
/// - **forwards** `productRealControlState` / `setOnWillChange` to the store and the public start/stop
///   methods to the sub-coordinators.
///
/// `MixerViewModel` still owns the cross-subsystem / UI orchestration: the row
/// `toggleExperimentalControl` entry point, the product-vs-advanced-manual `stopProcessTapLiveControl`
/// router, the shared display cleanup helper (`applyLiveControlStoppedDisplay`, reached through the
/// seam and also used by advanced-manual stop), and the lifecycle / output-device-change / global
/// teardown fan-out.
///
/// The seam references (`ProductRealControlSideEffects` / `ProductRealControlContext`) are held
/// **weakly** by the sub-coordinators — the view model owns this facade, so a strong back reference
/// would form a retain cycle.
///
/// State: the `ProductRealControlStateStore` owns `ProductRealControlState`. The view model reaches it
/// through the `productRealControlState` get/set forwarding property below; the state's previous
/// `@Published` change notification is preserved via `onWillChange` (the view model forwards it to
/// `objectWillChange`).
@MainActor
final class ProductRealControlCoordinator {
    private let stateStore = ProductRealControlStateStore()
    private let startCoordinator: ProductRealStartCoordinator
    private let stopCoordinator: ProductRealStopCoordinator

    init(
        liveSessionManager: ProcessTapLiveControlling & ProcessTapLiveSessionManaging,
        appAudioTargetResolver: AppAudioTargetResolving,
        startSettleGate: ProductRealStartSettling,
        processTapEligibility: @escaping @Sendable (Int32?) -> ProcessTapProcessEligibility,
        sideEffects: ProductRealControlSideEffects,
        context: ProductRealControlContext
    ) {
        // The facade stores none of these dependencies directly — they are threaded straight into the
        // two sub-coordinators, which share the single state store and the same weak seam. Neither
        // sub-coordinator holds a reference to the other; the three Start↔Stop cross-edges are wired
        // below as narrow closures. Constructed with their default no-op callbacks so nothing captures
        // `self` before initialization completes.
        self.startCoordinator = ProductRealStartCoordinator(
            stateStore: stateStore,
            liveSessionManager: liveSessionManager,
            appAudioTargetResolver: appAudioTargetResolver,
            startSettleGate: startSettleGate,
            processTapEligibility: processTapEligibility,
            sideEffects: sideEffects,
            context: context
        )
        self.stopCoordinator = ProductRealStopCoordinator(
            stateStore: stateStore,
            liveSessionManager: liveSessionManager,
            startSettleGate: startSettleGate,
            appAudioTargetResolver: appAudioTargetResolver,
            sideEffects: sideEffects,
            context: context
        )
        // All stored properties are now initialized, so `self` is usable: wire the three Start↔Stop
        // cross-edges as narrow closures routed through the facade. `[weak self]` keeps the
        // facade → sub-coordinator → closure → facade chain cycle-free (no sibling ownership).
        stopCoordinator.setCancelResolution { [weak self] reason in
            self?.startCoordinator.cancelAppAudioTargetResolution(reason: reason)
        }
        startCoordinator.setOnEngineStopped { [weak self] sessionID, result, diagnostics in
            self?.stopCoordinator.handleProductLiveControlStopped(
                sessionID: sessionID,
                result: result,
                diagnostics: diagnostics
            )
        }
        startCoordinator.setRefreshActiveName { [weak self] in
            self?.stopCoordinator.updateActiveLiveControlAppNameAfterProductChange()
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

    // MARK: - Start path (forwarded to ProductRealStartCoordinator)
    //
    // Thin facade forwards to `startCoordinator`, which owns the Product Real start + resolution logic.
    // `MixerViewModel` calls only these facade methods. The async `startExperimentalControl` overload,
    // the resolution-result handler, and stale-start cleanup are internal to the start coordinator and
    // are not exposed here.

    /// Starts Product Real Control for a row (sync preflight). Forwards to the start coordinator.
    func startExperimentalControl(for appID: MixerAppItem.ID) {
        startCoordinator.startExperimentalControl(for: appID)
    }

    /// Starts Product Real for `app`, resolving an audio-helper target first when the visible process
    /// is not directly eligible. Forwards to the start coordinator.
    func startResolvedExperimentalControl(for app: MixerAppItem, allowsCachedLookup: Bool = true) {
        startCoordinator.startResolvedExperimentalControl(for: app, allowsCachedLookup: allowsCachedLookup)
    }

    /// Cancels an in-flight app-audio resolution and clears resolving state. Forwards to the start coordinator.
    func cancelAppAudioTargetResolution(reason: ProcessTapCandidateProbeStopReason) {
        startCoordinator.cancelAppAudioTargetResolution(reason: reason)
    }

    /// Cancels only the resolution task (sleep/termination teardown path). Forwards to the start coordinator.
    func cancelResolutionTask() {
        startCoordinator.cancelResolutionTask()
    }

    /// Whether a new product real-control session may start for `appID` (nil when allowed). Forwards to
    /// the start coordinator.
    func productSessionStartBlockReason(for appID: MixerAppItem.ID) -> String? {
        startCoordinator.productSessionStartBlockReason(for: appID)
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
