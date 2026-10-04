import XCTest
@testable import MacMiniMixer

final class ProductRealControlStateTests: XCTestCase {
    func testInitialStateIsInactiveAndNotResolving() {
        let state = ProductRealControlState()

        XCTAssertNil(state.activeSession)
        XCTAssertNil(state.activeVisibleAppID)
        XCTAssertNil(state.activeDisplayName)
        XCTAssertFalse(state.isResolving)
        XCTAssertTrue(state.resolutionStateByAppID.isEmpty)
    }

    func testBeginningDirectSessionRecordsVisibleIdentityControlledPIDAndSource() {
        var state = ProductRealControlState()

        state.beginSession(
            visibleAppID: "spotify",
            displayName: "Spotify",
            controlledProcessIdentifier: 101,
            source: .directVisiblePID
        )

        XCTAssertEqual(state.activeVisibleAppID, "spotify")
        XCTAssertEqual(state.activeDisplayName, "Spotify")
        XCTAssertEqual(state.activeSession?.controlledProcessIdentifier, 101)
        XCTAssertEqual(state.activeSession?.source, .directVisiblePID)
        XCTAssertTrue(state.isActive(appID: "spotify", isLiveControlActive: true))
        XCTAssertFalse(state.isActive(appID: "music", isLiveControlActive: true))
        XCTAssertFalse(state.isActive(appID: "spotify", isLiveControlActive: false))
    }

    func testBeginningHelperSessionKeepsVisibleDisplayNameAndStoresHelperPIDInternally() {
        var state = ProductRealControlState()

        state.beginSession(
            visibleAppID: "youtube",
            displayName: "YouTube",
            controlledProcessIdentifier: 201,
            source: .discoveredHelper
        )

        XCTAssertEqual(state.activeVisibleAppID, "youtube")
        XCTAssertEqual(state.activeDisplayName, "YouTube")
        XCTAssertEqual(state.activeSession?.controlledProcessIdentifier, 201)
        XCTAssertEqual(state.activeSession?.source, .discoveredHelper)
        XCTAssertNotEqual(state.activeDisplayName, "com.apple.WebKit.GPU")
    }

    func testResetClearsActiveSessionMetadata() {
        var state = ProductRealControlState()
        state.beginSession(
            visibleAppID: "youtube",
            displayName: "YouTube",
            controlledProcessIdentifier: 201,
            source: .cachedHelper
        )

        state.clearActiveSession()

        XCTAssertNil(state.activeSession)
        XCTAssertNil(state.activeVisibleAppID)
        XCTAssertNil(state.activeDisplayName)
    }

    func testActiveSessionsAreTrackedByVisibleAppIDCollection() {
        var state = ProductRealControlState()

        state.beginSession(
            visibleAppID: "spotify",
            displayName: "Spotify",
            controlledProcessIdentifier: 101,
            source: .directVisiblePID
        )
        state.beginSession(
            visibleAppID: "youtube",
            displayName: "YouTube",
            controlledProcessIdentifier: 201,
            source: .discoveredHelper
        )

        XCTAssertEqual(Set(state.activeVisibleAppIDs), ["spotify", "youtube"])
        XCTAssertEqual(state.activeSessions.count, 2)
        XCTAssertTrue(state.isActive(appID: "spotify", isLiveControlActive: true))
        XCTAssertTrue(state.isActive(appID: "youtube", isLiveControlActive: true))
        XCTAssertEqual(state.activeSessionsByAppID["youtube"]?.controlledProcessIdentifier, 201)
    }

    func testBeginningSessionForSameAppReplacesThatAppsSession() {
        var state = ProductRealControlState()

        state.beginSession(
            visibleAppID: "youtube",
            displayName: "YouTube",
            controlledProcessIdentifier: 201,
            source: .discoveredHelper
        )
        state.beginSession(
            visibleAppID: "youtube",
            displayName: "YouTube",
            controlledProcessIdentifier: 202,
            source: .cachedHelper
        )

        XCTAssertEqual(state.activeSessions.count, 1)
        XCTAssertEqual(state.activeSessionsByAppID["youtube"]?.controlledProcessIdentifier, 202)
        XCTAssertEqual(state.activeSessionsByAppID["youtube"]?.source, .cachedHelper)
    }

    func testClearSessionForAppRemovesOnlyThatAppSession() {
        var state = ProductRealControlState()
        state.beginSession(
            visibleAppID: "spotify",
            displayName: "Spotify",
            controlledProcessIdentifier: 101,
            source: .directVisiblePID
        )
        state.beginSession(
            visibleAppID: "youtube",
            displayName: "YouTube",
            controlledProcessIdentifier: 201,
            source: .discoveredHelper
        )

        state.clearSession(for: "spotify")

        XCTAssertEqual(state.activeVisibleAppIDs, ["youtube"])
        XCTAssertFalse(state.isActive(appID: "spotify", isLiveControlActive: true))
        XCTAssertTrue(state.isActive(appID: "youtube", isLiveControlActive: true))
    }

