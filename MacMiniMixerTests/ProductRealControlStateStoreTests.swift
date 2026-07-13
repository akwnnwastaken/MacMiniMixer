import XCTest
@testable import MacMiniMixer

@MainActor
final class ProductRealControlStateStoreTests: XCTestCase {
    func testReadDoesNotNotify() {
        let store = ProductRealControlStateStore()
        var notifications = 0
        store.setOnWillChange { notifications += 1 }

        _ = store.productRealControlState
        _ = store.productRealControlState.activeVisibleAppIDs

        XCTAssertEqual(notifications, 0)
    }

    func testWriteNotifiesExactlyOnceBeforeApplyingState() {
        let store = ProductRealControlStateStore()
        var notifications = 0
        var appIDsObservedAtNotify: [MixerAppItem.ID]?
        store.setOnWillChange {
            notifications += 1
            // willSet-style timing: the callback fires *before* the new state is applied, so a read
            // here still observes the previous (empty) state.
            appIDsObservedAtNotify = store.productRealControlState.activeVisibleAppIDs
        }

        var newState = ProductRealControlState()
        newState.beginSession(
            visibleAppID: "a",
            displayName: "A",
            controlledProcessIdentifier: 1,
            source: .directVisiblePID
        )
        store.productRealControlState = newState

        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(appIDsObservedAtNotify, [], "onWillChange must fire before the write applies")
        XCTAssertEqual(store.productRealControlState.activeVisibleAppIDs, ["a"], "new state is stored after the write")
    }

    func testMultipleWritesNotifyOncePerWrite() {
        let store = ProductRealControlStateStore()
        var notifications = 0
        store.setOnWillChange { notifications += 1 }

        var state = ProductRealControlState()
        store.productRealControlState = state
        state.beginOperation(for: "a")
        store.productRealControlState = state
        store.productRealControlState = state

        XCTAssertEqual(notifications, 3)
    }

    func testStateRoundTripsThroughStore() {
        let store = ProductRealControlStateStore()
        var state = ProductRealControlState()
        state.beginSession(
            visibleAppID: "safari",
            displayName: "Safari",
            controlledProcessIdentifier: 100,
            source: .directVisiblePID,
            liveSessionID: ProcessTapLiveSessionID()
        )
        state.beginOperation(for: "safari")
        let requestID = state.beginStartRequest(for: "spotify")

        store.productRealControlState = state

        let readBack = store.productRealControlState
        XCTAssertEqual(readBack.activeVisibleAppIDs, ["safari"])
        XCTAssertTrue(readBack.hasConfirmedLiveSession)
        XCTAssertTrue(readBack.isOperationPending(for: "safari"))
        XCTAssertTrue(readBack.isCurrentStartRequest(requestID, for: "spotify"))
    }
}
