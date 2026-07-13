import Foundation

/// Single owner of the Product Real session/pending/resolution state and its change-notification
/// forwarding. Extracted from `ProductRealControlCoordinator` so the state has one source of truth
/// that the coordinator (and, later, the product start/stop sub-coordinators) share by reference.
///
/// Reads return the current value; a write fires `onWillChange` *before* applying, so a mutating
/// call routed through `productRealControlState` notifies exactly once — matching the old
/// `@Published` `willSet` timing that `MixerViewModel` bridges to `objectWillChange`.
@MainActor
final class ProductRealControlStateStore {
    private var state = ProductRealControlState()
    private var onWillChange: (() -> Void)?

    /// The Product Real session/pending/resolution state. A write fires `onWillChange` before it
    /// applies (willSet-style timing); a read never notifies.
    var productRealControlState: ProductRealControlState {
        get { state }
        set {
            onWillChange?()
            state = newValue
        }
    }

    /// Registers a handler fired immediately before every `productRealControlState` mutation, so the
    /// owning view model can forward it to `objectWillChange` — preserving the notification the
    /// state's previous `@Published` wrapper provided.
    func setOnWillChange(_ onWillChange: @escaping () -> Void) {
        self.onWillChange = onWillChange
    }
}
