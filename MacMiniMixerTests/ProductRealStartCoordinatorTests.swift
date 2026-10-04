import XCTest
@testable import MacMiniMixer

@MainActor
final class ProductRealStartCoordinatorTests: XCTestCase {
    // MARK: - Resolution slice

    func testStartResolvedStartsDirectlyWhenVisibleProcessEligible() {
        let harness = makeStartHarness(visibleProcessEligible: true)
        let app = makeApp()
        harness.context.apps = [app]

        harness.coordinator.startResolvedExperimentalControl(for: app)

        // The direct-eligible path runs the async start body, which synchronously creates the
        // optimistic session (before awaiting) and sets the active name; no resolution is entered.
        XCTAssertNotNil(harness.stateStore.productRealControlState.activeSessionsByAppID[app.id])
        XCTAssertFalse(harness.stateStore.productRealControlState.isResolving)
        XCTAssertEqual(harness.sideEffects.activeNameHistory.last, app.name)
    }

    func testHandleResolvedResultStartsWithResolvedTargetWhenResolving() {
        let harness = makeStartHarness()
        let app = makeApp()
        harness.context.apps = [app]
        harness.stateStore.productRealControlState.beginResolution(for: app.id)

        let resolved = ResolvedAppAudioTarget(
            visibleAppID: app.id,
            visibleAppName: app.name,
            target: makeTarget(for: app),
            kind: .helper,
            source: .discoveredHelper
        )
        harness.coordinator.handleAppAudioTargetResolution(.resolved(resolved), for: app.id)

        XCTAssertFalse(harness.stateStore.productRealControlState.isResolving)
        XCTAssertEqual(harness.stateStore.productRealControlState.activeSessionsByAppID[app.id]?.source, .discoveredHelper)
    }

    func testHandleUnavailableResultReportsReasonAndClearsResolving() {
        let harness = makeStartHarness()
        harness.stateStore.productRealControlState.beginResolution(for: "safari")

        harness.coordinator.handleAppAudioTargetResolution(.unavailable("No audio helper found"), for: "safari")

        XCTAssertEqual(harness.sideEffects.statusMessages, ["No audio helper found"])
        XCTAssertTrue(harness.stateStore.productRealControlState.activeSessions.isEmpty)
        XCTAssertFalse(harness.stateStore.productRealControlState.isResolving)
    }

    func testHandleCancelledResultClearsResolvingWithoutStatus() {
        let harness = makeStartHarness()
        harness.stateStore.productRealControlState.beginResolution(for: "safari")

        harness.coordinator.handleAppAudioTargetResolution(.cancelled, for: "safari")

        XCTAssertTrue(harness.sideEffects.statusMessages.isEmpty)
        XCTAssertTrue(harness.stateStore.productRealControlState.activeSessions.isEmpty)
        XCTAssertFalse(harness.stateStore.productRealControlState.isResolving)
    }

    func testHandleResultIgnoredWhenNotResolving() {
        let harness = makeStartHarness()
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

        XCTAssertTrue(harness.stateStore.productRealControlState.activeSessions.isEmpty)
        XCTAssertTrue(harness.sideEffects.statusMessages.isEmpty)
    }

    func testCancelAppAudioTargetResolutionClearsResolvingAndCancelsResolver() {
        let harness = makeStartHarness()
        harness.stateStore.productRealControlState.beginResolution(for: "safari")

        harness.coordinator.cancelAppAudioTargetResolution(reason: .userStopped)

        XCTAssertFalse(harness.stateStore.productRealControlState.isResolving)
        XCTAssertEqual(harness.resolver.cancelReasons, [.userStopped])
    }

    func testCancelAppAudioTargetResolutionIsNoOpWhenNotResolving() {
        let harness = makeStartHarness()

        harness.coordinator.cancelAppAudioTargetResolution(reason: .userStopped)

        XCTAssertTrue(harness.resolver.cancelReasons.isEmpty)
    }

    // MARK: - Task lifecycle

    func testCancelResolutionTaskCancelsOnlyTheOwnedTask() {
        let harness = makeStartHarness()
        // Mark resolving state; cancelResolutionTask cancels only the owned task and — unlike
        // cancelAppAudioTargetResolution — does NOT clear resolving state or cancel the resolver.
        harness.stateStore.productRealControlState.beginResolution(for: "safari")

        harness.coordinator.cancelResolutionTask()

        XCTAssertTrue(harness.stateStore.productRealControlState.isResolving)
        XCTAssertTrue(harness.resolver.cancelReasons.isEmpty)
    }

    // MARK: - Start preflight / async start body

    func testSuccessfulStartConfirmsSession() async {
        let harness = makeStartHarness()
        let app = makeApp()
        harness.context.apps = [app]
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        await waitUntil { harness.stateStore.productRealControlState.activeSessionsByAppID[app.id]?.liveSessionID != nil }

        let session = harness.stateStore.productRealControlState.activeSessionsByAppID[app.id]
        XCTAssertEqual(session?.liveSessionID, sessionID)
        XCTAssertFalse(harness.stateStore.productRealControlState.isOperationPending(for: app.id))
        XCTAssertEqual(harness.sideEffects.activeNameHistory.last, app.name)
        XCTAssertTrue(harness.sideEffects.diagnosticResults.contains { $0.outcome == .liveControlStarted })
        XCTAssertEqual(harness.sideEffects.diagnosticRunningHistory.last, false)
    }

