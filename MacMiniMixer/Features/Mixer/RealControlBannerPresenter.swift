import Foundation

/// Pure, UI-framework-free description of the Real Control banner. Built by
/// `RealControlBannerPresenter` and consumed by the SwiftUI banner so all banner string/label
/// decisions stay testable and out of the view. Never carries helper PID/process identity.
struct RealControlBannerPresentation: Equatable {
    enum Mode: Equatable {
        case product
        case advancedManual
    }

    let mode: Mode
    let appNames: [String]
    let confirmedCount: Int
    let summaryText: String
    let stopButtonTitle: String
    let accessibilityLabel: String
    let stopAccessibilityLabel: String
}

/// Single source of truth for the Real Control banner's text, stop-button title, and accessibility
/// wording. Pure (no stored state, no helper identity, no CoreAudio): Product sessions are
/// summarised from the confirmed visible app names (already in stable `apps` order); Advanced Manual
/// Live keeps its existing single-app wording. `nil` ⟺ the banner should be hidden, which is exactly
/// `!isLiveControlActive`.
enum RealControlBannerPresenter {
    /// Builds the banner presentation, or `nil` when the banner should be hidden.
    ///
    /// - Parameters:
    ///   - confirmedProductRealControlAppNames: Visible app display names for every confirmed
    ///     Product Real session, in stable `apps` order. Never carries helper PID/process identity.
    ///   - isAdvancedManualLiveControlActive: Whether the Advanced manual live-control session is
    ///     running.
    ///   - activeLiveControlAppName: The single Advanced-manual app name, if any.
    ///   - isLiveControlActive: The derived "live control active" flag; `nil` is returned exactly
    ///     when this is `false`.
    static func make(
        confirmedProductRealControlAppNames: [String],
        isAdvancedManualLiveControlActive: Bool,
        activeLiveControlAppName: String?,
        isLiveControlActive: Bool
    ) -> RealControlBannerPresentation? {
        let productNames = confirmedProductRealControlAppNames
        if !productNames.isEmpty {
            let count = productNames.count
            let isMultiple = count >= 2
            let joined = productNames.joined(separator: ", ")
            // Visible summary stays one line: for 3+ apps show the first two names plus a
            // "+N more" count so the narrow panel does not truncate mid-name. The accessibility
            // label below keeps the full list, so nothing is lost for assistive tech.
            let summaryText: String
            if count > 2 {
                let firstTwo = productNames.prefix(2).joined(separator: ", ")
                summaryText = "Real control: \(firstTwo) +\(count - 2) more"
            } else {
                summaryText = "Real control: \(joined)"
            }
            return RealControlBannerPresentation(
                mode: .product,
                appNames: productNames,
                confirmedCount: count,
                summaryText: summaryText,
                stopButtonTitle: isMultiple ? "Stop All" : "Stop",
                accessibilityLabel: isMultiple
                    ? "Real control active for \(count) apps: \(joined)"
                    : "Real control active for \(joined)",
                stopAccessibilityLabel: isMultiple
                    ? "Stop real control for all apps"
                    : "Stop real control for \(joined)"
            )
        }

        if isAdvancedManualLiveControlActive {
            let name = activeLiveControlAppName ?? "Active"
            return RealControlBannerPresentation(
                mode: .advancedManual,
                appNames: activeLiveControlAppName.map { [$0] } ?? [],
                confirmedCount: 0,
                summaryText: "Real control: \(name)",
                stopButtonTitle: "Stop",
                accessibilityLabel: "Real control active for \(name)",
                stopAccessibilityLabel: "Stop real control for \(name)"
            )
        }

        // Transient only: a confirmed session whose visible app momentarily left `apps` (before
        // teardown). Preserve the legacy generic banner rather than flicker it away.
        if isLiveControlActive {
            return RealControlBannerPresentation(
                mode: .product,
                appNames: [],
                confirmedCount: 0,
                summaryText: "Real control: Active",
                stopButtonTitle: "Stop",
                accessibilityLabel: "Real control active",
                stopAccessibilityLabel: "Stop real control"
            )
        }

        return nil
    }
}
