import Foundation

/// Write-side seam a future `ProductRealControlCoordinator` will use instead of mutating
/// `MixerViewModel` directly. `MixerViewModel` conforms today and the Product Real paths call
/// through it, so extracting the coordinator later becomes a mechanical receiver swap
/// (`self` → an injected `sideEffects`). Intentionally narrow: it exposes only the status/display
/// writes the Product Real orchestration performs — never the whole view model.
///
/// The status/name writes are already routed through this seam. The diagnostics/live-diagnostics
/// writes are declared here as the documented Phase-C surface and are wired at their call sites when
/// the async start/stop orchestration actually moves (see docs/HANDOFF ROADMAP), to keep the
/// preparatory step small and away from the delicate async body.
@MainActor
protocol ProductRealControlSideEffects: AnyObject {
    /// Publishes a Product Real / live-control status message (same wording/auto-clear as before).
    func showProductRealStatus(
        _ text: String,
        style: MixerStatusMessage.Style,
        action: MixerStatusMessage.Action?
    )
    /// Sets or clears the shared "active live-control app" display name.
    func setActiveLiveControlAppName(_ name: String?)
    /// Sets or clears the current live-diagnostics stream. (Phase-C write seam.)
    func setProcessTapLiveDiagnostics(_ diagnostics: ProcessTapLiveDiagnostics?)
    /// Advanced-diagnostics surface the Product Real start/stop path writes. (Phase-C write seam.)
    func setLiveControlDiagnosticResult(_ result: ProcessTapTestResult)
    func setLiveControlDiagnosticProgress(_ progress: ProcessTapDiagnosticProgress?)
    func setLiveControlDiagnosticRunning(_ isRunning: Bool)
}

/// Read-side seam: the cross-subsystem state the Product Real start path consults when deciding
/// whether a start is allowed. Narrow by design — no mutation, no orchestration.
@MainActor
protocol ProductRealControlContext: AnyObject {
    /// The current app list, in display order.
    var apps: [MixerAppItem] { get }
    /// Whether the global Real App Control preference is on.
    var isExperimentalRealAppControlEnabled: Bool { get }
    /// Whether the Advanced manual live-control session is active (mutually exclusive with product).
    var advancedManualLiveControlActive: Bool { get }
    /// The Advanced diagnostic app selection, if any.
    var selectedProcessTapAppID: MixerAppItem.ID? { get }
    /// Whether the two-app readiness test is running.
    var isTwoAppReadinessRunning: Bool { get }
    /// Whether an Advanced Process Tap diagnostic is running.
    var isProcessTapTesting: Bool { get }
    /// Whether a helper-process probe or auto-detect is in flight.
    var isHelperBusy: Bool { get }
    /// Whether an app-audio target resolution is in flight.
    var isAppAudioTargetResolving: Bool { get }
}