    func testFailedStartClearsPendingAndReportsFailureAndRefreshesActiveName() async {
        let harness = makeStartHarness()
        let app = makeApp()
        harness.context.apps = [app]
        harness.liveSessionManager.configureStart(
            result: ProcessTapLiveSessionStartResult(sessionID: nil, result: makeResult(.liveControlSetupFailed))
        )

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        await waitUntil { harness.sideEffects.statusMessages.contains("Could not start live control for this app") }

        XCTAssertNil(harness.stateStore.productRealControlState.activeSessionsByAppID[app.id])
        XCTAssertFalse(harness.stateStore.productRealControlState.isOperationPending(for: app.id))
        XCTAssertEqual(harness.sideEffects.diagnosticRunningHistory.last, false)
        // The failure path clears the session and refreshes the active-name display via the injected
        // closure (routed to the stop coordinator's helper in production).
        XCTAssertGreaterThanOrEqual(harness.refreshActiveNameSpy.count, 1)
    }

    func testStaleStartResultRejectedRegistersCleanupAndRefreshesActiveName() async {
        let harness = makeStartHarness()
        let app = makeApp()
        harness.context.apps = [app]
        let orphanSessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(orphanSessionID))

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        // Supersede the in-flight request synchronously, before the queued start task runs its
        // post-await block, so the completion is recognised as stale.
        _ = harness.stateStore.productRealControlState.beginStartRequest(for: app.id)

