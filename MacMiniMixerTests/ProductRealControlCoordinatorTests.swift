import XCTest
@testable import MacMiniMixer

@MainActor
final class ProductRealControlCoordinatorTests: XCTestCase {
    func testCoordinatorConstructsWithFakes() {
        let harness = makeHarness()

        XCTAssertNotNil(harness.coordinator)
        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
    }

    func testCleanupStopsStartedSessionByItsOwnID() async {
        let harness = makeHarness()
        let sessionID = ProcessTapLiveSessionID()
        let startResult = ProcessTapLiveSessionStartResult(
            sessionID: sessionID,
            result: makeResult(.liveControlStarted)
        )

        await harness.coordinator.cleanupStaleProductLiveStart(startResult)

        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.count, 1)
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.first?.id, sessionID)
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.first?.reason, .userStopped)
    }

    func testCleanupIsNoOpWhenStartDidNotSucceed() async {
        let harness = makeHarness()
        // A failed start still carries a session id in this contrived fixture; cleanup must ignore it
        // because the outcome is not `.liveControlStarted`.
        let startResult = ProcessTapLiveSessionStartResult(
            sessionID: ProcessTapLiveSessionID(),
            result: makeResult(.liveControlSetupFailed)
        )

        await harness.coordinator.cleanupStaleProductLiveStart(startResult)

        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
    }

    func testCleanupIsNoOpWhenStartedWithoutSessionID() async {
        let harness = makeHarness()
        let startResult = ProcessTapLiveSessionStartResult(
            sessionID: nil,
            result: makeResult(.liveControlStarted)
        )

        await harness.coordinator.cleanupStaleProductLiveStart(startResult)

        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
    }

    // MARK: - State ownership / forwarding

    func testStateMutationThroughCoordinatorFiresOnWillChangeOncePerWrite() {
        let harness = makeHarness()
        var willChangeCount = 0
        harness.coordinator.setOnWillChange { willChangeCount += 1 }

        harness.coordinator.productRealControlState.beginSession(
            visibleAppID: "a",
            displayName: "A",
            controlledProcessIdentifier: 1,
            source: .directVisiblePID
        )
        harness.coordinator.productRealControlState.beginOperation(for: "a")

        XCTAssertEqual(willChangeCount, 2)
        XCTAssertEqual(harness.coordinator.productRealControlState.activeVisibleAppIDs, ["a"])
        XCTAssertTrue(harness.coordinator.productRealControlState.isOperationPending(for: "a"))
    }

    func testStateReadThroughCoordinatorDoesNotFireOnWillChange() {
        let harness = makeHarness()
        harness.coordinator.productRealControlState.beginSession(
            visibleAppID: "a",
            displayName: "A",
            controlledProcessIdentifier: 1,
            source: .directVisiblePID
        )
        var willChangeCount = 0
        harness.coordinator.setOnWillChange { willChangeCount += 1 }

        _ = harness.coordinator.productRealControlState.activeSessions
        _ = harness.coordinator.productRealControlState.isResolving

        XCTAssertEqual(willChangeCount, 0)
    }

    func testCoordinatorForwardsStateHelpersConsistently() {
        let harness = makeHarness()

        // Cap helper still reachable through the coordinator-owned state.
        XCTAssertFalse(harness.coordinator.productRealControlState.wouldExceedConcurrentSessionCap(for: "a", cap: 3))

        // Callback acceptance helper still reachable and consistent after a mutation.
        let request = harness.coordinator.productRealControlState.beginStartRequest(for: "a")
        XCTAssertTrue(harness.coordinator.productRealControlState.shouldAcceptCallback(for: "a", requestID: request))

        harness.coordinator.productRealControlState.beginResolution(for: "a")
        XCTAssertTrue(harness.coordinator.productRealControlState.isResolving(appID: "a"))
    }

    // MARK: - Resolution slice

    func testStartResolvedStartsDirectlyWhenVisibleProcessEligible() {
        let harness = makeHarness(visibleProcessEligible: true)
        let app = makeApp()
        harness.context.apps = [app]

        harness.coordinator.startResolvedExperimentalControl(for: app)

        // The direct-eligible path runs the async start body, which synchronously creates the
        // optimistic session (before awaiting) and sets the active name; no resolution is entered.
        XCTAssertNotNil(harness.coordinator.productRealControlState.activeSessionsByAppID[app.id])
        XCTAssertFalse(harness.coordinator.productRealControlState.isResolving)
        XCTAssertEqual(harness.sideEffects.activeNameHistory.last, app.name)
    }

    func testHandleResolvedResultStartsWithResolvedTargetWhenResolving() {
        let harness = makeHarness()
        let app = makeApp()
        harness.context.apps = [app]
        harness.coordinator.productRealControlState.beginResolution(for: app.id)

        let resolved = ResolvedAppAudioTarget(
            visibleAppID: app.id,
            visibleAppName: app.name,
            target: makeTarget(for: app),
            kind: .helper,
            source: .discoveredHelper
        )
        harness.coordinator.handleAppAudioTargetResolution(.resolved(resolved), for: app.id)

        // Resolved → async start body runs; optimistic session created carrying the resolved source;
        // no longer resolving.
        XCTAssertFalse(harness.coordinator.productRealControlState.isResolving)
        XCTAssertEqual(harness.coordinator.productRealControlState.activeSessionsByAppID[app.id]?.source, .discoveredHelper)
    }

    func testHandleUnavailableResultReportsReasonAndClearsResolving() {
        let harness = makeHarness()
        harness.coordinator.productRealControlState.beginResolution(for: "safari")

        harness.coordinator.handleAppAudioTargetResolution(.unavailable("No audio helper found"), for: "safari")

        XCTAssertEqual(harness.sideEffects.statusMessages, ["No audio helper found"])
        XCTAssertTrue(harness.coordinator.productRealControlState.activeSessions.isEmpty)
        XCTAssertFalse(harness.coordinator.productRealControlState.isResolving)
    }

    func testHandleCancelledResultClearsResolvingWithoutStatus() {
        let harness = makeHarness()
        harness.coordinator.productRealControlState.beginResolution(for: "safari")

        harness.coordinator.handleAppAudioTargetResolution(.cancelled, for: "safari")

        XCTAssertTrue(harness.sideEffects.statusMessages.isEmpty)
        XCTAssertTrue(harness.coordinator.productRealControlState.activeSessions.isEmpty)
        XCTAssertFalse(harness.coordinator.productRealControlState.isResolving)
    }

    func testHandleResultIgnoredWhenNotResolving() {
        let harness = makeHarness()
        let app = makeApp()
        harness.context.apps = [app]
        let resolved = ResolvedAppAudioTarget(
            visibleAppID: app.id,
            visibleAppName: app.name,
            target: makeTarget(for: app),
            kind: .helper,
            source: .discoveredHelper
        )

        // Not resolving for this app → the result is stale and must be ignored.
        harness.coordinator.handleAppAudioTargetResolution(.resolved(resolved), for: app.id)

        XCTAssertTrue(harness.coordinator.productRealControlState.activeSessions.isEmpty)
        XCTAssertTrue(harness.sideEffects.statusMessages.isEmpty)
    }

    func testCancelAppAudioTargetResolutionClearsResolvingAndCancelsResolver() {
        let harness = makeHarness()
        harness.coordinator.productRealControlState.beginResolution(for: "safari")

        harness.coordinator.cancelAppAudioTargetResolution(reason: .userStopped)

        XCTAssertFalse(harness.coordinator.productRealControlState.isResolving)
        XCTAssertEqual(harness.resolver.cancelReasons, [.userStopped])
    }

    func testCancelAppAudioTargetResolutionIsNoOpWhenNotResolving() {
        let harness = makeHarness()

        harness.coordinator.cancelAppAudioTargetResolution(reason: .userStopped)

        XCTAssertTrue(harness.resolver.cancelReasons.isEmpty)
    }

    // MARK: - Async start body

    func testSuccessfulStartConfirmsSession() async {
        let harness = makeHarness()
        let app = makeApp()
        harness.context.apps = [app]
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        await waitUntil { harness.coordinator.productRealControlState.activeSessionsByAppID[app.id]?.liveSessionID != nil }

        let session = harness.coordinator.productRealControlState.activeSessionsByAppID[app.id]
        XCTAssertEqual(session?.liveSessionID, sessionID)
        XCTAssertFalse(harness.coordinator.productRealControlState.isOperationPending(for: app.id))
        XCTAssertEqual(harness.sideEffects.activeNameHistory.last, app.name)
        XCTAssertTrue(harness.sideEffects.diagnosticResults.contains { $0.outcome == .liveControlStarted })
        XCTAssertEqual(harness.sideEffects.diagnosticRunningHistory.last, false)
    }

    func testFailedStartClearsPendingAndReportsFailure() async {
        let harness = makeHarness()
        let app = makeApp()
        harness.context.apps = [app]
        harness.liveSessionManager.configureStart(
            result: ProcessTapLiveSessionStartResult(sessionID: nil, result: makeResult(.liveControlSetupFailed))
        )

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        await waitUntil { harness.sideEffects.statusMessages.contains("Could not start live control for this app") }

        XCTAssertNil(harness.coordinator.productRealControlState.activeSessionsByAppID[app.id])
        XCTAssertFalse(harness.coordinator.productRealControlState.isOperationPending(for: app.id))
        XCTAssertEqual(harness.sideEffects.diagnosticRunningHistory.last, false)
    }

    func testStaleStartResultRejectedAndCleanupRegistered() async {
        let harness = makeHarness()
        let app = makeApp()
        harness.context.apps = [app]
        let orphanSessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(orphanSessionID))

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        // Supersede the in-flight request synchronously, before the queued start task runs its
        // post-await block, so the completion is recognised as stale.
        _ = harness.coordinator.productRealControlState.beginStartRequest(for: app.id)

        await waitUntil { !harness.liveSessionManager.stopSessionCalls.isEmpty }

        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.contains { $0.id == orphanSessionID })
        XCTAssertFalse(harness.coordinator.productRealControlState.isOperationPending(for: app.id))
    }

    func testDiagnosticsProgressCallbackUpdatesWhenAccepted() async {
        let harness = makeHarness()
        let app = makeApp()
        harness.context.apps = [app]
        harness.liveSessionManager.configureStart(result: startedResult(ProcessTapLiveSessionID()))
        harness.liveSessionManager.configureEmitDiagnostics(makeDiagnostics(callbackCount: 5))

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        await waitUntil { harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 5 } }

        XCTAssertTrue(harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 5 })
    }

    func testDiagnosticsProgressCallbackIgnoredWhenStale() async {
        let harness = makeHarness()
        let app = makeApp()
        harness.context.apps = [app]
        harness.liveSessionManager.configureStart(result: startedResult(ProcessTapLiveSessionID()))
        harness.liveSessionManager.configureEmitDiagnostics(makeDiagnostics(callbackCount: 7))

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        _ = harness.coordinator.productRealControlState.beginStartRequest(for: app.id) // supersede

        await waitUntil { !harness.coordinator.productRealControlState.isOperationPending(for: app.id) }

        // The superseded request's diagnostics callback must be rejected by shouldAcceptCallback.
        XCTAssertFalse(harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 7 })
    }

    func testAsyncStartOnStoppedUsesCoordinatorLocalHandler() async {
        let harness = makeHarness()
        let app = makeApp()
        harness.context.apps = [app]
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))

        // Start and let the async body confirm the session with its engine id.
        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        await waitUntil { harness.coordinator.productRealControlState.activeSessionsByAppID[app.id]?.liveSessionID == sessionID }

        // Deliver the engine stop through the *captured* onStopped closure — the real wiring the
        // coordinator installed. Post-move this reaches the coordinator's own
        // `handleProductLiveControlStopped` (the `ProductRealControlSideEffects` seam no longer has a
        // `handleProductLiveControlStopped` member — its absence is a compile-time guarantee here).
        harness.liveSessionManager.emitCapturedStopped(id: sessionID, result: makeResult(.liveControlStopped), diagnostics: nil)
        await waitUntil { !harness.sideEffects.stoppedDisplayCalls.isEmpty }

        // The coordinator handled it locally: cleared its own session and ran the shared display
        // cleanup through the new seam callback.
        XCTAssertNil(harness.coordinator.productRealControlState.activeSessionsByAppID[app.id])
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.last?.result.outcome, .liveControlStopped)
    }

    // Cached-helper retry (a `.cachedHelper` failure re-attempting with `allowsCachedLookup: false`)
    // is exercised end-to-end by the existing MixerViewModelLiveControlTests; reproducing its
    // two-phase resolve + eligibility fixture at the coordinator unit level would be broad and
    // brittle, so it is intentionally left to the VM suite.

    // MARK: - Per-app stop leaf

    func testStopExperimentalControlStopsSessionByIDWithReason() async {
        let harness = makeHarness()
        let app = makeApp()
        let sessionID = ProcessTapLiveSessionID()
        harness.coordinator.productRealControlState.beginSession(
            visibleAppID: app.id,
            displayName: app.name,
            controlledProcessIdentifier: app.processIdentifier,
            source: .directVisiblePID,
            liveSessionID: sessionID
        )

        harness.coordinator.stopExperimentalControl(for: app.id, reason: .targetAppExited)
        await waitUntil { !harness.liveSessionManager.stopSessionCalls.isEmpty }

        // The stop task (registered with the settle gate) tears the session down by its own engine id
        // with the caller's reason.
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.count, 1)
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.first?.id, sessionID)
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.first?.reason, .targetAppExited)
        // The live-session path does NOT clear the local session; that terminal clear is owned by the
        // stop callback (`handleProductLiveControlStopped`). The session therefore remains present here.
        XCTAssertEqual(harness.coordinator.productRealControlState.activeSessionsByAppID[app.id]?.liveSessionID, sessionID)
    }

    func testStopExperimentalControlOptimisticWindowClearsLocallyWithoutStopSession() async {
        let harness = makeHarness()
        let app = makeApp()
        // No `liveSessionID` → optimistic window (start still in flight / not yet confirmed).
        harness.coordinator.productRealControlState.beginSession(
            visibleAppID: app.id,
            displayName: app.name,
            controlledProcessIdentifier: app.processIdentifier,
            source: .directVisiblePID
        )

        harness.coordinator.stopExperimentalControl(for: app.id)
        // Give any (erroneous) async stop task a chance to run before asserting it never fired.
        await Task.yield()

        // The session is cleared locally and the active-name display refreshed, without touching the
        // engine.
        XCTAssertNil(harness.coordinator.productRealControlState.activeSessionsByAppID[app.id])
        XCTAssertTrue(harness.coordinator.productRealControlState.activeVisibleAppIDs.isEmpty)
        XCTAssertEqual(harness.sideEffects.activeNameHistory.last, .some(nil))
        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
        // No stop transition is marked in flight in the optimistic window.
        XCTAssertFalse(harness.coordinator.productRealControlState.isOperationPending(for: app.id))
    }

    func testStopExperimentalControlMarksOperationPendingForLiveSessionStop() {
        let harness = makeHarness()
        let app = makeApp()
        let sessionID = ProcessTapLiveSessionID()
        harness.coordinator.productRealControlState.beginSession(
            visibleAppID: app.id,
            displayName: app.name,
            controlledProcessIdentifier: app.processIdentifier,
            source: .directVisiblePID,
            liveSessionID: sessionID
        )

        harness.coordinator.stopExperimentalControl(for: app.id)

        // `beginOperation` runs synchronously before the async stop task; the pending flag stays set
        // here because its terminal clear is owned by the later stop callback (not exercised in this
        // test, so we deliberately do not clear it).
        XCTAssertTrue(harness.coordinator.productRealControlState.isOperationPending(for: app.id))
    }

    // MARK: - Stop-all core and engine stop-callback handling

    /// Confirms two Product Real sessions with engine ids and returns them (a, b).
    private func makeTwoConfirmedSessions(
        _ harness: Harness
    ) -> (appA: MixerAppItem, appB: MixerAppItem, sidA: ProcessTapLiveSessionID, sidB: ProcessTapLiveSessionID) {
        let appA = makeApp(id: "a", name: "Alpha", pid: 1)
        let appB = makeApp(id: "b", name: "Bravo", pid: 2)
        let sidA = ProcessTapLiveSessionID()
        let sidB = ProcessTapLiveSessionID()
        harness.context.apps = [appA, appB]
        harness.coordinator.productRealControlState.beginSession(
            visibleAppID: appA.id, displayName: appA.name,
            controlledProcessIdentifier: appA.processIdentifier,
            source: .directVisiblePID, liveSessionID: sidA
        )
        harness.coordinator.productRealControlState.beginSession(
            visibleAppID: appB.id, displayName: appB.name,
            controlledProcessIdentifier: appB.processIdentifier,
            source: .directVisiblePID, liveSessionID: sidB
        )
        return (appA, appB, sidA, sidB)
    }

    func testStopProductLiveSessionsStopsEveryActiveSession() async {
        let harness = makeHarness()
        let (_, _, sidA, sidB) = makeTwoConfirmedSessions(harness)

        harness.coordinator.stopProductLiveSessions(reason: .userStopped)
        await waitUntil { harness.liveSessionManager.stopSessionCalls.count == 2 }

        // Every live session id is stopped with the exact reason.
        XCTAssertEqual(Set(harness.liveSessionManager.stopSessionCalls.map(\.id)), [sidA, sidB])
        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.allSatisfy { $0.reason == .userStopped })
        // A single batched teardown task is registered with the settle gate (matching the old VM),
        // and it stops both sessions.
        XCTAssertEqual(harness.settleGate.registerStopCount, 1)
        // Unrelated advanced-manual context is untouched by the product stop-all.
        XCTAssertFalse(harness.context.advancedManualLiveControlActive)
    }

    func testStopProductLiveSessionsHandlesNoActiveSessionsLikeBefore() async {
        let harness = makeHarness()
        let diagnostics = makeDiagnostics(callbackCount: 3)
        harness.context.processTapLiveDiagnostics = diagnostics

        harness.coordinator.stopProductLiveSessions(reason: .userStopped)
        await Task.yield()

        // No engine stop, no teardown task registered.
        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
        XCTAssertEqual(harness.settleGate.registerStopCount, 0)
        // Same not-active display path as the old VM: routes a `.liveControlNotActive` stop callback
        // carrying the current diagnostics through the shared display cleanup.
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.count, 1)
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.first?.result.outcome, .liveControlNotActive)
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.first?.diagnostics?.callbackCount, 3)
    }

    func testHandleProductLiveControlStoppedClearsOnlyMatchingSession() {
        let harness = makeHarness()
        let (appA, appB, sidA, _) = makeTwoConfirmedSessions(harness)
        harness.coordinator.productRealControlState.beginOperation(for: appA.id)

        harness.coordinator.handleProductLiveControlStopped(
            sessionID: sidA, result: makeResult(.liveControlStopped), diagnostics: nil
        )

        // Only the matching app's session is cleared; the other remains active.
        XCTAssertNil(harness.coordinator.productRealControlState.activeSessionsByAppID[appA.id])
        XCTAssertNotNil(harness.coordinator.productRealControlState.activeSessionsByAppID[appB.id])
        // The matching app's pending operation clears; active-name refreshes to the surviving session.
        XCTAssertFalse(harness.coordinator.productRealControlState.isOperationPending(for: appA.id))
        XCTAssertEqual(harness.sideEffects.activeNameHistory.last, appB.name)
    }

    func testHandleProductLiveControlStoppedUnknownSessionDoesNotDisturbActiveSessions() {
        let harness = makeHarness()
        let (appA, appB, _, _) = makeTwoConfirmedSessions(harness)
        harness.coordinator.productRealControlState.beginOperation(for: appA.id)

        harness.coordinator.handleProductLiveControlStopped(
            sessionID: ProcessTapLiveSessionID(), result: makeResult(.liveControlStopped), diagnostics: nil
        )

        // An untracked session id leaves every active session and pending flag untouched...
        XCTAssertNotNil(harness.coordinator.productRealControlState.activeSessionsByAppID[appA.id])
        XCTAssertNotNil(harness.coordinator.productRealControlState.activeSessionsByAppID[appB.id])
        XCTAssertTrue(harness.coordinator.productRealControlState.isOperationPending(for: appA.id))
        // ...and performs no display cleanup.
        XCTAssertTrue(harness.sideEffects.stoppedDisplayCalls.isEmpty)
    }

    func testHandleProductLiveControlStoppedRoutesDisplayCleanupThroughSeam() {
        let harness = makeHarness()
        let (_, _, sidA, _) = makeTwoConfirmedSessions(harness)
        let result = makeResult(.liveControlStopped)
        let diagnostics = makeDiagnostics(callbackCount: 9)

        harness.coordinator.handleProductLiveControlStopped(
            sessionID: sidA, result: result, diagnostics: diagnostics
        )

        // The shared display cleanup receives the exact result and diagnostics via the seam callback.
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.count, 1)
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.first?.result.outcome, result.outcome)
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.first?.diagnostics?.callbackCount, 9)
    }

    func testHandleProductLiveControlStoppedClearsPendingOperation() {
        let harness = makeHarness()
        let (appA, _, sidA, _) = makeTwoConfirmedSessions(harness)
        harness.coordinator.productRealControlState.beginOperation(for: appA.id)
        XCTAssertTrue(harness.coordinator.productRealControlState.isOperationPending(for: appA.id))

        harness.coordinator.handleProductLiveControlStopped(
            sessionID: sidA, result: makeResult(.liveControlStopped), diagnostics: nil
        )

        XCTAssertFalse(harness.coordinator.productRealControlState.isOperationPending(for: appA.id))
    }

    // MARK: - App-exit stop slice

    func testStopRealControlForExitedTargetAppsStopsOnlyMissingApps() async {
        let harness = makeHarness()
        let (appA, appB, _, sidB) = makeTwoConfirmedSessions(harness)
        // appA is still running; appB has exited (dropped from the refreshed running-app list).
        harness.context.apps = [appA]

        harness.coordinator.stopRealControlForExitedTargetApps()
        await waitUntil { !harness.liveSessionManager.stopSessionCalls.isEmpty }

        // Only the exited app's live session is stopped, with the app-exit reason.
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.count, 1)
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.first?.id, sidB)
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.first?.reason, .targetAppExited)
        // The still-running app remains active; the exited app's stop is in flight (pending) via the
        // per-app stop leaf until its stop callback lands.
        XCTAssertNotNil(harness.coordinator.productRealControlState.activeSessionsByAppID[appA.id])
        XCTAssertTrue(harness.coordinator.productRealControlState.isOperationPending(for: appB.id))
    }

    func testStopRealControlForExitedTargetAppsDoesNothingWhenAllTargetsStillRunning() async {
        let harness = makeHarness()
        // `makeTwoConfirmedSessions` sets `context.apps = [appA, appB]`, so both targets still run.
        let (appA, appB, _, _) = makeTwoConfirmedSessions(harness)

        harness.coordinator.stopRealControlForExitedTargetApps()
        await Task.yield()

        // No exited app → no stop, no resolution cancel, sessions unchanged.
        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
        XCTAssertTrue(harness.resolver.cancelReasons.isEmpty)
        XCTAssertNotNil(harness.coordinator.productRealControlState.activeSessionsByAppID[appA.id])
        XCTAssertNotNil(harness.coordinator.productRealControlState.activeSessionsByAppID[appB.id])
    }

    // The optimistic-window session (begun, no engine `liveSessionID` yet) is a real state — the
    // app can exit during the async start before `startSession` returns. Here the app-exit slice
    // routes it through the per-app stop leaf's optimistic branch: local clear, no engine stop.
    func testStopRealControlForExitedTargetAppsHandlesOptimisticSessionWithoutLiveID() async {
        let harness = makeHarness()
        let app = makeApp(id: "gone", name: "Gone", pid: 9)
        harness.coordinator.productRealControlState.beginSession(
            visibleAppID: app.id, displayName: app.name,
            controlledProcessIdentifier: app.processIdentifier, source: .directVisiblePID
        )
        // The optimistic app is not in the refreshed running-app list (it exited mid-start).
        harness.context.apps = []

        harness.coordinator.stopRealControlForExitedTargetApps()
        await Task.yield()

        // Optimistic branch of the leaf: session cleared locally, no engine stop issued.
        XCTAssertNil(harness.coordinator.productRealControlState.activeSessionsByAppID[app.id])
        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
    }

    // MARK: - Harness

    private struct Harness {
        let coordinator: ProductRealControlCoordinator
        let liveSessionManager: FakeProductRealLiveSessionManager
        let resolver: RecordingAppAudioTargetResolver
        let settleGate: RecordingStartSettleGate
        // Held so the coordinator's `weak` seam references stay alive for the test's lifetime.
        let sideEffects: StubProductRealControlSideEffects
        let context: StubProductRealControlContext
    }

    private func makeHarness(visibleProcessEligible: Bool = false) -> Harness {
        let liveSessionManager = FakeProductRealLiveSessionManager()
        let resolver = RecordingAppAudioTargetResolver()
        let settleGate = RecordingStartSettleGate()
        let sideEffects = StubProductRealControlSideEffects()
        let context = StubProductRealControlContext()
        let coordinator = ProductRealControlCoordinator(
            liveSessionManager: liveSessionManager,
            appAudioTargetResolver: resolver,
            startSettleGate: settleGate,
            processTapEligibility: { _ in
                visibleProcessEligible ? .eligible : ProcessTapProcessEligibility(isEligible: false, reason: nil)
            },
            sideEffects: sideEffects,
            context: context
        )
        return Harness(
            coordinator: coordinator,
            liveSessionManager: liveSessionManager,
            resolver: resolver,
            settleGate: settleGate,
            sideEffects: sideEffects,
            context: context
        )
    }

    private func makeApp(id: String = "safari", name: String = "Safari", pid: Int32? = 100) -> MixerAppItem {
        MixerAppItem(id: id, name: name, icon: .systemSymbol("app"), processIdentifier: pid, volume: 50)
    }

    private func makeTarget(for app: MixerAppItem) -> ProcessTapTarget {
        ProcessTapTarget(appID: app.id, appName: app.name, processIdentifier: app.processIdentifier)
    }

    private func startedResult(_ sessionID: ProcessTapLiveSessionID) -> ProcessTapLiveSessionStartResult {
        ProcessTapLiveSessionStartResult(sessionID: sessionID, result: makeResult(.liveControlStarted))
    }

    private func makeDiagnostics(callbackCount: Int) -> ProcessTapLiveDiagnostics {
        ProcessTapLiveDiagnostics(
            selectedGain: ProcessTapReplayGainOption(scalar: 1, label: "100%"),
            callbackCount: callbackCount,
            peakLevel: 0,
            rmsLevel: 0,
            enqueuedBufferCount: 0,
            droppedBufferCount: 0,
            enqueueFailureCount: 0,
            copyFailureCount: 0
        )
    }

    /// Polls the (deterministic, immediately-returning) start task to completion via cooperative
    /// yields — no sleeps, no timing reliance. Bounded so a logic error fails fast instead of hanging.
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, iterations: Int = 5000) async {
        var i = 0
        while !condition() && i < iterations {
            await Task.yield()
            i += 1
        }
        XCTAssertTrue(condition(), "waitUntil condition not met within \(iterations) iterations")
    }

    private func makeResult(_ outcome: ProcessTapTestResult.Outcome) -> ProcessTapTestResult {
        ProcessTapTestResult(outcome: outcome, message: "test", severity: .info)
    }
}

