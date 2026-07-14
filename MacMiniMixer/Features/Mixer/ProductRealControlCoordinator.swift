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
        self.liveSessionManager = liveSessionManager
        self.appAudioTargetResolver = appAudioTargetResolver
        self.startSettleGate = startSettleGate
        self.processTapEligibility = processTapEligibility
        self.sideEffects = sideEffects
        self.context = context
        // Both sub-coordinators share the single state store, the same injected engine/settle/resolver
        // dependencies, and the same weak seam. Neither holds a reference to the other; the three
        // Start↔Stop cross-edges are wired below as narrow closures. Constructed with their default
        // no-op callbacks so nothing captures `self` before initialization completes.
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
