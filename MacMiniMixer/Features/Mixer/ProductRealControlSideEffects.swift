import Foundation

/// Write-side seam the `ProductRealControlCoordinator` uses instead of mutating `MixerViewModel`
/// directly: the coordinator holds this weakly and calls through it for status/display writes and
/// the stop-callback hand-off. Intentionally narrow — it never exposes the whole view model.
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
    /// Sets or clears the current live-diagnostics stream.
    func setProcessTapLiveDiagnostics(_ diagnostics: ProcessTapLiveDiagnostics?)
    /// Advanced-diagnostics surface the Product Real start/stop path writes.
    func setLiveControlDiagnosticResult(_ result: ProcessTapTestResult)
    func setLiveControlDiagnosticProgress(_ progress: ProcessTapDiagnosticProgress?)
    func setLiveControlDiagnosticRunning(_ isRunning: Bool)
    /// Runs the shared stop/display cleanup (`MixerViewModel.applyLiveControlStoppedDisplay`) after the
    /// coordinator has cleared the Product Real state for a stopped session. Kept as a seam callback —
    /// not moved — because the same view-model helper also serves the advanced-manual stop path.
    func applyLiveControlStoppedDisplay(
        result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?
    )
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
    /// Whether the two-app readiness test is running.
    var isTwoAppReadinessRunning: Bool { get }
    /// Whether an Advanced Process Tap diagnostic is running.
    var isProcessTapTesting: Bool { get }
    /// Whether a helper-process probe or auto-detect is in flight.
    var isHelperBusy: Bool { get }
    /// Whether an app-audio target resolution is in flight.
    var isAppAudioTargetResolving: Bool { get }
    /// The derived "live control active" flag (Advanced-manual active OR a confirmed product
    /// session).
    var isProcessTapLiveControlActive: Bool { get }
    /// The current live-diagnostics stream, read by the Stop All path to carry the last diagnostics
    /// into its no-active-session cleanup (matching the previous view-model behavior).
    var processTapLiveDiagnostics: ProcessTapLiveDiagnostics? { get }
}