    func testClearActiveSessionRemovesAllSessions() {
        var state = ProductRealControlState()
        state.beginSession(
            visibleAppID: "spotify",
            displayName: "Spotify",
            controlledProcessIdentifier: 101,
            source: .directVisiblePID
        )
        state.beginSession(
            visibleAppID: "youtube",
            displayName: "YouTube",
            controlledProcessIdentifier: 201,
            source: .discoveredHelper
        )

        state.clearActiveSession()

        XCTAssertTrue(state.activeSessions.isEmpty)
        XCTAssertTrue(state.activeVisibleAppIDs.isEmpty)
        XCTAssertNil(state.activeSession)
    }

    // MARK: - Per-app start-request tokens

    func testEachAppGetsIndependentStartRequestTokens() {
        var state = ProductRealControlState()

        let spotifyRequest = state.beginStartRequest(for: "spotify")
        let youtubeRequest = state.beginStartRequest(for: "youtube")

        XCTAssertNotEqual(spotifyRequest, youtubeRequest)
        XCTAssertTrue(state.isCurrentStartRequest(spotifyRequest, for: "spotify"))
        XCTAssertTrue(state.isCurrentStartRequest(youtubeRequest, for: "youtube"))
        // A token is only current for its own app.
        XCTAssertFalse(state.isCurrentStartRequest(spotifyRequest, for: "youtube"))
        XCTAssertFalse(state.isCurrentStartRequest(youtubeRequest, for: "spotify"))
    }

    func testNewStartRequestForSameAppSupersedesPrevious() {
        var state = ProductRealControlState()

        let first = state.beginStartRequest(for: "spotify")
        let second = state.beginStartRequest(for: "spotify")

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(state.isCurrentStartRequest(first, for: "spotify"))
        XCTAssertTrue(state.isCurrentStartRequest(second, for: "spotify"))
    }

    func testNewStartRequestForOtherAppDoesNotDisturbExistingRequest() {
        var state = ProductRealControlState()

        let spotifyRequest = state.beginStartRequest(for: "spotify")
        _ = state.beginStartRequest(for: "youtube")

        XCTAssertTrue(state.isCurrentStartRequest(spotifyRequest, for: "spotify"))
    }

    func testClearStartRequestClearsOnlyThatApp() {
        var state = ProductRealControlState()
        let spotifyRequest = state.beginStartRequest(for: "spotify")
        let youtubeRequest = state.beginStartRequest(for: "youtube")

        state.clearStartRequest(for: "spotify")

        XCTAssertFalse(state.isCurrentStartRequest(spotifyRequest, for: "spotify"))
        XCTAssertTrue(state.isCurrentStartRequest(youtubeRequest, for: "youtube"))
        XCTAssertEqual(Array(state.pendingStartRequestByAppID.keys), ["youtube"])
    }

    func testClearAllStartRequestsClearsEveryPendingRequest() {
        var state = ProductRealControlState()
        let spotifyRequest = state.beginStartRequest(for: "spotify")
        let youtubeRequest = state.beginStartRequest(for: "youtube")

        state.clearAllStartRequests()

        XCTAssertFalse(state.isCurrentStartRequest(spotifyRequest, for: "spotify"))
        XCTAssertFalse(state.isCurrentStartRequest(youtubeRequest, for: "youtube"))
        XCTAssertTrue(state.pendingStartRequestByAppID.isEmpty)
    }

    func testBeginSessionStoresStartRequestIDInActiveMetadata() {
        var state = ProductRealControlState()
        let request = state.beginStartRequest(for: "spotify")

        state.beginSession(
            visibleAppID: "spotify",
            displayName: "Spotify",
            controlledProcessIdentifier: 101,
            source: .directVisiblePID,
            startRequestID: request
        )

        XCTAssertEqual(state.activeSessionsByAppID["spotify"]?.startRequestID, request)
    }

    func testHelperSessionWithStartRequestKeepsVisibleNameAndHidesHelperIdentity() {
        var state = ProductRealControlState()
        let request = state.beginStartRequest(for: "youtube")

        state.beginSession(
            visibleAppID: "youtube",
            displayName: "YouTube",
            controlledProcessIdentifier: 201,
            source: .discoveredHelper,
            startRequestID: request
        )

        let session = state.activeSessionsByAppID["youtube"]
        XCTAssertEqual(session?.displayName, "YouTube")
        XCTAssertEqual(session?.startRequestID, request)
        // Helper PID is kept internally as the controlled process; the display name never
        // exposes the helper process identity.
        XCTAssertEqual(session?.controlledProcessIdentifier, 201)
        XCTAssertNotEqual(session?.displayName, "com.apple.WebKit.GPU")
    }

