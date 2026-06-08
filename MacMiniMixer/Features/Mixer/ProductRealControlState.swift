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
    let startRequestID: ProductRealControlStartRequestID?
}

struct ProductRealControlStartRequestID: Equatable, Sendable {
    let rawValue: UInt64
}

struct ProductRealControlState: Equatable, Sendable {
    private(set) var activeSession: ProductRealControlActiveSession?
    private(set) var resolutionStateByAppID: [MixerAppItem.ID: AppAudioResolutionState] = [:]
    private(set) var currentStartRequestID: ProductRealControlStartRequestID?
    private var nextStartRequestRawValue: UInt64 = 0

    var activeVisibleAppID: MixerAppItem.ID? {
        activeSession?.visibleAppID
    }

    var activeDisplayName: String? {
        activeSession?.displayName
    }

    var activeStartRequestID: ProductRealControlStartRequestID? {
        activeSession?.startRequestID
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
        startRequestID: ProductRealControlStartRequestID? = nil
    ) {
        activeSession = ProductRealControlActiveSession(
            visibleAppID: visibleAppID,
            displayName: displayName,
            controlledProcessIdentifier: controlledProcessIdentifier ?? -1,
            source: source,
            startRequestID: startRequestID
        )
    }

    mutating func clearActiveSession() {
        activeSession = nil
    }

    mutating func beginStartRequest() -> ProductRealControlStartRequestID {
        nextStartRequestRawValue += 1
        let requestID = ProductRealControlStartRequestID(rawValue: nextStartRequestRawValue)
        currentStartRequestID = requestID
        return requestID
    }

    func isCurrentStartRequest(_ requestID: ProductRealControlStartRequestID) -> Bool {
        currentStartRequestID == requestID
    }

    mutating func clearStartRequest(_ requestID: ProductRealControlStartRequestID) {
        if currentStartRequestID == requestID {
            currentStartRequestID = nil
        }
    }

    mutating func invalidateCurrentStartRequest() {
        currentStartRequestID = nil
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
        activeVisibleAppID == appID && isLiveControlActive
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
