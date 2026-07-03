import Foundation

/// Gates new Product Real session starts behind any in-flight Product Real teardown plus a short
/// settle interval, so a fresh tap/aggregate/IOProc/AudioQueue is not created while coreaudiod is
/// still releasing the previous session's private aggregate/tap and resettling the shared output
/// route. Without this, overlapping a start with a not-yet-settled teardown produces
/// nondeterministic output-queue starvation. Stop semantics are unchanged (still session-id keyed);
/// the gate only observes when teardown work is in flight.
protocol ProductRealStartSettling: Sendable {
    /// Registers an in-flight Product Real stop/cleanup task whose Core Audio teardown affects the
    /// shared output route. Safe to call from any thread.
    func registerStop(_ stop: Task<Void, Never>)
    /// Awaits every currently-registered stop task, then — only if a Product Real teardown has
    /// occurred since the last settled start — suspends for one settle interval. Never blocks the
    /// calling thread (it suspends), and is a no-op when no teardown preceded it.
    func waitForReadyToStart() async
}

/// Default `ProductRealStartSettling`. Thread-safe via a lock; the only async work is awaiting the
/// registered stop tasks and the injected sleeper, so it never holds the lock across a suspension.
final class ProductRealStartSettleGate: ProductRealStartSettling, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingStops: [Task<Void, Never>] = []
    private var hasUnsettledTeardown = false
    private let settleDelay: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async -> Void

    init(
        settleDelay: TimeInterval = AppConstants.productRealStartAfterStopSettleDelay,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.settleDelay = settleDelay
        self.sleeper = sleeper
    }

    func registerStop(_ stop: Task<Void, Never>) {
        lock.lock()
        pendingStops.append(stop)
        hasUnsettledTeardown = true
        lock.unlock()
    }

    func waitForReadyToStart() async {
        // Snapshot and consume the pending stops and the teardown flag together. A teardown that
        // registers during the awaits below re-sets the flag, so the next start settles again.
        lock.lock()
        let stops = pendingStops
        pendingStops.removeAll()
        let shouldSettle = hasUnsettledTeardown
        hasUnsettledTeardown = false
        lock.unlock()

        for stop in stops {
            await stop.value
        }

        if shouldSettle {
            await sleeper(settleDelay)
        }
    }
}

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