    func testStartRequestsDoNotDisturbActiveSessionCollection() {
        var state = ProductRealControlState()
        state.beginSession(
            visibleAppID: "spotify",
            displayName: "Spotify",
            controlledProcessIdentifier: 101,
            source: .directVisiblePID
        )

        _ = state.beginStartRequest(for: "youtube")
        state.clearStartRequest(for: "youtube")

        // Pending-request bookkeeping must not change the active session collection.
        XCTAssertEqual(state.activeVisibleAppIDs, ["spotify"])
        XCTAssertEqual(state.activeSessionsByAppID["spotify"]?.controlledProcessIdentifier, 101)
    }

    func testResolutionStateIsTrackedByVisibleRowID() {
        var state = ProductRealControlState()

        state.beginResolution(for: "youtube")

        XCTAssertTrue(state.isResolving)
        XCTAssertTrue(state.isResolving(appID: "youtube"))
        XCTAssertFalse(state.isResolving(appID: "spotify"))
        XCTAssertEqual(state.resolutionStateByAppID, ["youtube": .resolving])
        XCTAssertEqual(state.resolvingAppIDs, ["youtube"])
        XCTAssertTrue(state.shouldAcceptResolutionResult(for: "youtube"))
        XCTAssertFalse(state.shouldAcceptResolutionResult(for: "spotify"))
    }

    func testClearingResolutionRemovesOnlyThatRowState() {
        var state = ProductRealControlState()
        state.beginResolution(for: "youtube")

        state.clearResolution(for: "youtube")

        XCTAssertFalse(state.isResolving)
        XCTAssertFalse(state.isResolving(appID: "youtube"))
        XCTAssertFalse(state.shouldAcceptResolutionResult(for: "youtube"))
    }

    func testBeginResolutionReplacesPreviousResolvingRow() {
        var state = ProductRealControlState()
        state.beginResolution(for: "youtube")

        state.beginResolution(for: "safari")

        XCTAssertFalse(state.isResolving(appID: "youtube"))
        XCTAssertTrue(state.isResolving(appID: "safari"))
        XCTAssertEqual(state.resolutionStateByAppID, ["safari": .resolving])
    }

    func testSourceMappingFromResolvedTargetSource() {
        XCTAssertEqual(ProductRealControlStartSource(resolutionSource: nil), .directVisiblePID)
        XCTAssertEqual(ProductRealControlStartSource(resolutionSource: .directVisibleApp), .directVisiblePID)
        XCTAssertEqual(ProductRealControlStartSource(resolutionSource: .discoveredHelper), .discoveredHelper)
        XCTAssertEqual(ProductRealControlStartSource(resolutionSource: .cachedHelper), .cachedHelper)
    }

    // MARK: - shouldAcceptCallback

    func testCallbackAcceptedForCurrentPendingStartRequest() {
        var state = ProductRealControlState()
        let request = state.beginStartRequest(for: "spotify")

        XCTAssertTrue(state.shouldAcceptCallback(for: "spotify", requestID: request))
    }

    func testStaleCallbackRejectedWhenRequestSupersededAndNoConfirmedSession() {
        var state = ProductRealControlState()
        let first = state.beginStartRequest(for: "spotify")
        let second = state.beginStartRequest(for: "spotify")

        XCTAssertFalse(state.shouldAcceptCallback(for: "spotify", requestID: first))
        XCTAssertTrue(state.shouldAcceptCallback(for: "spotify", requestID: second))
    }

    func testCallbackAcceptedForConfirmedSessionThatOwnsRequestEvenAfterPendingCleared() {
        var state = ProductRealControlState()
        let request = state.beginStartRequest(for: "spotify")
        state.beginSession(
            visibleAppID: "spotify",
            displayName: "Spotify",
            controlledProcessIdentifier: 101,
            source: .directVisiblePID,
            liveSessionID: ProcessTapLiveSessionID(),
            startRequestID: request
        )
        state.clearStartRequest(for: "spotify")

        XCTAssertFalse(state.isCurrentStartRequest(request, for: "spotify"))
        XCTAssertTrue(state.shouldAcceptCallback(for: "spotify", requestID: request))
    }

