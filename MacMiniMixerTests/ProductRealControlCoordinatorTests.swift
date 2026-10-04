import XCTest
@testable import MacMiniMixer

@MainActor
final class ProductRealControlCoordinatorTests: XCTestCase {
    func testCoordinatorConstructsWithFakes() {
        let harness = makeHarness()

        XCTAssertNotNil(harness.coordinator)
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

    // MARK: - Start↔Stop cross-edge integration (through the real facade wiring)

    func testFacadeStartOnStoppedReachesStopHandler() async {
        let harness = makeHarness(visibleProcessEligible: true)
        let app = makeApp()
        harness.context.apps = [app]
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))

        // Drive a start through the facade's public forward (→ start coordinator → engine).
        harness.coordinator.startResolvedExperimentalControl(for: app)
        await waitUntil { harness.coordinator.productRealControlState.activeSessionsByAppID[app.id]?.liveSessionID == sessionID }

        // Deliver the engine stop. The full facade wiring must route it: start coordinator's
        // `onStopped` → facade-wired `onEngineStopped` closure → stop coordinator's
        // `handleProductLiveControlStopped` → session cleared + shared display cleanup.
        harness.liveSessionManager.emitCapturedStopped(id: sessionID, result: makeResult(.liveControlStopped), diagnostics: nil)
        await waitUntil { !harness.sideEffects.stoppedDisplayCalls.isEmpty }

