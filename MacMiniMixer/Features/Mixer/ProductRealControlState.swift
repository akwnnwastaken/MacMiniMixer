import Foundation

enum ProductRealControlStartSource: Equatable, Sendable {
    case directVisiblePID
    case discoveredHelper
    case cachedHelper

    init(resolutionSource: ResolvedAppAudioTarget.Source?) {
        switch resolutionSource {
        case .cachedHelper:
            self = .cachedHelper
        case .discoveredHelper:
            self = .discoveredHelper
        case .directVisibleApp, nil:
            self = .directVisiblePID
        }
    }
}

struct ProductRealControlActiveSession: Equatable, Sendable {
    let visibleAppID: MixerAppItem.ID
    let displayName: String
    let controlledProcessIdentifier: Int32
    let source: ProductRealControlStartSource
}

struct ProductRealControlState: Equatable, Sendable {
    private(set) var activeSessionsByAppID: [MixerAppItem.ID: ProductRealControlActiveSession] = [:]
    private(set) var resolutionStateByAppID: [MixerAppItem.ID: AppAudioResolutionState] = [:]

    var activeSessions: [ProductRealControlActiveSession] {
        Array(activeSessionsByAppID.values)
    }

    var activeVisibleAppIDs: [MixerAppItem.ID] {
        Array(activeSessionsByAppID.keys)
    }

    /// Transitional single-session convenience: while orchestration still enforces one
    /// active product session at a time, this returns that session. Phase 3 lifts the
    /// single-session limit; new code should prefer `activeSessions` / `activeVisibleAppIDs`.
    var activeSession: ProductRealControlActiveSession? {
        activeSessionsByAppID.values.first
    }

    var activeVisibleAppID: MixerAppItem.ID? {
        activeSession?.visibleAppID
    }

    var activeDisplayName: String? {
        activeSession?.displayName
    }

    var isResolving: Bool {
        !resolutionStateByAppID.isEmpty
    }

    var resolvingAppIDs: [MixerAppItem.ID] {
        Array(resolutionStateByAppID.keys)
    }

    mutating func beginSession(
        visibleAppID: MixerAppItem.ID,
        displayName: String,
        controlledProcessIdentifier: Int32?,
        source: ProductRealControlStartSource
    ) {
        activeSessionsByAppID[visibleAppID] = ProductRealControlActiveSession(
            visibleAppID: visibleAppID,
            displayName: displayName,
            controlledProcessIdentifier: controlledProcessIdentifier ?? -1,
            source: source
        )
    }

    mutating func clearActiveSession() {
        activeSessionsByAppID = [:]
    }

    mutating func clearSession(for appID: MixerAppItem.ID) {
        activeSessionsByAppID.removeValue(forKey: appID)
    }

    mutating func beginResolution(for appID: MixerAppItem.ID) {
        resolutionStateByAppID = [appID: .resolving]
    }

    mutating func clearResolution(for appID: MixerAppItem.ID) {
        resolutionStateByAppID.removeValue(forKey: appID)
    }

    mutating func clearAllResolutions() {
        resolutionStateByAppID = [:]
    }

    func isActive(appID: MixerAppItem.ID, isLiveControlActive: Bool) -> Bool {
        activeSessionsByAppID[appID] != nil && isLiveControlActive
    }

    func isResolving(appID: MixerAppItem.ID) -> Bool {
        resolutionStateByAppID[appID] != nil
    }

    func shouldAcceptResolutionResult(for appID: MixerAppItem.ID) -> Bool {
        isResolving(appID: appID)
    }

    static func gainOption(for app: MixerAppItem) -> ProcessTapReplayGainOption {
        let scalar: Float = app.isMuted
            ? 0
            : Float(app.volume.clamped(to: AppConstants.volumeRange) / AppConstants.volumeRange.upperBound)
        let percent = Int((Double(scalar) * 100).rounded())

        return ProcessTapReplayGainOption(
            scalar: scalar,
            label: "\(percent)%"
        )
    }
}