    func testCallbackRejectedForOptimisticSessionWithoutLiveSessionIDOnceSuperseded() {
        var state = ProductRealControlState()
        let request = state.beginStartRequest(for: "spotify")
        state.beginSession(
            visibleAppID: "spotify",
            displayName: "Spotify",
            controlledProcessIdentifier: 101,
            source: .directVisiblePID,
            liveSessionID: nil,
            startRequestID: request
        )
        _ = state.beginStartRequest(for: "spotify")

        // Session still carries this request id but has no live session id, so a late callback
        // for the superseded request must be rejected.
        XCTAssertFalse(state.shouldAcceptCallback(for: "spotify", requestID: request))
    }

    func testCallbackRejectedForUnknownApp() {
        let state = ProductRealControlState()
        let bogus = ProductRealControlStartRequestID(rawValue: 999)

        XCTAssertFalse(state.shouldAcceptCallback(for: "ghost", requestID: bogus))
    }

    func testCallbackRejectedWhenConfirmedSessionOwnsADifferentRequest() {
        var state = ProductRealControlState()
        let request = state.beginStartRequest(for: "spotify")
        state.beginSession(
            visibleAppID: "spotify",
            displayName: "Spotify",
            controlledProcessIdentifier: 101,
            source: .directVisiblePID,
            liveSessionID: ProcessTapLiveSessionID(),
            startRequestID: request
        )
        state.clearStartRequest(for: "spotify")
        let bogus = ProductRealControlStartRequestID(rawValue: 999)

        XCTAssertFalse(state.shouldAcceptCallback(for: "spotify", requestID: bogus))
    }

    // MARK: - wouldExceedConcurrentSessionCap

    func testStartAllowedWhenUnderCap() {
        let state = ProductRealControlState()

        XCTAssertFalse(state.wouldExceedConcurrentSessionCap(for: "spotify", cap: 3))
    }

    func testNewAppBlockedOnceCapReached() {
        var state = ProductRealControlState()
        for appID in ["a", "b", "c"] {
            state.beginSession(
                visibleAppID: appID,
                displayName: appID,
                controlledProcessIdentifier: 100,
                source: .directVisiblePID
            )
        }

        XCTAssertEqual(state.activeSessions.count, 3)
        XCTAssertTrue(state.wouldExceedConcurrentSessionCap(for: "d", cap: 3))
    }

    func testExistingAppNotBlockedAtCapBecauseItDoesNotCountTowardLimit() {
        var state = ProductRealControlState()
        for appID in ["a", "b", "c"] {
            state.beginSession(
                visibleAppID: appID,
                displayName: appID,
                controlledProcessIdentifier: 100,
                source: .directVisiblePID
            )
        }

        // An app that already owns a session may re-assert even at the cap.
        XCTAssertFalse(state.wouldExceedConcurrentSessionCap(for: "b", cap: 3))
    }

    func testNewAppBlockedUnderCapOfOneWhenAnotherSessionActive() {
        var state = ProductRealControlState()
        state.beginSession(
            visibleAppID: "a",
            displayName: "a",
            controlledProcessIdentifier: 100,
            source: .directVisiblePID
        )

        XCTAssertTrue(state.wouldExceedConcurrentSessionCap(for: "b", cap: 1))
        XCTAssertFalse(state.wouldExceedConcurrentSessionCap(for: "a", cap: 1))
    }

    // A nil cap is the product default (no app-count limit): never blocks, however many apps run.
    func testNilCapNeverBlocksNewOrExistingApp() {
        var state = ProductRealControlState()
        for appID in ["a", "b", "c", "d", "e", "f", "g"] {
            state.beginSession(
                visibleAppID: appID,
                displayName: appID,
                controlledProcessIdentifier: 100,
                source: .directVisiblePID
            )
        }

        XCTAssertEqual(state.activeSessions.count, 7)
        XCTAssertFalse(state.wouldExceedConcurrentSessionCap(for: "h", cap: nil))
        XCTAssertFalse(state.wouldExceedConcurrentSessionCap(for: "a", cap: nil))
    }

    func testGainOptionUsesCurrentMuteAndVolumeMapping() {
        let audibleApp = MixerAppItem(
            id: "spotify",
            name: "Spotify",
            icon: .systemSymbol("music.note"),
            processIdentifier: 101,
            volume: 42,
            isMuted: false
        )
        let mutedApp = MixerAppItem(
            id: "music",
            name: "Music",
            icon: .systemSymbol("music.quarternote.3"),
            processIdentifier: 102,
            volume: 88,
            isMuted: true
        )

        XCTAssertEqual(ProductRealControlState.gainOption(for: audibleApp).scalar, 0.42)
        XCTAssertEqual(ProductRealControlState.gainOption(for: audibleApp).percentLabel, "42%")
        XCTAssertEqual(ProductRealControlState.gainOption(for: mutedApp).scalar, 0)
        XCTAssertEqual(ProductRealControlState.gainOption(for: mutedApp).percentLabel, "0%")
    }
}