        XCTAssertNil(harness.coordinator.productRealControlState.activeSessionsByAppID[app.id])
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.last?.result.outcome, .liveControlStopped)
    }

    func testFacadeStopAppExitCancelsResolutionThroughStartCoordinator() {
        let harness = makeHarness()
        // A resolving app that is no longer in the running-app list.
        harness.coordinator.productRealControlState.beginResolution(for: "ghost")
        harness.context.apps = []

        harness.coordinator.stopRealControlForExitedTargetApps()

        // Stop's app-exit path → facade-wired `cancelResolution` closure →
        // start coordinator's `cancelAppAudioTargetResolution` → resolver cancel with the app-exit reason.
        XCTAssertEqual(harness.resolver.cancelReasons, [.targetExited])
        XCTAssertFalse(harness.coordinator.productRealControlState.isResolving)
    }

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

    // The engine stop-callback (`handleProductLiveControlStopped`) is now owned by
    // `ProductRealStopCoordinator`; its direct unit coverage lives in
    // `ProductRealStopCoordinatorTests`. The facade's integration with it is still exercised here by
    // `testAsyncStartOnStoppedUsesCoordinatorLocalHandler` (onStopped reaching the stop coordinator)
    // and by the forwarding tests below (`testStopProductLiveSessions*` route through it).

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

    // MARK: - Concurrent-session limit (threaded through the facade)

    // Default facade (no `maxConcurrentSessions` argument, exactly as `MixerViewModel` builds it):
    // no app-count limit. Six distinct apps are started one after another through the real start
    // path and all are confirmed at once; a per-app stop tears down only that app's session, and Stop
    // All then stops every remaining session by its own engine id.
    func testDefaultFacadeRunsManyConcurrentSessionsPerAppStopAndStopAll() async {
        let harness = makeHarness(visibleProcessEligible: true)
        let apps = (1...6).map { makeApp(id: "app\($0)", name: "App \($0)", pid: Int32(100 + $0)) }
        harness.context.apps = apps

        var sessionIDs: [ProcessTapLiveSessionID] = []
        for app in apps {
            XCTAssertNil(harness.coordinator.productSessionStartBlockReason(for: app.id))
            let sessionID = ProcessTapLiveSessionID()
            harness.liveSessionManager.configureStart(result: startedResult(sessionID))
            harness.coordinator.startResolvedExperimentalControl(for: app)
            await waitUntil {
                harness.coordinator.productRealControlState.activeSessionsByAppID[app.id]?.liveSessionID == sessionID
            }
            sessionIDs.append(sessionID)
        }

        let started = harness.coordinator.productRealControlState
        XCTAssertEqual(started.activeSessions.count, apps.count)
        XCTAssertEqual(Set(started.activeSessions.compactMap(\.liveSessionID)), Set(sessionIDs))
        XCTAssertFalse(harness.sideEffects.statusMessages.contains { $0.contains("apps at a time") })

        // Per-app stop: only the third app's session is stopped by its own id.
        let stoppedApp = apps[2]
        let stoppedID = sessionIDs[2]
        harness.coordinator.stopExperimentalControl(for: stoppedApp.id)
        await waitUntil { harness.liveSessionManager.stopSessionCalls.count == 1 }
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.first?.id, stoppedID)

        // Deliver that session's engine stop; only its app is cleared, the other five stay active.
        harness.liveSessionManager.emitCapturedStopped(id: stoppedID, result: makeResult(.liveControlStopped), diagnostics: nil)
        await waitUntil { harness.coordinator.productRealControlState.activeSessionsByAppID[stoppedApp.id] == nil }
        XCTAssertEqual(harness.coordinator.productRealControlState.activeSessions.count, apps.count - 1)

        // Stop All stops every remaining session, each by its own engine id.
        harness.coordinator.stopProductLiveSessions(reason: .userStopped)
        await waitUntil { harness.liveSessionManager.stopSessionCalls.count == apps.count }
        let stopAllIDs = harness.liveSessionManager.stopSessionCalls.dropFirst().map { $0.id }
        XCTAssertEqual(stopAllIDs.count, apps.count - 1)
        XCTAssertEqual(Set(stopAllIDs), Set(sessionIDs.filter { $0 != stoppedID }))
        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.allSatisfy { $0.reason == .userStopped })
    }

    // An explicitly injected cap still works end to end through the facade: the preflight blocks a
    // brand-new app once the configured count is reached, the row-toggle start surfaces the message
    // naming that configured count, and nothing is started for the blocked app.
    func testInjectedCapBlocksNewAppThroughFacadeWithConfiguredCountMessage() {
        let harness = makeHarness(maxConcurrentSessions: 3)
        let apps = (1...4).map { makeApp(id: "app\($0)", name: "App \($0)", pid: Int32(100 + $0)) }
        harness.context.apps = apps
        for app in apps.prefix(3) {
            harness.coordinator.productRealControlState.beginSession(
                visibleAppID: app.id, displayName: app.name,
                controlledProcessIdentifier: app.processIdentifier,
                source: .directVisiblePID, liveSessionID: ProcessTapLiveSessionID()
            )
        }
        let blockedApp = apps[3]

        XCTAssertEqual(
            harness.coordinator.productSessionStartBlockReason(for: blockedApp.id),
            "Real app control supports 3 apps at a time"
        )

        harness.coordinator.startExperimentalControl(for: blockedApp.id)

        XCTAssertEqual(harness.sideEffects.statusMessages, ["Real app control supports 3 apps at a time"])
        XCTAssertNil(harness.coordinator.productRealControlState.activeSessionsByAppID[blockedApp.id])
        XCTAssertEqual(harness.coordinator.productRealControlState.activeSessions.count, 3)
        // An app that already owns a session is never counted against the cap.
        XCTAssertNil(harness.coordinator.productSessionStartBlockReason(for: apps[0].id))
    }

    // MARK: - Queued start lane (through the facade forwards)

    // `requestAutomaticStart` queues a second app behind an in-flight start (instead of rejecting it),
    // the queue drains when that start completes, and `clearQueuedStarts` drops a still-queued entry so
    // it never starts.
    func testFacadeRequestAutomaticStartQueuesBehindInFlightStartAndClearQueuedStartsDropsIt() async {
        let harness = makeHarness(visibleProcessEligible: true)
        let apps = (1...3).map { makeApp(id: "app\($0)", name: "App \($0)", pid: Int32(100 + $0)) }
        harness.context.apps = apps
        harness.context.isExperimentalRealAppControlEnabled = true
        harness.liveSessionManager.suspendsStarts = true

        harness.coordinator.requestAutomaticStart(for: apps[0].id)
        await waitUntilDeadline { harness.liveSessionManager.pendingStartCount == 1 }
        harness.coordinator.requestAutomaticStart(for: apps[1].id)
        harness.coordinator.requestAutomaticStart(for: apps[2].id)

        // Both later requests are queued (pending rows), not rejected.
        XCTAssertEqual(harness.coordinator.productRealControlState.queuedStartAppIDs, [apps[1].id, apps[2].id])
        XCTAssertTrue(harness.coordinator.productRealControlState.isOperationPending(for: apps[1].id))
        XCTAssertTrue(harness.sideEffects.statusMessages.isEmpty)
        XCTAssertEqual(harness.liveSessionManager.startedAppIDs, [apps[0].id])

        // The third app's queued start is dropped before it can drain.
        harness.coordinator.productRealControlState.removeQueuedStart(for: apps[2].id)
        // Completing the first start drains the queue: the second app starts next.
        harness.liveSessionManager.completeNextStart(startedResult(ProcessTapLiveSessionID()))
        await waitUntilDeadline { harness.liveSessionManager.pendingStartCount == 1 && harness.liveSessionManager.startedAppIDs.count == 2 }
        XCTAssertEqual(harness.liveSessionManager.startedAppIDs, [apps[0].id, apps[1].id])

        // Queue the third app again behind the second app's in-flight start, then clear the queue.
        harness.coordinator.requestAutomaticStart(for: apps[2].id)
        XCTAssertEqual(harness.coordinator.productRealControlState.queuedStartAppIDs, [apps[2].id])
        harness.coordinator.clearQueuedStarts()
        XCTAssertTrue(harness.coordinator.productRealControlState.queuedStarts.isEmpty)
        XCTAssertFalse(harness.coordinator.productRealControlState.isOperationPending(for: apps[2].id))

        let secondID = ProcessTapLiveSessionID()
        harness.liveSessionManager.completeNextStart(startedResult(secondID))
        await waitUntilDeadline { harness.coordinator.productRealControlState.activeSessionsByAppID[apps[1].id]?.liveSessionID == secondID }

        // The cleared entry never started.
        XCTAssertEqual(harness.liveSessionManager.startedAppIDs, [apps[0].id, apps[1].id])
        XCTAssertEqual(harness.liveSessionManager.pendingStartCount, 0)
        XCTAssertNil(harness.coordinator.productRealControlState.activeSessionsByAppID[apps[2].id])
    }

    /// Deadline-bounded observable wait for the queued-lane tests, whose starts complete across the
    /// fake engine's off-main suspension: returns as soon as `condition` holds, cooperatively yielding
    /// otherwise; the deadline is a failure bound, not a sleep.
    private func waitUntilDeadline(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }

            await Task.yield()
        }
    }

    // MARK: - Hard-teardown state reset

    func testTearDownProductStateForHardStopClearsAllProductState() {
        let harness = makeHarness()
        let (appA, appB, _, _) = makeTwoConfirmedSessions(harness)
        let reqID = harness.coordinator.productRealControlState.beginStartRequest(for: appA.id)
        harness.coordinator.productRealControlState.beginResolution(for: "resolving-app")
        harness.coordinator.productRealControlState.beginOperation(for: appB.id)
        XCTAssertFalse(harness.coordinator.productRealControlState.activeVisibleAppIDs.isEmpty)

        harness.coordinator.tearDownProductStateForHardStop()

        let state = harness.coordinator.productRealControlState
        // Sessions, start requests, resolutions, and pending operations are all cleared.
        XCTAssertTrue(state.activeVisibleAppIDs.isEmpty)
        XCTAssertFalse(state.hasConfirmedLiveSession)
        XCTAssertFalse(state.isCurrentStartRequest(reqID, for: appA.id))
        XCTAssertTrue(state.resolvingAppIDs.isEmpty)
        XCTAssertFalse(state.isOperationPending(for: appA.id))
        XCTAssertFalse(state.isOperationPending(for: appB.id))
    }

    func testTearDownProductStateForHardStopClearsActiveName() {
        let harness = makeHarness()
        _ = makeTwoConfirmedSessions(harness)

        harness.coordinator.tearDownProductStateForHardStop()

        // The shared active-name display is reset to nil, exactly as the old VM block did.
        XCTAssertEqual(harness.sideEffects.activeNameHistory.last, .some(nil))
    }

    func testTearDownProductStateForHardStopDoesNotCallEngineStopSession() async {
        let harness = makeHarness()
        _ = makeTwoConfirmedSessions(harness)

        harness.coordinator.tearDownProductStateForHardStop()
        await Task.yield()

        // This is a pure state reset; the engine hard stop stays in the VM's teardown flow.
        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
    }

    func testTearDownProductStateForHardStopDoesNotTouchAdvancedManualOrUnrelatedContext() {
        let harness = makeHarness()
        _ = makeTwoConfirmedSessions(harness)
        harness.context.advancedManualLiveControlActive = true
        harness.context.isProcessTapTesting = true

        harness.coordinator.tearDownProductStateForHardStop()

        // The Product Real state reset leaves advanced-manual and unrelated subsystem context alone.
        XCTAssertTrue(harness.context.advancedManualLiveControlActive)
        XCTAssertTrue(harness.context.isProcessTapTesting)
        XCTAssertTrue(harness.resolver.cancelReasons.isEmpty)
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

    private func makeHarness(
        visibleProcessEligible: Bool = false,
        maxConcurrentSessions: Int? = AppConstants.maxConcurrentLiveSessions
    ) -> Harness {
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
            context: context,
            maxConcurrentSessions: maxConcurrentSessions
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

final class FakeProductRealLiveSessionManager: ProcessTapLiveControlling & ProcessTapLiveSessionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStopSessionCalls: [(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason)] = []
    private var configuredStartResult: ProcessTapLiveSessionStartResult?
    private var diagnosticsToEmit: ProcessTapLiveDiagnostics?
    private var stoppedToEmit: (id: ProcessTapLiveSessionID?, result: ProcessTapTestResult, diagnostics: ProcessTapLiveDiagnostics?)?
    private var capturedOnStopped: (@Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void)?
    private var recordedStartSessionTargets: [ProcessTapTarget] = []
    private var capturedOnDiagnosticsBySessionID: [ProcessTapLiveSessionID: @Sendable (ProcessTapLiveSessionID, ProcessTapLiveDiagnostics) -> Void] = [:]

    var stopSessionCalls: [(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason)] {
        lock.withLock { recordedStopSessionCalls }
    }

    /// Delivers a diagnostics snapshot through the `onDiagnostics` closure captured for session `id`
    /// (the real per-session wiring the start coordinator installs), so a test can drive each of
    /// several concurrent sessions' diagnostics after their starts have confirmed. No-op for an
    /// unknown id.
    func emitCapturedDiagnostics(id: ProcessTapLiveSessionID, _ diagnostics: ProcessTapLiveDiagnostics) {
        let onDiagnostics = lock.withLock { capturedOnDiagnosticsBySessionID[id] }
        onDiagnostics?(id, diagnostics)
    }

    /// Every target `startSession` was called with, in call order (one entry per engine start).
    var startSessionTargetHistory: [ProcessTapTarget] {
        lock.withLock { recordedStartSessionTargets }
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
        if let suspendedResult = await recordStartAndSuspendIfConfigured(target: target, gain: gain, onStopped: onStopped) {
            return suspendedResult
        }
        let (result, diagnostics, stopped) = lock.withLock {
            capturedOnStopped = onStopped
            return (configuredStartResult, diagnosticsToEmit, stoppedToEmit)
        }
        let startResult = result ?? notActiveStartResult
        let callbackSessionID = startResult.sessionID ?? ProcessTapLiveSessionID()
        lock.withLock { recordedStartSessionTargets.append(target); capturedOnDiagnosticsBySessionID[callbackSessionID] = onDiagnostics }
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

    // MARK: Suspended-start mode (queued start-lane tests)
    //
    // Off by default, so existing tests keep the immediate-return behavior. Every `startSession` call
    // is recorded (target, gain, and how many `stopSession` calls preceded it). With `suspendsStarts`
    // on, `startSession` parks until the test resumes it with `completeNextStart(_:)` (FIFO). The
    // continuation is registered in the same lock as the record, so a test that waits on
    // `startCalls`/`pendingStartCount` can always complete the start it observed.

    private var suspendsStartsStorage = false
    private var pendingStartContinuations: [CheckedContinuation<ProcessTapLiveSessionStartResult, Never>] = []
    private var recordedStartCalls: [(target: ProcessTapTarget, gain: ProcessTapReplayGainOption, priorStopSessionCount: Int)] = []

    var suspendsStarts: Bool {
        get { lock.withLock { suspendsStartsStorage } }
        set { lock.withLock { suspendsStartsStorage = newValue } }
    }

    var pendingStartCount: Int {
        lock.withLock { pendingStartContinuations.count }
    }

    var startCalls: [(target: ProcessTapTarget, gain: ProcessTapReplayGainOption, priorStopSessionCount: Int)] {
        lock.withLock { recordedStartCalls }
    }

    var startedAppIDs: [MixerAppItem.ID] {
        startCalls.map { $0.target.appID }
    }

    /// Resumes the oldest suspended start with `result`. No-op when no start is suspended.
    func completeNextStart(_ result: ProcessTapLiveSessionStartResult) {
        let continuation = lock.withLock { () -> CheckedContinuation<ProcessTapLiveSessionStartResult, Never>? in
            guard !pendingStartContinuations.isEmpty else {
                return nil
            }
            return pendingStartContinuations.removeFirst()
        }
        continuation?.resume(returning: result)
    }

    /// Records the start; in suspended mode parks it until `completeNextStart(_:)` and returns that
    /// result (capturing `onStopped` like an immediate start). Returns nil in the default mode.
    private func recordStartAndSuspendIfConfigured(
        target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onStopped: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapLiveSessionStartResult? {
        let suspends = lock.withLock { suspendsStartsStorage }
        guard suspends else {
            lock.withLock {
                recordedStartCalls.append((target: target, gain: gain, priorStopSessionCount: recordedStopSessionCalls.count))
            }
            return nil
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ProcessTapLiveSessionStartResult, Never>) in
            lock.withLock {
                pendingStartContinuations.append(continuation)
                recordedStartCalls.append((target: target, gain: gain, priorStopSessionCount: recordedStopSessionCalls.count))
            }
        }
        lock.withLock { capturedOnStopped = onStopped }
        return result
    }
}

final class StubProductRealControlSideEffects: ProductRealControlSideEffects {
    private(set) var statusMessages: [String] = []
    private(set) var activeNameHistory: [String?] = []
    private(set) var diagnosticResults: [ProcessTapTestResult] = []
    private(set) var diagnosticProgressHistory: [ProcessTapDiagnosticProgress?] = []
    private(set) var diagnosticRunningHistory: [Bool] = []
    private(set) var stoppedDisplayCalls: [(result: ProcessTapTestResult, diagnostics: ProcessTapLiveDiagnostics?)] = []
    private(set) var liveDiagnosticsHistory: [ProcessTapLiveDiagnostics?] = []

    func showProductRealStatus(_ text: String, style: MixerStatusMessage.Style, action: MixerStatusMessage.Action?) {
        statusMessages.append(text)
    }
    func setActiveLiveControlAppName(_ name: String?) {
        activeNameHistory.append(name)
    }
    func setProcessTapLiveDiagnostics(_ diagnostics: ProcessTapLiveDiagnostics?) {
        liveDiagnosticsHistory.append(diagnostics)
    }
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

final class StubProductRealControlContext: ProductRealControlContext {
    var apps: [MixerAppItem] = []
    var isExperimentalRealAppControlEnabled = false
    var advancedManualLiveControlActive = false
    var isTwoAppReadinessRunning = false
    var isProcessTapTesting = false
    var isHelperBusy = false
    var isAppAudioTargetResolving = false
    var isProcessTapLiveControlActive = false
    var processTapLiveDiagnostics: ProcessTapLiveDiagnostics?
    /// Visible by default so coordinator tests observe product live-diagnostics publishing unless a
    /// test hides the display explicitly.
    var isLiveDiagnosticsDisplayVisible = true
}

final class RecordingAppAudioTargetResolver: AppAudioTargetResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCancelReasons: [ProcessTapCandidateProbeStopReason] = []
    private var recordedInvalidatedTargetCount = 0

    var cancelReasons: [ProcessTapCandidateProbeStopReason] {
        lock.withLock { recordedCancelReasons }
    }

    var invalidatedTargetCount: Int {
        lock.withLock { recordedInvalidatedTargetCount }
    }

    func resolveTarget(
        for request: AppAudioTargetRequest,
        allowsCachedLookup: Bool,
        onProgress: @escaping @Sendable (AppAudioResolutionProgress) -> Void
    ) async -> AppAudioTargetResolutionResult {
        let suspends = lock.withLock { suspendsResolutionStorage }
        guard suspends else {
            lock.withLock { recordedResolveRequests.append(request) }
            return .cancelled
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<AppAudioTargetResolutionResult, Never>) in
            lock.withLock {
                pendingResolutionContinuations.append(continuation)
                recordedResolveRequests.append(request)
            }
        }
    }

    func cancelCurrentResolution(reason: ProcessTapCandidateProbeStopReason) {
        lock.withLock { recordedCancelReasons.append(reason) }
    }

    func invalidateCachedTarget(for request: AppAudioTargetRequest) {
        lock.withLock { recordedInvalidatedTargetCount += 1 }
    }
    func invalidateAllCachedTargets() {}

    // MARK: Suspended-resolution mode (queued start-lane tests)
    //
    // Off by default: `resolveTarget` records the request and returns `.cancelled` immediately, as
    // before. With `suspendsResolution` on, it parks until the test resumes it with `completeNext(_:)`
    // (FIFO); the continuation is registered in the same lock as the record, so a test that waits on
    // `resolveRequests`/`pendingResolutionCount` can always complete the resolution it observed. Like
    // the real resolver's in-flight probe, a cancelled resolution keeps running until completed.

    private var suspendsResolutionStorage = false
    private var pendingResolutionContinuations: [CheckedContinuation<AppAudioTargetResolutionResult, Never>] = []
    private var recordedResolveRequests: [AppAudioTargetRequest] = []

    var suspendsResolution: Bool {
        get { lock.withLock { suspendsResolutionStorage } }
        set { lock.withLock { suspendsResolutionStorage = newValue } }
    }

    var resolveRequests: [AppAudioTargetRequest] {
        lock.withLock { recordedResolveRequests }
    }

    var pendingResolutionCount: Int {
        lock.withLock { pendingResolutionContinuations.count }
    }

    /// Resumes the oldest suspended resolution with `result`. No-op when none is suspended.
    func completeNext(_ result: AppAudioTargetResolutionResult) {
        let continuation = lock.withLock { () -> CheckedContinuation<AppAudioTargetResolutionResult, Never>? in
            guard !pendingResolutionContinuations.isEmpty else {
                return nil
            }
            return pendingResolutionContinuations.removeFirst()
        }
        continuation?.resume(returning: result)
    }
}

/// Records `registerStop` calls so stop-path tests can assert teardown was tracked with the settle
/// gate. Delegates behavior to a real gate with a zero settle delay and a no-op sleeper (no real
/// sleeps), so `waitForReadyToStart` still awaits registered stop tasks exactly as production does.
final class RecordingStartSettleGate: ProductRealStartSettling, @unchecked Sendable {
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