// MARK: - Fakes

private final class FakeProductRealLiveSessionManager: ProcessTapLiveControlling & ProcessTapLiveSessionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStopSessionCalls: [(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason)] = []
    private var configuredStartResult: ProcessTapLiveSessionStartResult?
    private var diagnosticsToEmit: ProcessTapLiveDiagnostics?
    private var stoppedToEmit: (id: ProcessTapLiveSessionID?, result: ProcessTapTestResult, diagnostics: ProcessTapLiveDiagnostics?)?
    private var capturedOnStopped: (@Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void)?

    var stopSessionCalls: [(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason)] {
        lock.withLock { recordedStopSessionCalls }
    }

    /// Delivers an engine stop through the most recently started session's captured `onStopped`
    /// closure — the real wiring the coordinator installs — so a test can deliver a stop *after* the
    /// start has confirmed its session (avoiding the during-start ordering race).
    func emitCapturedStopped(id: ProcessTapLiveSessionID, result: ProcessTapTestResult, diagnostics: ProcessTapLiveDiagnostics?) {
        let onStopped = lock.withLock { capturedOnStopped }
        onStopped?(id, result, diagnostics)
    }

    func configureStart(result: ProcessTapLiveSessionStartResult) {
        lock.withLock { configuredStartResult = result }
    }

    func configureEmitDiagnostics(_ diagnostics: ProcessTapLiveDiagnostics) {
        lock.withLock { diagnosticsToEmit = diagnostics }
    }

    func configureEmitStopped(id: ProcessTapLiveSessionID?, result: ProcessTapTestResult, diagnostics: ProcessTapLiveDiagnostics?) {
        lock.withLock { stoppedToEmit = (id, result, diagnostics) }
    }

    var activeSession: ProcessTapLiveSessionState? { nil }
    var activeSessions: [ProcessTapLiveSessionState] { [] }

    func startSession(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapLiveSessionStartResult {
        await startSession(for: target, gain: gain, timeoutPolicy: .standard, onDiagnostics: onDiagnostics, onStopped: onStopped)
    }

    func startSession(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapLiveSessionStartResult {
        let (result, diagnostics, stopped) = lock.withLock {
            capturedOnStopped = onStopped
            return (configuredStartResult, diagnosticsToEmit, stoppedToEmit)
        }
        let startResult = result ?? notActiveStartResult
        let callbackSessionID = startResult.sessionID ?? ProcessTapLiveSessionID()
        if let diagnostics {
            onDiagnostics(callbackSessionID, diagnostics)
        }
        if let stopped {
            onStopped(stopped.id ?? callbackSessionID, stopped.result, stopped.diagnostics)
        }
        return startResult
    }

    func stopSession(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        lock.withLock { recordedStopSessionCalls.append((id, reason)) }
        return ProcessTapTestResult(outcome: .liveControlStopped, message: "stopped", severity: .info)
    }

    func stopAll(reason: ProcessTapLiveStopReason) async -> [ProcessTapTestResult] { [] }

    func updateGain(sessionID: ProcessTapLiveSessionID, gain: ProcessTapReplayGainOption) {}

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        notActiveResult
    }

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        notActiveResult
    }

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption) {}

    @discardableResult
    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult? { nil }

    private var notActiveResult: ProcessTapTestResult {
        ProcessTapTestResult(outcome: .liveControlNotActive, message: "not active", severity: .info)
    }

    private var notActiveStartResult: ProcessTapLiveSessionStartResult {
        ProcessTapLiveSessionStartResult(sessionID: nil, result: notActiveResult)
    }
}