        await waitUntil { !harness.liveSessionManager.stopSessionCalls.isEmpty }

        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.contains { $0.id == orphanSessionID })
        XCTAssertFalse(harness.stateStore.productRealControlState.isOperationPending(for: app.id))
        // The stale-rejection path drops the lingering optimistic entry and refreshes the active name.
        XCTAssertGreaterThanOrEqual(harness.refreshActiveNameSpy.count, 1)
    }

    func testDiagnosticsProgressCallbackUpdatesWhenAccepted() async {
        let harness = makeStartHarness()
        let app = makeApp()
        harness.context.apps = [app]
        harness.liveSessionManager.configureStart(result: startedResult(ProcessTapLiveSessionID()))
        harness.liveSessionManager.configureEmitDiagnostics(makeDiagnostics(callbackCount: 5))

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        await waitUntil { harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 5 } }

        XCTAssertTrue(harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 5 })
    }

    func testDiagnosticsProgressCallbackIgnoredWhenStale() async {
        let harness = makeStartHarness()
        let app = makeApp()
        harness.context.apps = [app]
        harness.liveSessionManager.configureStart(result: startedResult(ProcessTapLiveSessionID()))
        harness.liveSessionManager.configureEmitDiagnostics(makeDiagnostics(callbackCount: 7))

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        _ = harness.stateStore.productRealControlState.beginStartRequest(for: app.id) // supersede

        await waitUntil { !harness.stateStore.productRealControlState.isOperationPending(for: app.id) }

        // The superseded request's diagnostics callback must be rejected by shouldAcceptCallback.
        XCTAssertFalse(harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 7 })
    }

    func testOnStoppedRoutesThroughOnEngineStoppedCallback() async {
        let harness = makeStartHarness()
        let app = makeApp()
        harness.context.apps = [app]
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))

        // Start and let the async body confirm the session with its engine id.
        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        await waitUntil { harness.stateStore.productRealControlState.activeSessionsByAppID[app.id]?.liveSessionID == sessionID }

        // Deliver the engine stop through the captured onStopped closure (the real wiring). It must
        // route through the injected `onEngineStopped` callback rather than any direct stop reference.
        harness.liveSessionManager.emitCapturedStopped(id: sessionID, result: makeResult(.liveControlStopped), diagnostics: nil)
        await waitUntil { !harness.engineStoppedSpy.calls.isEmpty }

        XCTAssertEqual(harness.engineStoppedSpy.calls.last?.sessionID, sessionID)
        XCTAssertEqual(harness.engineStoppedSpy.calls.last?.result.outcome, .liveControlStopped)
    }

    func testCachedHelperFailureInvalidatesCachedTarget() async {
        let harness = makeStartHarness()
        let app = makeApp()
        harness.context.apps = [app]
        harness.liveSessionManager.configureStart(
            result: ProcessTapLiveSessionStartResult(sessionID: nil, result: makeResult(.liveControlSetupFailed))
        )

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app), resolutionSource: .cachedHelper)
        await waitUntil { harness.resolver.invalidatedTargetCount >= 1 }

        // A cached-helper start failure invalidates the stale cached target (the cached-helper-specific
        // step before any retry). The full two-phase resolve→retry is exercised end-to-end by
        // MixerViewModelLiveControlTests, which owns that broad fixture.
        XCTAssertGreaterThanOrEqual(harness.resolver.invalidatedTargetCount, 1)
    }

    // The cached-helper retry is no longer suppressed by other confirmed Product sessions: they run
    // concurrently with a fresh resolve/start just like with a first start. The visible process is
    // eligible in this fixture, so the fresh retry starts directly and reaches the engine a second
    // time (its own failure has no cached source, so it reports instead of retrying again).
    func testCachedHelperRetryRunsWhileAnotherProductSessionIsActive() async {
        let harness = makeStartHarness(visibleProcessEligible: true)
        let app = makeApp()
        harness.context.apps = [makeApp(id: "music", name: "Music", pid: 102), app]
        harness.context.isExperimentalRealAppControlEnabled = true
        beginConfirmedSessions(["music"], in: harness)
        // The view model derives this from the confirmed "music" session above.
        harness.context.isProcessTapLiveControlActive = true
        harness.liveSessionManager.configureStart(
            result: ProcessTapLiveSessionStartResult(sessionID: nil, result: makeResult(.liveControlSetupFailed))
        )

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app), resolutionSource: .cachedHelper)
        await waitUntil {
            harness.liveSessionManager.startSessionTargetHistory.count == 2
                && harness.sideEffects.statusMessages.contains("Could not start live control for this app")
        }

        XCTAssertEqual(harness.liveSessionManager.startSessionTargetHistory.map(\.appID), [app.id, app.id])
        XCTAssertGreaterThanOrEqual(harness.resolver.invalidatedTargetCount, 1)
        XCTAssertFalse(harness.stateStore.productRealControlState.isOperationPending(for: app.id))
        // The other app's confirmed session is untouched.
        XCTAssertNotNil(harness.stateStore.productRealControlState.activeSessionsByAppID["music"]?.liveSessionID)
    }

    // The mutually exclusive Advanced manual session still suppresses the retry (it would run a
    // helper probe alongside it): the failure is reported and nothing else starts or resolves.
    func testCachedHelperRetryIsSkippedWhileAdvancedManualLiveControlIsActive() async {
        let harness = makeStartHarness(visibleProcessEligible: true)
        let app = makeApp()
        harness.context.apps = [app]
        harness.context.isExperimentalRealAppControlEnabled = true
        harness.context.advancedManualLiveControlActive = true
        harness.context.isProcessTapLiveControlActive = true
        harness.liveSessionManager.configureStart(
            result: ProcessTapLiveSessionStartResult(sessionID: nil, result: makeResult(.liveControlSetupFailed))
        )

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app), resolutionSource: .cachedHelper)
        await waitUntil { harness.sideEffects.statusMessages.contains("Could not start live control for this app") }

        XCTAssertEqual(harness.liveSessionManager.startSessionTargetHistory.count, 1)
        XCTAssertFalse(harness.stateStore.productRealControlState.isResolving)
        XCTAssertFalse(harness.stateStore.productRealControlState.isOperationPending(for: app.id))
        XCTAssertGreaterThanOrEqual(harness.resolver.invalidatedTargetCount, 1)
    }

    // MARK: - Concurrent-session limit (start preflight)

    // Owner decision: Product Real Control has no app-count limit by default.
    func testProductDefaultHasNoConcurrentSessionLimit() {
        XCTAssertNil(AppConstants.maxConcurrentLiveSessions)
    }

    func testBlockReasonAllowsNewAppAlongsideManySessionsWithDefaultLimit() {
        let harness = makeStartHarness()
        beginConfirmedSessions(["a", "b", "c", "d", "e", "f", "g"], in: harness)

        XCTAssertNil(harness.coordinator.productSessionStartBlockReason(for: "h"))
    }

    func testBlockReasonStillEnforcesMutualExclusionWithDefaultLimit() {
        let harness = makeStartHarness()
        harness.context.isProcessTapTesting = true

        XCTAssertEqual(harness.coordinator.productSessionStartBlockReason(for: "a"), "Stop active live control first")

        harness.context.isProcessTapTesting = false
        harness.context.advancedManualLiveControlActive = true

        XCTAssertEqual(harness.coordinator.productSessionStartBlockReason(for: "a"), "Stop the active live control first")
    }

    func testInjectedCapBlocksNewAppWithConfiguredCountMessage() {
        let harness = makeStartHarness(maxConcurrentSessions: 3)
        beginConfirmedSessions(["a", "b", "c"], in: harness)

        XCTAssertEqual(
            harness.coordinator.productSessionStartBlockReason(for: "d"),
            "Real app control supports 3 apps at a time"
        )
        // An app that already owns a session is never counted against the cap.
        XCTAssertNil(harness.coordinator.productSessionStartBlockReason(for: "b"))
    }

    func testInjectedCapMessageUsesTheConfiguredValue() {
        let harness = makeStartHarness(maxConcurrentSessions: 5)
        beginConfirmedSessions(["a", "b", "c", "d"], in: harness)

        XCTAssertNil(harness.coordinator.productSessionStartBlockReason(for: "e"))

        beginConfirmedSessions(["e"], in: harness)

        XCTAssertEqual(
            harness.coordinator.productSessionStartBlockReason(for: "f"),
            "Real app control supports 5 apps at a time"
        )
    }

    // MARK: - Starvation attribution logging (diagnostics-only)

    func testAcceptedStarvationDiagnosticsStillPublishProgressUnchanged() async {
        let harness = makeStartHarness()
        let app = makeApp()
        harness.context.apps = [app]
        harness.liveSessionManager.configureStart(result: startedResult(ProcessTapLiveSessionID()))
        harness.liveSessionManager.configureEmitDiagnostics(
            makeDiagnostics(callbackCount: 9, outputStarvationCount: 1300)
        )

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        await waitUntil { harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 9 } }

        // Adding starvation-attribution logging must not change what is published: an accepted
        // diagnostics snapshot still forwards its progress exactly as before, starvation present or not.
        XCTAssertTrue(harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 9 })
    }

    func testStaleStarvationDiagnosticsNeitherPublishesNorEscalates() async {
        let harness = makeStartHarness()
        let app = makeApp()
        harness.context.apps = [app]
        harness.liveSessionManager.configureStart(result: startedResult(ProcessTapLiveSessionID()))
        harness.liveSessionManager.configureEmitDiagnostics(
            makeDiagnostics(callbackCount: 11, outputStarvationCount: 999)
        )

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        _ = harness.stateStore.productRealControlState.beginStartRequest(for: app.id) // supersede

        await waitUntil { !harness.stateStore.productRealControlState.isOperationPending(for: app.id) }

        // A superseded callback is rejected by shouldAcceptCallback *before* both the publish and the
        // attribution-log call, so nothing is published (and by the same early return nothing logs).
        XCTAssertFalse(harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 11 })
    }

    // MARK: - Live diagnostics: focused session only, and only while the display is visible
    //
    // Diagnostics are delivered through each session's captured `onDiagnostics` closure. Every
    // emission from the test enqueues its main-actor hop in order, so once a later emission is
    // observed every earlier one has already been handled; negative assertions are exact.

    func testOnlyFocusedSessionPublishesLiveDiagnostics() async {
        let harness = makeStartHarness()
        let (appA, appB) = (makeApp(id: "a", name: "Alpha", pid: 1), makeApp(id: "b", name: "Bravo", pid: 2))
        harness.context.apps = [appA, appB]
        let (sidA, sidB) = (ProcessTapLiveSessionID(), ProcessTapLiveSessionID())
        await startConfirmedDiagnosticsSession(appA, sessionID: sidA, in: harness)
        await startConfirmedDiagnosticsSession(appB, sessionID: sidB, in: harness)

        harness.liveSessionManager.emitCapturedDiagnostics(id: sidA, makeDiagnostics(callbackCount: 11))
        harness.liveSessionManager.emitCapturedDiagnostics(id: sidB, makeDiagnostics(callbackCount: 22))
        await waitUntil { harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 22 } }

        // Bravo (the newest start) owns the shared surface; Alpha's snapshot is not interleaved.
        XCTAssertFalse(harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 11 })
        XCTAssertFalse(harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 11 })
        XCTAssertTrue(harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 22 })
    }

    func testNewestStartTakesLiveDiagnosticsFocus() async {
        let harness = makeStartHarness()
        let (appA, appB) = (makeApp(id: "a", name: "Alpha", pid: 1), makeApp(id: "b", name: "Bravo", pid: 2))
        harness.context.apps = [appA, appB]
        let (sidA, sidB) = (ProcessTapLiveSessionID(), ProcessTapLiveSessionID())

        // Alone, Alpha publishes.
        await startConfirmedDiagnosticsSession(appA, sessionID: sidA, in: harness)
        harness.liveSessionManager.emitCapturedDiagnostics(id: sidA, makeDiagnostics(callbackCount: 11))
        await waitUntil { harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 11 } }

        // Once Bravo starts, it takes the focus and Alpha stops publishing.
        await startConfirmedDiagnosticsSession(appB, sessionID: sidB, in: harness)
        harness.liveSessionManager.emitCapturedDiagnostics(id: sidA, makeDiagnostics(callbackCount: 12))
        harness.liveSessionManager.emitCapturedDiagnostics(id: sidB, makeDiagnostics(callbackCount: 21))
        await waitUntil { harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 21 } }

        XCTAssertFalse(harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 12 })
    }

    func testLiveDiagnosticsFocusFallsBackToSurvivingSessionAfterFocusedSessionClears() async {
        let harness = makeStartHarness()
        let (appA, appB) = (makeApp(id: "a", name: "Alpha", pid: 1), makeApp(id: "b", name: "Bravo", pid: 2))
        harness.context.apps = [appA, appB]
        let (sidA, sidB) = (ProcessTapLiveSessionID(), ProcessTapLiveSessionID())
        await startConfirmedDiagnosticsSession(appA, sessionID: sidA, in: harness)
        await startConfirmedDiagnosticsSession(appB, sessionID: sidB, in: harness)

        // The focused session (Bravo) goes away, as its stop callback would clear it.
        harness.stateStore.productRealControlState.clearSession(for: appB.id)

        // The surviving session adopts the focus on its next accepted callback and publishes.
        harness.liveSessionManager.emitCapturedDiagnostics(id: sidA, makeDiagnostics(callbackCount: 31))
        await waitUntil { harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 31 } }
        XCTAssertTrue(harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 31 })
    }

    func testStaleCallbackCannotStealLiveDiagnosticsFocus() async {
        let harness = makeStartHarness()
        let appA = makeApp(id: "a", name: "Alpha", pid: 1)
        let appB = makeApp(id: "b", name: "Bravo", pid: 2)
        let appC = makeApp(id: "c", name: "Charlie", pid: 3)
        harness.context.apps = [appA, appB, appC]

        // Alpha's first start is superseded before it completes: rejected as stale, its orphan
        // session torn down — but that orphan's diagnostics closure is still captured by the engine.
        let staleSidA = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(staleSidA))
        harness.coordinator.startExperimentalControl(for: appA, target: makeTarget(for: appA))
        _ = harness.stateStore.productRealControlState.beginStartRequest(for: appA.id) // supersede
        await waitUntil { harness.liveSessionManager.stopSessionCalls.contains { $0.id == staleSidA } }

        // Alpha restarts (a valid newer session), then Bravo and Charlie start; Charlie is focused.
        await startConfirmedDiagnosticsSession(appA, sessionID: ProcessTapLiveSessionID(), in: harness)
        let sidB = ProcessTapLiveSessionID()
        await startConfirmedDiagnosticsSession(appB, sessionID: sidB, in: harness)
        await startConfirmedDiagnosticsSession(appC, sessionID: ProcessTapLiveSessionID(), in: harness)
        // The focused session goes away, so the focus is up for adoption.
        harness.stateStore.productRealControlState.clearSession(for: appC.id)

        // The stale orphan callback arrives first. Alpha does have a live session, so if the stale
        // callback could reach the focus logic it would take the focus and block Bravo below.
        harness.liveSessionManager.emitCapturedDiagnostics(id: staleSidA, makeDiagnostics(callbackCount: 41))
        harness.liveSessionManager.emitCapturedDiagnostics(id: sidB, makeDiagnostics(callbackCount: 42))
        await waitUntil { harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 42 } }

        XCTAssertFalse(harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 41 })
        XCTAssertFalse(harness.coordinator.hasStarvationAttributionBaseline(for: staleSidA))
    }

    func testNonFocusedSessionStillRecordsStarvationAttribution() async {
        let harness = makeStartHarness()
        let (appA, appB) = (makeApp(id: "a", name: "Alpha", pid: 1), makeApp(id: "b", name: "Bravo", pid: 2))
        harness.context.apps = [appA, appB]
        let (sidA, sidB) = (ProcessTapLiveSessionID(), ProcessTapLiveSessionID())
        await startConfirmedDiagnosticsSession(appA, sessionID: sidA, in: harness)
        await startConfirmedDiagnosticsSession(appB, sessionID: sidB, in: harness)
        XCTAssertFalse(harness.coordinator.hasStarvationAttributionBaseline(for: sidA))

        // Alpha is not focused (Bravo started later) and reports a starvation spike.
        harness.liveSessionManager.emitCapturedDiagnostics(id: sidA, makeDiagnostics(callbackCount: 51, outputStarvationCount: 1300))
        harness.liveSessionManager.emitCapturedDiagnostics(id: sidB, makeDiagnostics(callbackCount: 52))
        await waitUntil { harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 52 } }

        // Not published, but still attributed (logging is independent of the shared surface).
        XCTAssertFalse(harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 51 })
        XCTAssertTrue(harness.coordinator.hasStarvationAttributionBaseline(for: sidA))
    }

    func testHiddenDisplaySkipsLiveDiagnosticsPublishButStillRecordsAttribution() async {
        let harness = makeStartHarness()
        harness.context.isLiveDiagnosticsDisplayVisible = false
        let app = makeApp()
        harness.context.apps = [app]
        let sessionID = ProcessTapLiveSessionID()
        await startConfirmedDiagnosticsSession(app, sessionID: sessionID, in: harness)
        let progressCountAfterStart = harness.sideEffects.diagnosticProgressHistory.count

        harness.liveSessionManager.emitCapturedDiagnostics(id: sessionID, makeDiagnostics(callbackCount: 61, outputStarvationCount: 5))
        // The attribution baseline appears once the accepted callback has been handled.
        await waitUntil { harness.coordinator.hasStarvationAttributionBaseline(for: sessionID) }

        XCTAssertFalse(harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 61 })
        XCTAssertEqual(harness.sideEffects.diagnosticProgressHistory.count, progressCountAfterStart)
    }

    func testLiveDiagnosticsPublishResumesWhenDisplayBecomesVisible() async {
        let harness = makeStartHarness()
        harness.context.isLiveDiagnosticsDisplayVisible = false
        let app = makeApp()
        harness.context.apps = [app]
        let sessionID = ProcessTapLiveSessionID()
        await startConfirmedDiagnosticsSession(app, sessionID: sessionID, in: harness)

        harness.liveSessionManager.emitCapturedDiagnostics(id: sessionID, makeDiagnostics(callbackCount: 71))
        await waitUntil { harness.coordinator.hasStarvationAttributionBaseline(for: sessionID) }
        XCTAssertFalse(harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 71 })

        harness.context.isLiveDiagnosticsDisplayVisible = true
        harness.liveSessionManager.emitCapturedDiagnostics(id: sessionID, makeDiagnostics(callbackCount: 72))
        await waitUntil { harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 72 } }

        XCTAssertTrue(harness.sideEffects.diagnosticProgressHistory.contains { $0?.callbackCount == 72 })
        XCTAssertFalse(harness.sideEffects.liveDiagnosticsHistory.contains { $0?.callbackCount == 71 })
    }

    func testStartAndFailureDisplayWritesAreNotGatedWhileDisplayHidden() async {
        let harness = makeStartHarness()
        harness.context.isLiveDiagnosticsDisplayVisible = false
        let app = makeApp()
        harness.context.apps = [app]
        harness.liveSessionManager.configureStart(
            result: ProcessTapLiveSessionStartResult(sessionID: nil, result: makeResult(.liveControlSetupFailed))
        )
        let zeroProgress = ProcessTapDiagnosticProgress(callbackCount: 0, peakLevel: 0, rmsLevel: 0, audioDetected: false)

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))

        // Synchronous "Starting…" writes: result, zero progress, cleared diagnostics, running flag.
        XCTAssertEqual(harness.sideEffects.diagnosticResults.map(\.outcome), [.liveControlStarting])
        XCTAssertEqual(harness.sideEffects.diagnosticProgressHistory, [zeroProgress])
        XCTAssertEqual(harness.sideEffects.liveDiagnosticsHistory, [nil])
        XCTAssertEqual(harness.sideEffects.diagnosticRunningHistory, [true])

        await waitUntil { harness.sideEffects.statusMessages.contains("Could not start live control for this app") }

        // Post-await failure writes: final result, running cleared, diagnostics and progress cleared.
        XCTAssertEqual(harness.sideEffects.diagnosticResults.map(\.outcome), [.liveControlStarting, .liveControlSetupFailed])
        XCTAssertEqual(harness.sideEffects.diagnosticRunningHistory, [true, false])
        XCTAssertEqual(harness.sideEffects.diagnosticProgressHistory, [zeroProgress, nil])
        XCTAssertEqual(harness.sideEffects.liveDiagnosticsHistory, [nil, nil])
    }

    // MARK: - Stale-start cleanup

    func testCleanupStopsStartedSessionByItsOwnID() async {
        let harness = makeStartHarness()
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
        let harness = makeStartHarness()
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
        let harness = makeStartHarness()
        let startResult = ProcessTapLiveSessionStartResult(
            sessionID: nil,
            result: makeResult(.liveControlStarted)
        )

        await harness.coordinator.cleanupStaleProductLiveStart(startResult)

        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
    }

    // MARK: - Harness

    private struct StartHarness {
        let coordinator: ProductRealStartCoordinator
        let stateStore: ProductRealControlStateStore
        let liveSessionManager: FakeProductRealLiveSessionManager
        let settleGate: RecordingStartSettleGate
        let resolver: RecordingAppAudioTargetResolver
        // Held so the coordinator's `weak` seam references stay alive for the test's lifetime.
        let sideEffects: StubProductRealControlSideEffects
        let context: StubProductRealControlContext
        let engineStoppedSpy: EngineStoppedSpy
        let refreshActiveNameSpy: RefreshActiveNameSpy
    }

    private func makeStartHarness(
        visibleProcessEligible: Bool = false,
        maxConcurrentSessions: Int? = AppConstants.maxConcurrentLiveSessions
    ) -> StartHarness {
        let stateStore = ProductRealControlStateStore()
        let liveSessionManager = FakeProductRealLiveSessionManager()
        let settleGate = RecordingStartSettleGate()
        let resolver = RecordingAppAudioTargetResolver()
        let sideEffects = StubProductRealControlSideEffects()
        let context = StubProductRealControlContext()
        let engineStoppedSpy = EngineStoppedSpy()
        let refreshActiveNameSpy = RefreshActiveNameSpy()
        let coordinator = ProductRealStartCoordinator(
            stateStore: stateStore,
            liveSessionManager: liveSessionManager,
            appAudioTargetResolver: resolver,
            startSettleGate: settleGate,
            processTapEligibility: { _ in
                visibleProcessEligible ? .eligible : ProcessTapProcessEligibility(isEligible: false, reason: nil)
            },
            sideEffects: sideEffects,
            context: context,
            maxConcurrentSessions: maxConcurrentSessions
        )
        coordinator.setOnEngineStopped { sessionID, result, diagnostics in
            engineStoppedSpy.record(sessionID, result, diagnostics)
        }
        coordinator.setRefreshActiveName { refreshActiveNameSpy.record() }
        return StartHarness(
            coordinator: coordinator,
            stateStore: stateStore,
            liveSessionManager: liveSessionManager,
            settleGate: settleGate,
            resolver: resolver,
            sideEffects: sideEffects,
            context: context,
            engineStoppedSpy: engineStoppedSpy,
            refreshActiveNameSpy: refreshActiveNameSpy
        )
    }

    private func makeApp(id: String = "safari", name: String = "Safari", pid: Int32? = 100) -> MixerAppItem {
        MixerAppItem(id: id, name: name, icon: .systemSymbol("app"), processIdentifier: pid, volume: 50)
    }

    private func makeTarget(for app: MixerAppItem) -> ProcessTapTarget {
        ProcessTapTarget(appID: app.id, appName: app.name, processIdentifier: app.processIdentifier)
    }

    /// Seeds one confirmed (engine session id set) Product Real session per app id, directly in the
    /// shared state store, so the start preflight sees that many concurrent sessions.
    private func beginConfirmedSessions(_ appIDs: [MixerAppItem.ID], in harness: StartHarness) {
        for (index, appID) in appIDs.enumerated() {
            harness.stateStore.productRealControlState.beginSession(
                visibleAppID: appID,
                displayName: appID,
                controlledProcessIdentifier: Int32(100 + index),
                source: .directVisiblePID,
                liveSessionID: ProcessTapLiveSessionID()
            )
        }
    }

    private func startedResult(_ sessionID: ProcessTapLiveSessionID) -> ProcessTapLiveSessionStartResult {
        ProcessTapLiveSessionStartResult(sessionID: sessionID, result: makeResult(.liveControlStarted))
    }

    /// Starts `app` through the real async start body with `sessionID` as its engine session id and
    /// waits until the post-await block has confirmed it (engine id recorded, transition finished).
    private func startConfirmedDiagnosticsSession(
        _ app: MixerAppItem,
        sessionID: ProcessTapLiveSessionID,
        in harness: StartHarness
    ) async {
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))
        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        await waitUntil {
            harness.stateStore.productRealControlState.activeSessionsByAppID[app.id]?.liveSessionID == sessionID
                && !harness.stateStore.productRealControlState.isOperationPending(for: app.id)
        }
    }

    private func makeDiagnostics(
        callbackCount: Int,
        outputStarvationCount: Int = 0,
        droppedBufferCount: Int = 0,
        enqueuedBufferCount: Int = 0
    ) -> ProcessTapLiveDiagnostics {
        ProcessTapLiveDiagnostics(
            selectedGain: ProcessTapReplayGainOption(scalar: 1, label: "100%"),
            callbackCount: callbackCount,
            peakLevel: 0,
            rmsLevel: 0,
            enqueuedBufferCount: enqueuedBufferCount,
            droppedBufferCount: droppedBufferCount,
            enqueueFailureCount: 0,
            copyFailureCount: 0,
            outputStarvationCount: outputStarvationCount
        )
    }

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

