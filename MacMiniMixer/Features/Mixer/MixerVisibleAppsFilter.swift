import Foundation

/// Pure, value-based derivation of the visible mixer app list. Extracted from `MixerViewModel`
/// so the "which apps show in the panel" decision stays testable and out of the view model.
/// Preserves the original `apps` ordering (it only filters) and introduces no duplicates.
enum MixerVisibleAppsFilter {
    /// The apps that should be shown in the mixer panel.
    ///
    /// When `showAllApps` is true, every app is returned in its original order. Otherwise an app is
    /// shown when it is likely audio-relevant, is an active live-control target, or is currently
    /// resolving its app-audio target. Ordering follows `apps`; no app appears twice.
    ///
    /// - Parameters:
    ///   - apps: The full app list, in the order it should be displayed.
    ///   - showAllApps: When true, bypass filtering and return `apps` unchanged.
    ///   - activeVisibleAppIDs: Visible app ids with an active/optimistic Product Real session.
    ///   - resolvingAppIDs: Visible app ids currently resolving an app-audio target.
    ///   - selectedProcessTapAppID: The Advanced diagnostic selection, if any.
    ///   - isLiveControlActive: The derived "live control active" flag.
    static func visibleApps(
        apps: [MixerAppItem],
        showAllApps: Bool,
        activeVisibleAppIDs: Set<MixerAppItem.ID>,
        resolvingAppIDs: Set<MixerAppItem.ID>,
        selectedProcessTapAppID: MixerAppItem.ID?,
        isLiveControlActive: Bool
    ) -> [MixerAppItem] {
        if showAllApps {
            return apps
        }

        return apps.filter { app in
            app.isLikelyAudioRelevant ||
                isActiveLiveControlTarget(
                    app.id,
                    activeVisibleAppIDs: activeVisibleAppIDs,
                    selectedProcessTapAppID: selectedProcessTapAppID,
                    isLiveControlActive: isLiveControlActive
                ) ||
                resolvingAppIDs.contains(app.id)
        }
    }

    /// Whether `appID` should stay visible because it is an active live-control target: it owns a
    /// Product Real session, or it is the Advanced diagnostic selection while live control is active.
    static func isActiveLiveControlTarget(
        _ appID: MixerAppItem.ID,
        activeVisibleAppIDs: Set<MixerAppItem.ID>,
        selectedProcessTapAppID: MixerAppItem.ID?,
        isLiveControlActive: Bool
    ) -> Bool {
        activeVisibleAppIDs.contains(appID) ||
            (isLiveControlActive && appID == selectedProcessTapAppID)
    }
}