private final class StubProductRealControlSideEffects: ProductRealControlSideEffects {
    private(set) var statusMessages: [String] = []
    private(set) var activeNameHistory: [String?] = []
    private(set) var diagnosticResults: [ProcessTapTestResult] = []
    private(set) var diagnosticProgressHistory: [ProcessTapDiagnosticProgress?] = []
    private(set) var diagnosticRunningHistory: [Bool] = []
    private(set) var stoppedDisplayCalls: [(result: ProcessTapTestResult, diagnostics: ProcessTapLiveDiagnostics?)] = []

    func showProductRealStatus(_ text: String, style: MixerStatusMessage.Style, action: MixerStatusMessage.Action?) {
        statusMessages.append(text)
    }
    func setActiveLiveControlAppName(_ name: String?) {
        activeNameHistory.append(name)
    }
    func setProcessTapLiveDiagnostics(_ diagnostics: ProcessTapLiveDiagnostics?) {}
    func setLiveControlDiagnosticResult(_ result: ProcessTapTestResult) {
        diagnosticResults.append(result)
    }
    func setLiveControlDiagnosticProgress(_ progress: ProcessTapDiagnosticProgress?) {
        diagnosticProgressHistory.append(progress)
    }
    func setLiveControlDiagnosticRunning(_ isRunning: Bool) {
        diagnosticRunningHistory.append(isRunning)
    }
    func applyLiveControlStoppedDisplay(
        result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?
    ) {
        stoppedDisplayCalls.append((result, diagnostics))
    }
}

