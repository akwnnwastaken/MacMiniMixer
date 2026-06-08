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

/// Monotonic identifier for one Product live-start attempt. Used to reject stale async
/// start completions/callbacks per app, so a late result from a superseded or cancelled
/// start cannot reactivate or disturb current state. Uniqueness is global (monotonic raw
/// value); validity is tracked per visible app id (see `pendingStartRequestByAppID`).
struct ProductRealControlStartRequestID: Equatable, Sendable {
    let rawValue: UInt64
}

struct ProductRealControlActiveSession: Equatable, Sendable {
    let visibleAppID: MixerAppItem.ID
    let displayName: String
    let controlledProcessIdentifier: Int32
    let source: ProductRealControlStartSource
    /// The live engine session id for this app, once `startSession` has returned it. Nil
    /// during the brief optimistic window before the async start completes.
    var liveSessionID: ProcessTapLiveSessionID?
    /// The start request that produced this session, so a later callback can confirm it is
    /// still the one that owns this app's session.
    var startRequestID: ProductRealControlStartRequestID?
}

struct ProductRealControlState: Equatable, Sendable {
    private(set) var activeSessionsByAppID: [MixerAppItem.ID: ProductRealControlActiveSession] = [:]
    private(set) var resolutionStateByAppID: [MixerAppItem.ID: AppAudioResolutionState] = [:]
    /// The currently pending start request for each visible app. A new start for an app
    /// supersedes any earlier pending request for that same app, while leaving other apps'
    /// requests untouched.
    private(set) var pendingStartRequestByAppID: [MixerAppItem.ID: ProductRealControlStartRequestID] = [:]
    private var nextStartRequestRawValue: UInt64 = 0

    var activeSessions: [ProductRealControlActiveSession] {
        Array(activeSessionsByAppID.values)
    }

    var activeVisibleAppIDs: [MixerAppItem.ID] {
        Array(activeSessionsByAppID.keys)
    }

    /// True once at least one session has a confirmed engine session id (i.e. live control
    /// actually started), as opposed to the brief optimistic window before `startSession`
    /// returns. Used to derive the "live control active" flag without counting the optimistic
    /// pre-start window.
    var hasConfirmedLiveSession: Bool {
        activeSessionsByAppID.values.contains { $0.liveSessionID != nil }
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
        source: ProductRealControlStartSource,
        liveSessionID: ProcessTapLiveSessionID? = nil,
        startRequestID: ProductRealControlStartRequestID? = nil
    ) {
        activeSessionsByAppID[visibleAppID] = ProductRealControlActiveSession(
            visibleAppID: visibleAppID,
            displayName: displayName,
            controlledProcessIdentifier: controlledProcessIdentifier ?? -1,
            source: source,
            liveSessionID: liveSessionID,
            startRequestID: startRequestID
        )
    }

    mutating func clearActiveSession() {
        activeSessionsByAppID = [:]
    }

    mutating func clearSession(for appID: MixerAppItem.ID) {
        activeSessionsByAppID.removeValue(forKey: appID)
    }

    /// Begins (and supersedes) the pending start request for `appID`, returning a fresh
    /// per-app token. A later start for the same app invalidates this one; other apps are
    /// unaffected.
    mutating func beginStartRequest(for appID: MixerAppItem.ID) -> ProductRealControlStartRequestID {
        nextStartRequestRawValue += 1
        let requestID = ProductRealControlStartRequestID(rawValue: nextStartRequestRawValue)
        pendingStartRequestByAppID[appID] = requestID
        return requestID
    }

    /// Whether `requestID` is still the current pending start request for `appID`.
    func isCurrentStartRequest(_ requestID: ProductRealControlStartRequestID, for appID: MixerAppItem.ID) -> Bool {
        pendingStartRequestByAppID[appID] == requestID
    }

    /// Clears the pending start request for a single app only.
    mutating func clearStartRequest(for appID: MixerAppItem.ID) {
        pendingStartRequestByAppID.removeValue(forKey: appID)
    }

    /// Clears every pending start request (e.g. global toggle off, output change, termination).
    mutating func clearAllStartRequests() {
        pendingStartRequestByAppID = [:]
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