/// Records the `onEngineStopped` closure invocations the facade wires from the start coordinator to
/// the stop coordinator.
@MainActor
final class EngineStoppedSpy {
    private(set) var calls: [(sessionID: ProcessTapLiveSessionID, result: ProcessTapTestResult, diagnostics: ProcessTapLiveDiagnostics?)] = []
    func record(_ sessionID: ProcessTapLiveSessionID, _ result: ProcessTapTestResult, _ diagnostics: ProcessTapLiveDiagnostics?) {
        calls.append((sessionID, result, diagnostics))
    }
}

/// Records `refreshActiveName` closure invocations from the start coordinator.
@MainActor
final class RefreshActiveNameSpy {
    private(set) var count = 0
    func record() {
        count += 1
    }
}

/// Unit tests for the pure, diagnostics-only per-session attribution rate-shaper. No CoreAudio, no
/// sleeps, no OSLog assertions — only the log/no-log decision and per-session high-water state.
final class ProductRealStarvationAttributionLogTests: XCTestCase {
    private func decide(
        _ log: inout ProductRealStarvationAttributionLog,
        _ session: ProcessTapLiveSessionID,
        starv: Int,
        drops: Int = 0,
        fail: Int = 0
    ) -> ProductRealStarvationAttributionLog.Decision? {
        log.decision(
            sessionID: session,
            outputStarvationCount: starv,
            droppedBufferCount: drops,
            totalFailureCount: fail
        )
    }

