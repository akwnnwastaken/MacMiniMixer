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

    func testStartRequestsAreGeneratedAndValidatedExplicitly() {
        var state = ProductRealControlState()

        let first = state.beginStartRequest()
        XCTAssertEqual(first.rawValue, 1)
        XCTAssertTrue(state.isCurrentStartRequest(first))

        let second = state.beginStartRequest()
        XCTAssertEqual(second.rawValue, 2)
        XCTAssertFalse(state.isCurrentStartRequest(first))
        XCTAssertTrue(state.isCurrentStartRequest(second))

        state.clearStartRequest(first)
        XCTAssertTrue(state.isCurrentStartRequest(second))

        state.clearStartRequest(second)
        XCTAssertNil(state.currentStartRequestID)
    }

    func testInvalidatingCurrentStartRequestRejectsPendingCompletionWithoutClearingActiveMetadata() {
        var state = ProductRealControlState()
        let requestID = state.beginStartRequest()
        state.beginSession(
            visibleAppID: "spotify",
            displayName: "Spotify",
            controlledProcessIdentifier: 101,
            source: .directVisiblePID,
            startRequestID: requestID
        )

        state.invalidateCurrentStartRequest()

        XCTAssertFalse(state.isCurrentStartRequest(requestID))
        XCTAssertEqual(state.activeVisibleAppID, "spotify")
        XCTAssertEqual(state.activeStartRequestID, requestID)
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