private final class StubProductRealControlContext: ProductRealControlContext {
    var apps: [MixerAppItem] = []
    var isExperimentalRealAppControlEnabled = false
    var advancedManualLiveControlActive = false
    var selectedProcessTapAppID: MixerAppItem.ID?
    var isTwoAppReadinessRunning = false
    var isProcessTapTesting = false
    var isHelperBusy = false
    var isAppAudioTargetResolving = false
    var isProcessTapLiveControlActive = false
    var processTapLiveDiagnostics: ProcessTapLiveDiagnostics?
}

private final class RecordingAppAudioTargetResolver: AppAudioTargetResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCancelReasons: [ProcessTapCandidateProbeStopReason] = []

    var cancelReasons: [ProcessTapCandidateProbeStopReason] {
        lock.withLock { recordedCancelReasons }
    }

    func resolveTarget(
        for request: AppAudioTargetRequest,
        allowsCachedLookup: Bool,
        onProgress: @escaping @Sendable (AppAudioResolutionProgress) -> Void
    ) async -> AppAudioTargetResolutionResult {
        .cancelled
    }

    func cancelCurrentResolution(reason: ProcessTapCandidateProbeStopReason) {
        lock.withLock { recordedCancelReasons.append(reason) }
    }

    func invalidateCachedTarget(for request: AppAudioTargetRequest) {}
    func invalidateAllCachedTargets() {}
}

/// Records `registerStop` calls so stop-path tests can assert teardown was tracked with the settle
/// gate. Delegates behavior to a real gate with a zero settle delay and a no-op sleeper (no real
/// sleeps), so `waitForReadyToStart` still awaits registered stop tasks exactly as production does.
private final class RecordingStartSettleGate: ProductRealStartSettling, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRegisterStopCount = 0
    private let inner = ProductRealStartSettleGate(settleDelay: 0, sleeper: { _ in })

    var registerStopCount: Int { lock.withLock { recordedRegisterStopCount } }

    func registerStop(_ stop: Task<Void, Never>) {
        lock.withLock { recordedRegisterStopCount += 1 }
        inner.registerStop(stop)
    }

    func waitForReadyToStart() async {
        await inner.waitForReadyToStart()
    }
}