    // 1. Starv == 0 must not log.
    func testZeroDoesNotLog() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()

        XCTAssertNil(decide(&log, s, starv: 0))
        XCTAssertTrue(log.hasBaseline(for: s)) // state established, silently
    }

    // 2. The first observed nonzero Starv value logs immediately.
    func testFirstNonzeroLogs() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()

        let decision = decide(&log, s, starv: 37)
        XCTAssertEqual(decision?.starvationBucketCrossed, true)
        XCTAssertEqual(decision?.reasonLabel, "starv")
    }

    // 3 & 4. Within the first bucket (1 → 2, 1 → 99) does not log again.
    func testFurtherIncreasesWithinFirstBucketDoNotLog() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()

        XCTAssertNotNil(decide(&log, s, starv: 1))   // first nonzero logs
        XCTAssertNil(decide(&log, s, starv: 2))       // 1 → 2, same bucket 0
        XCTAssertNil(decide(&log, s, starv: 99))      // 1 → 99, still bucket 0
    }

    // 5 & 6. Crossing to 100 logs; 100 → 199 does not.
    func testCrossingToOneHundredLogsThenSameBucketDoesNot() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()
        _ = decide(&log, s, starv: 1)                 // bucket 0

        XCTAssertEqual(decide(&log, s, starv: 100)?.starvationBucketCrossed, true) // bucket 1
        XCTAssertNil(decide(&log, s, starv: 150))     // still bucket 1
        XCTAssertNil(decide(&log, s, starv: 199))     // still bucket 1
    }

    // 7. Crossing to 200 logs.
    func testCrossingToTwoHundredLogs() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()
        _ = decide(&log, s, starv: 1)
        _ = decide(&log, s, starv: 100)

        XCTAssertEqual(decide(&log, s, starv: 200)?.starvationBucketCrossed, true)
    }

    // 8. A first value of 1300 logs once (not thirteen times).
    func testFirstValueThirteenHundredLogsOnce() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()

        XCTAssertEqual(decide(&log, s, starv: 1300)?.starvationBucketCrossed, true)
        // No prior calls at 1..1299 were needed and no further Starv escalation occurs within bucket 13.
        XCTAssertNil(decide(&log, s, starv: 1300))
    }

    // 9. A later 1301 (same bucket 13) does not log.
    func testLaterSameBucketAfterSpikeDoesNotLog() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()
        _ = decide(&log, s, starv: 1300)

        XCTAssertNil(decide(&log, s, starv: 1301))
    }

    // 10. A later 1400 (bucket 14) logs.
    func testLaterHigherBucketAfterSpikeLogs() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()
        _ = decide(&log, s, starv: 1300)
        _ = decide(&log, s, starv: 1301)

        XCTAssertEqual(decide(&log, s, starv: 1400)?.starvationBucketCrossed, true)
    }

    // 11. A Drops increase logs immediately, regardless of the current Starv bucket.
    func testDropsIncreaseLogsImmediately() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()
        _ = decide(&log, s, starv: 150)               // establish bucket 1, drops high-water 0

        let decision = decide(&log, s, starv: 150, drops: 1) // same Starv bucket, drops up
        XCTAssertEqual(decision?.dropsIncreased, true)
        XCTAssertEqual(decision?.starvationBucketCrossed, false)
        XCTAssertEqual(decision?.reasonLabel, "drops")
    }

    // 12. A Fail increase logs immediately, regardless of the current Starv bucket.
    func testFailIncreaseLogsImmediately() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()
        _ = decide(&log, s, starv: 150)

        let decision = decide(&log, s, starv: 150, fail: 1)
        XCTAssertEqual(decision?.failIncreased, true)
        XCTAssertEqual(decision?.starvationBucketCrossed, false)
        XCTAssertEqual(decision?.reasonLabel, "fail")
    }

    // 13. Unchanged Drops/Fail (and unchanged Starv bucket) do not log.
    func testUnchangedDropsAndFailDoNotLog() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()
        _ = decide(&log, s, starv: 150, drops: 2, fail: 3) // logs (first nonzero starv)

        XCTAssertNil(decide(&log, s, starv: 150, drops: 2, fail: 3)) // all identical
    }

    // 14. Decreasing values do not lower the high-water marks.
    func testDecreasingValuesDoNotLowerHighWaterMarks() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()
        _ = decide(&log, s, starv: 200, drops: 5, fail: 5) // bucket 2, drops/fail HW 5

        // Lower values on every field: no log, and no backward movement of any high-water.
        XCTAssertNil(decide(&log, s, starv: 150, drops: 2, fail: 2))
        // The next genuine increases are measured against the retained high-waters, not the dips.
        XCTAssertNil(decide(&log, s, starv: 250, drops: 5, fail: 5))   // 250 still bucket 2; drops/fail == HW
        XCTAssertEqual(decide(&log, s, starv: 300, drops: 6, fail: 6)?.reasonLabel, "starv+drops+fail")
    }

    // 15. Session B remains independent of session A.
    func testSessionsAreIndependent() {
        var log = ProductRealStarvationAttributionLog()
        let a = ProcessTapLiveSessionID()
        let b = ProcessTapLiveSessionID()
        _ = decide(&log, a, starv: 1300)              // A deep in bucket 13

        // B starts from its own clean baseline and logs its own first nonzero, unaffected by A.
        XCTAssertEqual(decide(&log, b, starv: 5)?.starvationBucketCrossed, true)
        XCTAssertNil(decide(&log, a, starv: 1301))    // A unaffected by B
    }

    // 16. forget resets all baselines (Starv bucket + drops/fail high-waters) for that session.
    func testForgetResetsAllBaselinesForSession() {
        var log = ProductRealStarvationAttributionLog()
        let s = ProcessTapLiveSessionID()
        _ = decide(&log, s, starv: 1300, drops: 9, fail: 9)
        log.forget(sessionID: s)
        XCTAssertFalse(log.hasBaseline(for: s))

        // A fresh start (same fixture id here, always a new id in production) is fully clean: its first
        // nonzero Starv logs again, and drops/fail high-waters are back to zero.
        let decision = decide(&log, s, starv: 4, drops: 1, fail: 1)
        XCTAssertEqual(decision?.starvationBucketCrossed, true)
        XCTAssertEqual(decision?.dropsIncreased, true)
        XCTAssertEqual(decision?.failIncreased, true)
    }

    func testForgetUnknownSessionIsSafe() {
        var log = ProductRealStarvationAttributionLog()

        log.forget(sessionID: ProcessTapLiveSessionID())

        XCTAssertFalse(log.hasBaseline(for: ProcessTapLiveSessionID()))
    }
}
