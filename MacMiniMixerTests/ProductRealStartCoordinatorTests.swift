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

    // MARK: - Multi-process targets (HAL process-object matching)

    // Chrome-like app: the visible main process is eligible, but the audio is rendered by a helper
    // child. The start widens the visible target to the matched helper — one session, one tap over
    // both processes — without entering helper resolution.
    func testEligibleChromeLikeAppStartsOneSessionOverMainAndHelperProcesses() async {
        let harness = makeStartHarness(visibleProcessEligible: true)
        let chrome = makeApp(id: "bundle:com.google.Chrome", name: "Google Chrome", pid: 100)
        harness.context.apps = [chrome]
        harness.resolver.matchedAudioProcessIdentifiersByAppID = [chrome.id: [300, 100]]
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))

        harness.coordinator.startResolvedExperimentalControl(for: chrome)
        await waitUntil {
            harness.stateStore.productRealControlState.activeSessionsByAppID[chrome.id]?.liveSessionID == sessionID
        }

        XCTAssertEqual(
            harness.liveSessionManager.startSessionTargetHistory,
            [
                ProcessTapTarget(
                    appID: chrome.id,
                    appName: chrome.name,
                    processIdentifier: 100,
                    additionalProcessIdentifiers: [300]
                )
            ]
        )
        let session = harness.stateStore.productRealControlState.activeSessionsByAppID[chrome.id]
        XCTAssertEqual(session?.controlledProcessIdentifier, 100)
        XCTAssertEqual(session?.controlledProcessIdentifiers, [100, 300])
        XCTAssertEqual(session?.source, .matchedAudioProcesses)
        XCTAssertFalse(harness.stateStore.productRealControlState.isResolving)
        XCTAssertTrue(harness.resolver.resolveRequests.isEmpty)
    }

    // Without any matched process the eligible direct start is the classic single-process target.
    func testEligibleAppWithoutMatchedProcessesKeepsSingleProcessTarget() async {
        let harness = makeStartHarness(visibleProcessEligible: true)
        let music = makeApp(id: "bundle:com.apple.Music", name: "Music", pid: 102)
        harness.context.apps = [music]
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))

        harness.coordinator.startResolvedExperimentalControl(for: music)
        await waitUntil {
            harness.stateStore.productRealControlState.activeSessionsByAppID[music.id]?.liveSessionID == sessionID
        }

        XCTAssertEqual(harness.liveSessionManager.startSessionTargetHistory, [makeTarget(for: music)])
        XCTAssertEqual(
            harness.stateStore.productRealControlState.activeSessionsByAppID[music.id]?.source,
            .directVisiblePID
        )
    }

    // Row toggle (Safari-like): the visible process is not a Core Audio client, but a matched WebKit
    // process is, so the toggle starts directly over the matched processes instead of failing.
    // (The test runner's own pid stands in for the app so the toggle's NSRunningApplication check passes.)
    func testToggleStartUsesMatchedProcessesWhenVisibleProcessIsNotEligible() async {
        let harness = makeStartHarness()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let safari = makeApp(id: "bundle:com.apple.Safari", name: "Safari", pid: ownPID)
        harness.context.apps = [safari]
        harness.resolver.matchedAudioProcessIdentifiersByAppID = [safari.id: [500]]
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))

        harness.coordinator.startExperimentalControl(for: safari.id)
        await waitUntil {
            harness.stateStore.productRealControlState.activeSessionsByAppID[safari.id]?.liveSessionID == sessionID
        }

        XCTAssertEqual(
            harness.liveSessionManager.startSessionTargetHistory,
            [ProcessTapTarget(appID: safari.id, appName: "Safari", processIdentifier: ownPID, additionalProcessIdentifiers: [500])]
        )
        XCTAssertTrue(harness.resolver.resolveRequests.isEmpty)
    }

    // Row toggle with nothing matched and an ineligible visible process: a direct start could only
    // fail, so the toggle goes through resolution (helper probe / "play audio first") instead.
    func testToggleStartWithoutMatchAndIneligibleVisibleProcessResolves() async {
        let harness = makeStartHarness()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let discord = makeApp(id: "bundle:com.hnc.Discord", name: "Discord", pid: ownPID)
        harness.context.apps = [discord]

        harness.coordinator.startExperimentalControl(for: discord.id)

        XCTAssertTrue(harness.stateStore.productRealControlState.isResolving(appID: discord.id))
        await waitUntil { harness.resolver.resolveRequests.count == 1 }
        XCTAssertEqual(harness.resolver.resolveRequests.first?.appID, discord.id)
        XCTAssertTrue(harness.liveSessionManager.startSessionTargetHistory.isEmpty)
        XCTAssertTrue(harness.sideEffects.statusMessages.isEmpty)
    }

    // The browser-keyword gate no longer rejects non-browser apps up front: an ineligible Discord-like
    // row enters resolution, where the resolver matches its helpers (or asks to play audio first).
    func testIneligibleNonBrowserAppEntersResolutionInsteadOfBeingRejected() async {
        let harness = makeStartHarness()
        let discord = makeApp(id: "bundle:com.hnc.Discord", name: "Discord", pid: 100)
        harness.context.apps = [discord]

        harness.coordinator.startResolvedExperimentalControl(for: discord)

        XCTAssertTrue(harness.stateStore.productRealControlState.isResolving(appID: discord.id))
        XCTAssertFalse(harness.sideEffects.statusMessages.contains("This app is not available for real app control"))
        await waitUntil { harness.resolver.resolveRequests.count == 1 }
        XCTAssertEqual(harness.resolver.resolveRequests.first?.appID, discord.id)
    }

    // A resolved multi-process target starts as one session that records every tapped process.
    func testResolvedMatchedTargetStartsWithAllProcesses() {
        let harness = makeStartHarness()
        let safari = makeApp(id: "bundle:com.apple.Safari", name: "Safari", pid: 100)
        harness.context.apps = [safari]
        harness.stateStore.productRealControlState.beginResolution(for: safari.id)
        let target = ProcessTapTarget(appID: safari.id, appName: safari.name, processIdentifier: 100, additionalProcessIdentifiers: [500, 501])

        harness.coordinator.handleAppAudioTargetResolution(
            .resolved(ResolvedAppAudioTarget(
                visibleAppID: safari.id,
                visibleAppName: safari.name,
                target: target,
                kind: .audioProcessGroup,
                source: .matchedAudioProcesses
            )),
            for: safari.id
        )

        let session = harness.stateStore.productRealControlState.activeSessionsByAppID[safari.id]
        XCTAssertEqual(session?.source, .matchedAudioProcesses)
        XCTAssertEqual(session?.controlledProcessIdentifiers, [100, 500, 501])
    }

    // No double tap: processes another app's session already taps are left out of a new session.
    func testStartSkipsProcessesAlreadyControlledByAnotherSession() async {
        let harness = makeStartHarness(visibleProcessEligible: true)
        let chrome = makeApp(id: "bundle:com.google.Chrome", name: "Google Chrome", pid: 100)
        harness.context.apps = [chrome]
        harness.stateStore.productRealControlState.beginSession(
            visibleAppID: "bundle:com.google.Chrome.canary",
            displayName: "Google Chrome Canary",
            controlledProcessIdentifier: 200,
            additionalControlledProcessIdentifiers: [300],
            source: .matchedAudioProcesses,
            liveSessionID: ProcessTapLiveSessionID()
        )
        harness.resolver.matchedAudioProcessIdentifiersByAppID = [chrome.id: [300, 301, 200, 100]]
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))

        harness.coordinator.startResolvedExperimentalControl(for: chrome)
        await waitUntil {
            harness.stateStore.productRealControlState.activeSessionsByAppID[chrome.id]?.liveSessionID == sessionID
        }

        XCTAssertEqual(
            harness.liveSessionManager.startSessionTargetHistory,
            [ProcessTapTarget(appID: chrome.id, appName: chrome.name, processIdentifier: 100, additionalProcessIdentifiers: [301])]
        )
        XCTAssertEqual(
            harness.stateStore.productRealControlState.activeSessionsByAppID[chrome.id]?.controlledProcessIdentifiers,
            [100, 301]
        )
        // The other session is untouched.
        XCTAssertEqual(
            harness.stateStore.productRealControlState.activeSessionsByAppID["bundle:com.google.Chrome.canary"]?.controlledProcessIdentifiers,
            [200, 300]
        )
    }

    // Every process of the new target is already tapped by another session: nothing starts.
    func testStartIsRejectedWhenEveryProcessIsControlledByAnotherSession() {
        let harness = makeStartHarness()
        let app = makeApp(id: "child", name: "Child App", pid: 100)
        harness.context.apps = [app]
        harness.stateStore.productRealControlState.beginSession(
            visibleAppID: "parent",
            displayName: "Parent App",
            controlledProcessIdentifier: 90,
            additionalControlledProcessIdentifiers: [100],
            source: .matchedAudioProcesses,
            liveSessionID: ProcessTapLiveSessionID()
        )

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))

        XCTAssertEqual(harness.sideEffects.statusMessages, ["This app's audio is already under real control in another row"])
        XCTAssertNil(harness.stateStore.productRealControlState.activeSessionsByAppID[app.id])
        XCTAssertFalse(harness.stateStore.productRealControlState.isOperationPending(for: app.id))
        XCTAssertFalse(harness.coordinator.isStartLaneBusy)
        XCTAssertTrue(harness.liveSessionManager.startSessionTargetHistory.isEmpty)
    }

    // An app's own earlier session never excludes its own processes (restart keeps the full target).
    func testOwnExistingSessionDoesNotExcludeItsProcesses() async {
        let harness = makeStartHarness(visibleProcessEligible: true)
        let chrome = makeApp(id: "bundle:com.google.Chrome", name: "Google Chrome", pid: 100)
        harness.context.apps = [chrome]
        harness.stateStore.productRealControlState.beginSession(
            visibleAppID: chrome.id,
            displayName: chrome.name,
            controlledProcessIdentifier: 100,
            additionalControlledProcessIdentifiers: [300],
            source: .matchedAudioProcesses
        )
        harness.resolver.matchedAudioProcessIdentifiersByAppID = [chrome.id: [300, 100]]
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))

        harness.coordinator.startResolvedExperimentalControl(for: chrome)
        await waitUntil {
            harness.stateStore.productRealControlState.activeSessionsByAppID[chrome.id]?.liveSessionID == sessionID
        }

        XCTAssertEqual(harness.liveSessionManager.startSessionTargetHistory.first?.allProcessIdentifiers, [100, 300])
    }

    // The process matcher is told about every OTHER current row (pid + bundle id from a `bundle:` id,
    // nil otherwise), so it can keep e.g. a Safari web app's processes out of the Safari row.
    func testDirectStartPassesTheOtherRunningAppsToTheProcessMatcher() async {
        let harness = makeStartHarness(visibleProcessEligible: true)
        let safari = makeApp(id: "bundle:com.apple.Safari", name: "Safari", pid: 100)
        let webApp = makeApp(id: "bundle:com.apple.Safari.WebApp.7F3A2B10", name: "YouTube", pid: 200)
        let other = makeApp(id: "executable:/Applications/Other.app/Contents/MacOS/Other", name: "Other", pid: 300)
        harness.context.apps = [safari, webApp, other]
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))

        harness.coordinator.startResolvedExperimentalControl(for: safari)
        await waitUntil {
            harness.stateStore.productRealControlState.activeSessionsByAppID[safari.id]?.liveSessionID == sessionID
        }

        XCTAssertEqual(harness.resolver.matchRequests.map(\.appID), [safari.id])
        XCTAssertEqual(
            harness.resolver.matchRequests.first?.otherRunningApps,
            [
                AppAudioTargetRequest.OtherRunningApp(processIdentifier: 200, bundleIdentifier: "com.apple.Safari.WebApp.7F3A2B10"),
                AppAudioTargetRequest.OtherRunningApp(processIdentifier: 300, bundleIdentifier: nil)
            ]
        )
    }

    // The resolution path (visible process not eligible) carries the same other-row list.
    func testResolutionRequestCarriesTheOtherRunningApps() async {
        let harness = makeStartHarness()
        let safari = makeApp(id: "bundle:com.apple.Safari", name: "Safari", pid: 100)
        let webApp = makeApp(id: "bundle:com.apple.Safari.WebApp.7F3A2B10", name: "YouTube", pid: 200)
        harness.context.apps = [webApp, safari]

        harness.coordinator.startResolvedExperimentalControl(for: safari)
        await waitUntil { harness.resolver.resolveRequests.count == 1 }

        XCTAssertEqual(harness.resolver.resolveRequests.first?.appID, safari.id)
        XCTAssertEqual(
            harness.resolver.resolveRequests.first?.otherRunningApps,
            [AppAudioTargetRequest.OtherRunningApp(processIdentifier: 200, bundleIdentifier: "com.apple.Safari.WebApp.7F3A2B10")]
        )
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
    /// shared state store, so the start preflight sees that many concurrent sessions. The seeded
    /// controlled pids (10000+) never collide with the fixture apps' pids, so the start path's
    /// "never tap a process another session already taps" exclusion leaves the started app alone.
    private func beginConfirmedSessions(_ appIDs: [MixerAppItem.ID], in harness: StartHarness) {
        for (index, appID) in appIDs.enumerated() {
            harness.stateStore.productRealControlState.beginSession(
                visibleAppID: appID,
                displayName: appID,
                controlledProcessIdentifier: Int32(10_000 + index),
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

/// Queued Product Real start lane (single FIFO): at most one helper resolution or product start is
/// physically in flight, and a start requested meanwhile is queued instead of rejected, then drained
/// with a fresh preflight when the lane frees. Deterministic: the fake engine and resolver suspend
/// until the test completes them, and every wait is on observable state (deadline-bounded, no sleeps).
@MainActor
final class ProductRealStartLaneTests: XCTestCase {
    // MARK: - Queued instead of rejected

    func testToggleWhileResolutionInFlightIsQueuedNotRejected() async {
        let safari = makeApp("safari", "Safari", pid: 100)
        let music = makeApp("music", "Music", pid: 101)
        let harness = makeLaneHarness(apps: [safari, music], eligiblePIDs: [101])

        harness.coordinator.requestAutomaticStart(for: safari.id)
        await waitFor { harness.resolver.pendingResolutionCount == 1 }
        XCTAssertTrue(laneState(harness).isResolving(appID: safari.id))
        XCTAssertTrue(harness.coordinator.isStartLaneBusy)

        // Row toggle for another app while the helper probe runs (the view model reports resolving):
        // queued and shown pending, instead of "Process Tap is already busy".
        harness.context.isAppAudioTargetResolving = true
        harness.coordinator.startExperimentalControl(for: music.id)

        XCTAssertEqual(laneState(harness).queuedStarts, [ProductRealQueuedStart(appID: music.id, origin: .toggle)])
        XCTAssertTrue(laneState(harness).isOperationPending(for: music.id))
        XCTAssertTrue(harness.sideEffects.statusMessages.isEmpty)
        XCTAssertTrue(harness.liveSessionManager.startCalls.isEmpty)

        // Finish the resolution. Advanced manual control became active meanwhile, so the drained toggle
        // re-runs its preflight and is dropped with that block's message (no in-flight work is left).
        harness.context.isAppAudioTargetResolving = false
        harness.context.advancedManualLiveControlActive = true
        harness.resolver.completeNext(.unavailable("No audio helper found"))
        await waitFor { harness.sideEffects.statusMessages.contains("Stop the active live control first") }

        XCTAssertEqual(harness.sideEffects.statusMessages, ["No audio helper found", "Stop the active live control first"])
        XCTAssertTrue(laneState(harness).queuedStarts.isEmpty)
        XCTAssertFalse(laneState(harness).isOperationPending(for: music.id))
        XCTAssertFalse(harness.coordinator.isStartLaneBusy)
        XCTAssertTrue(harness.liveSessionManager.startCalls.isEmpty)
    }

    func testAutomaticStartWhileProductStartInFlightIsQueuedNotRejected() async {
        let music = makeApp("music", "Music", pid: 101)
        let notes = makeApp("notes", "Notes", pid: 102)
        let harness = makeLaneHarness(apps: [music, notes], eligiblePIDs: [101, 102])

        harness.coordinator.requestAutomaticStart(for: music.id)
        await waitForPendingStart(harness, startCount: 1)
        // The view model reports its shared "running" flag while a product start is in flight.
        harness.context.isProcessTapTesting = true

        harness.coordinator.requestAutomaticStart(for: notes.id)

        XCTAssertEqual(laneState(harness).queuedStartAppIDs, [notes.id])
        XCTAssertTrue(laneState(harness).isOperationPending(for: notes.id))
        XCTAssertFalse(harness.sideEffects.statusMessages.contains("Stop active live control first"))
        XCTAssertTrue(harness.sideEffects.statusMessages.isEmpty)
        XCTAssertEqual(harness.liveSessionManager.startedAppIDs, [music.id])

        // In production the post-await block clears the running flag before it drains the queue.
        harness.context.isProcessTapTesting = false
        await completeStart(harness, appID: music.id)
        await waitForPendingStart(harness, startCount: 2)

        XCTAssertEqual(harness.liveSessionManager.startedAppIDs, [music.id, notes.id])
        XCTAssertTrue(laneState(harness).queuedStarts.isEmpty)
        await completeStart(harness, appID: notes.id)
        XCTAssertNotNil(laneState(harness).activeSessionsByAppID[music.id]?.liveSessionID)
    }

    // MARK: - Drain points

    func testQueuedStartRunsAfterResolutionCompletesUnavailable() async {
        let safari = makeApp("safari", "Safari", pid: 100)
        let music = makeApp("music", "Music", pid: 101)
        let harness = makeLaneHarness(apps: [safari, music], eligiblePIDs: [101])

        harness.coordinator.requestAutomaticStart(for: safari.id)
        await waitFor { harness.resolver.pendingResolutionCount == 1 }
        harness.coordinator.requestAutomaticStart(for: music.id)
        XCTAssertEqual(laneState(harness).queuedStartAppIDs, [music.id])
        XCTAssertTrue(harness.liveSessionManager.startCalls.isEmpty)

        harness.resolver.completeNext(.unavailable("No audio helper found"))
        await waitForPendingStart(harness, startCount: 1)

        XCTAssertEqual(harness.liveSessionManager.startedAppIDs, [music.id])
        XCTAssertEqual(harness.sideEffects.statusMessages, ["No audio helper found"])
        XCTAssertFalse(laneState(harness).isResolving)
        await completeStart(harness, appID: music.id)
    }

    func testQueuedStartWaitsForResolvedHelperStartToFinish() async {
        let safari = makeApp("safari", "Safari", pid: 100)
        let music = makeApp("music", "Music", pid: 101)
        let harness = makeLaneHarness(apps: [safari, music], eligiblePIDs: [101])

        harness.coordinator.requestAutomaticStart(for: safari.id)
        await waitFor { harness.resolver.pendingResolutionCount == 1 }
        harness.coordinator.requestAutomaticStart(for: music.id)

        harness.resolver.completeNext(.resolved(helperTarget(for: safari, pid: 300, source: .discoveredHelper)))
        await waitForPendingStart(harness, startCount: 1)

        // The resolved helper start took the lane straight from the resolution: music keeps waiting.
        XCTAssertEqual(harness.liveSessionManager.startCalls.first?.target.processIdentifier, 300)
        XCTAssertEqual(laneState(harness).activeSessionsByAppID[safari.id]?.source, .discoveredHelper)
        XCTAssertEqual(laneState(harness).queuedStartAppIDs, [music.id])
        XCTAssertTrue(harness.coordinator.isStartLaneBusy)

        await completeStart(harness, appID: safari.id)
        await waitForPendingStart(harness, startCount: 2)

        XCTAssertEqual(harness.liveSessionManager.startCalls.last?.target.appID, music.id)
        XCTAssertTrue(laneState(harness).queuedStarts.isEmpty)
        await completeStart(harness, appID: music.id)
    }

    func testQueuedStartsDrainInFIFOOrderOneAtATime() async {
        let apps = [
            makeApp("music", "Music", pid: 101),
            makeApp("notes", "Notes", pid: 102),
            makeApp("mail", "Mail", pid: 103),
            makeApp("maps", "Maps", pid: 104)
        ]
        let harness = makeLaneHarness(apps: apps, eligiblePIDs: [101, 102, 103, 104])

        harness.coordinator.requestAutomaticStart(for: apps[0].id)
        await waitForPendingStart(harness, startCount: 1)
        for app in apps.dropFirst() {
            harness.coordinator.requestAutomaticStart(for: app.id)
        }
        XCTAssertEqual(laneState(harness).queuedStartAppIDs, ["notes", "mail", "maps"])

        for (index, app) in apps.enumerated() {
            // Exactly one start is in flight at a time, and it is the oldest request.
            XCTAssertEqual(harness.liveSessionManager.startedAppIDs, apps.prefix(index + 1).map(\.id))
            XCTAssertEqual(harness.liveSessionManager.pendingStartCount, 1)
            XCTAssertEqual(laneState(harness).queuedStartAppIDs, apps.dropFirst(index + 1).map(\.id))

            await completeStart(harness, appID: app.id)
            if index + 1 < apps.count {
                await waitForPendingStart(harness, startCount: index + 2)
            }
        }

        XCTAssertEqual(harness.liveSessionManager.startedAppIDs, ["music", "notes", "mail", "maps"])
        XCTAssertEqual(laneState(harness).activeSessions.filter { $0.liveSessionID != nil }.count, apps.count)
        XCTAssertFalse(harness.coordinator.isStartLaneBusy)
    }

    func testDuplicateRequestsForAQueuedAppProduceOneStart() async {
        let music = makeApp("music", "Music", pid: 101)
        let notes = makeApp("notes", "Notes", pid: 102)
        let harness = makeLaneHarness(apps: [music, notes], eligiblePIDs: [101, 102])

        harness.coordinator.requestAutomaticStart(for: music.id)
        await waitForPendingStart(harness, startCount: 1)

        harness.coordinator.requestAutomaticStart(for: notes.id)
        harness.coordinator.requestAutomaticStart(for: notes.id)
        harness.coordinator.startExperimentalControl(for: notes.id)
        harness.coordinator.requestAutomaticStart(for: notes.id)

        // One entry, keeping the first request's place and origin.
        XCTAssertEqual(laneState(harness).queuedStarts, [ProductRealQueuedStart(appID: notes.id, origin: .automatic)])

        await completeStart(harness, appID: music.id)
        await waitForPendingStart(harness, startCount: 2)
        await completeStart(harness, appID: notes.id)

        XCTAssertEqual(harness.liveSessionManager.startedAppIDs, [music.id, notes.id])
        XCTAssertEqual(harness.liveSessionManager.pendingStartCount, 0)
        XCTAssertTrue(laneState(harness).queuedStarts.isEmpty)
    }

    // MARK: - Fresh preflight at drain

    func testDrainRechecksPreflightAndDropsBlockedEntryWithItsMessage() async {
        let music = makeApp("music", "Music", pid: 101)
        let notes = makeApp("notes", "Notes", pid: 102)
        let mail = makeApp("mail", "Mail", pid: 103)
        let harness = makeLaneHarness(apps: [music, notes, mail], eligiblePIDs: [101, 102, 103])

        harness.coordinator.requestAutomaticStart(for: music.id)
        await waitForPendingStart(harness, startCount: 1)
        harness.coordinator.requestAutomaticStart(for: notes.id)
        harness.coordinator.requestAutomaticStart(for: mail.id)

        // Notes lost its process while queued: its drained preflight rejects it, and the loop moves on.
        harness.context.apps = [music, makeApp("notes", "Notes", pid: nil), mail]
        await completeStart(harness, appID: music.id)
        await waitForPendingStart(harness, startCount: 2)

        XCTAssertEqual(harness.liveSessionManager.startedAppIDs, [music.id, mail.id])
        XCTAssertEqual(harness.sideEffects.statusMessages, ["This app is not available for real app control"])
        XCTAssertTrue(laneState(harness).queuedStarts.isEmpty)
        XCTAssertFalse(laneState(harness).isOperationPending(for: notes.id))
        await completeStart(harness, appID: mail.id)
    }

    func testDrainSkipsQueuedAppThatDisappeared() async {
        let music = makeApp("music", "Music", pid: 101)
        let notes = makeApp("notes", "Notes", pid: 102)
        let mail = makeApp("mail", "Mail", pid: 103)
        let harness = makeLaneHarness(apps: [music, notes, mail], eligiblePIDs: [101, 102, 103])

        harness.coordinator.requestAutomaticStart(for: music.id)
        await waitForPendingStart(harness, startCount: 1)
        harness.coordinator.requestAutomaticStart(for: notes.id)
        harness.coordinator.requestAutomaticStart(for: mail.id)

        // Notes is gone from the app list by the time its entry drains: skipped silently.
        harness.context.apps = [music, mail]
        await completeStart(harness, appID: music.id)
        await waitForPendingStart(harness, startCount: 2)

        XCTAssertEqual(harness.liveSessionManager.startedAppIDs, [music.id, mail.id])
        XCTAssertTrue(harness.sideEffects.statusMessages.isEmpty)
        XCTAssertTrue(laneState(harness).queuedStarts.isEmpty)
        await completeStart(harness, appID: mail.id)
    }

    func testQueuedStartUsesGainCurrentAtDrain() async {
        let music = makeApp("music", "Music", pid: 101)
        let notes = makeApp("notes", "Notes", pid: 102, volume: 50)
        let harness = makeLaneHarness(apps: [music, notes], eligiblePIDs: [101, 102])

        harness.coordinator.requestAutomaticStart(for: music.id)
        await waitForPendingStart(harness, startCount: 1)
        harness.coordinator.requestAutomaticStart(for: notes.id)

        // The slider keeps moving while the start is queued.
        harness.context.apps = [music, makeApp("notes", "Notes", pid: 102, volume: 20)]
        await completeStart(harness, appID: music.id)
        await waitForPendingStart(harness, startCount: 2)

        let drainedGain = harness.liveSessionManager.startCalls.last?.gain
        XCTAssertEqual(drainedGain?.percentLabel, "20%")
        XCTAssertEqual(Double(drainedGain?.scalar ?? -1), 0.2, accuracy: 0.0001)
        await completeStart(harness, appID: notes.id)
    }

    // MARK: - Lane release

    func testCancelledResolutionDrainsOnlyAfterResolutionTaskFinishes() async {
        let safari = makeApp("safari", "Safari", pid: 100)
        let music = makeApp("music", "Music", pid: 101)
        let harness = makeLaneHarness(apps: [safari, music], eligiblePIDs: [101])

        harness.coordinator.requestAutomaticStart(for: safari.id)
        await waitFor { harness.resolver.pendingResolutionCount == 1 }
        harness.coordinator.requestAutomaticStart(for: music.id)

        harness.coordinator.cancelAppAudioTargetResolution(reason: .userStopped)

        // Resolving state is cleared, but the cancelled probe is still running (its task has not
        // returned), so the lane stays busy and nothing drains.
        XCTAssertFalse(laneState(harness).isResolving)
        XCTAssertEqual(harness.resolver.cancelReasons, [.userStopped])
        XCTAssertTrue(harness.coordinator.isStartLaneBusy)
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertTrue(harness.liveSessionManager.startCalls.isEmpty)
        XCTAssertEqual(laneState(harness).queuedStartAppIDs, [music.id])

        // The probe returns: only now does the lane free and the queued start run.
        harness.resolver.completeNext(.cancelled)
        await waitForPendingStart(harness, startCount: 1)

        XCTAssertEqual(harness.liveSessionManager.startedAppIDs, [music.id])
        XCTAssertTrue(harness.sideEffects.statusMessages.isEmpty)
        await completeStart(harness, appID: music.id)
    }

    func testHardBlocksRejectImmediatelyEvenWhileLaneBusy() async {
        let music = makeApp("music", "Music", pid: 101)
        let notes = makeApp("notes", "Notes", pid: 102)
        let radio = makeApp("radio", "Radio", pid: nil)
        let harness = makeLaneHarness(apps: [music, notes, radio], eligiblePIDs: [101, 102])

        harness.coordinator.requestAutomaticStart(for: music.id)
        await waitForPendingStart(harness, startCount: 1)
        XCTAssertTrue(harness.coordinator.isStartLaneBusy)

        harness.context.isHelperBusy = true
        harness.coordinator.requestAutomaticStart(for: notes.id)
        harness.context.isHelperBusy = false

        harness.context.isTwoAppReadinessRunning = true
        harness.coordinator.requestAutomaticStart(for: notes.id)
        harness.coordinator.startExperimentalControl(for: notes.id)
        harness.context.isTwoAppReadinessRunning = false

        harness.coordinator.requestAutomaticStart(for: radio.id)

        harness.context.isExperimentalRealAppControlEnabled = false
        harness.coordinator.requestAutomaticStart(for: notes.id)
        harness.context.isExperimentalRealAppControlEnabled = true

        XCTAssertEqual(harness.sideEffects.statusMessages, [
            "Stop helper probe first",
            "Stop two-app test first",
            "Stop two-app test first",
            "This app is not available for real app control"
        ])
        XCTAssertTrue(laneState(harness).queuedStarts.isEmpty)

        await completeStart(harness, appID: music.id)
        XCTAssertEqual(harness.liveSessionManager.startedAppIDs, [music.id])
        XCTAssertEqual(harness.liveSessionManager.pendingStartCount, 0)
    }

    func testStaleStartDrainsOnlyAfterOrphanCleanupIsRegistered() async {
        let music = makeApp("music", "Music", pid: 101)
        let notes = makeApp("notes", "Notes", pid: 102)
        let harness = makeLaneHarness(apps: [music, notes], eligiblePIDs: [101, 102])

        harness.coordinator.requestAutomaticStart(for: music.id)
        await waitForPendingStart(harness, startCount: 1)
        harness.coordinator.requestAutomaticStart(for: notes.id)

        // Supersede music's in-flight start, so its (successful) completion is stale.
        _ = harness.stateStore.productRealControlState.beginStartRequest(for: music.id)
        let orphanID = ProcessTapLiveSessionID()
        harness.liveSessionManager.completeNextStart(startedResult(orphanID))
        await waitForPendingStart(harness, startCount: 2)

        // The orphan teardown was registered with the settle gate before the lane was released, so the
        // drained start's settle wait awaited it: the orphan stop precedes the next engine start.
        XCTAssertEqual(harness.liveSessionManager.startCalls.last?.target.appID, notes.id)
        XCTAssertEqual(harness.liveSessionManager.startCalls.last?.priorStopSessionCount, 1)
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.map(\.id), [orphanID])
        XCTAssertEqual(harness.settleGate.registerStopCount, 1)
        XCTAssertNil(laneState(harness).activeSessionsByAppID[music.id])
        await completeStart(harness, appID: notes.id)
    }

    func testCachedHelperRetryTakesLaneBeforeQueueDrains() async {
        let safari = makeApp("safari", "Safari", pid: 100)
        let music = makeApp("music", "Music", pid: 101)
        let harness = makeLaneHarness(apps: [safari, music], eligiblePIDs: [101])

        harness.coordinator.startExperimentalControl(
            for: safari,
            target: helperTarget(for: safari, pid: 300, source: .cachedHelper).target,
            resolutionSource: .cachedHelper
        )
        await waitForPendingStart(harness, startCount: 1)
        harness.coordinator.requestAutomaticStart(for: music.id)

        // The cached helper fails to start: its post-await retries a fresh resolution, which takes the
        // lane before the queue would drain, so music keeps waiting.
        harness.liveSessionManager.completeNextStart(
            ProcessTapLiveSessionStartResult(sessionID: nil, result: makeResult(.liveControlSetupFailed))
        )
        await waitFor { harness.resolver.pendingResolutionCount == 1 }

        XCTAssertGreaterThanOrEqual(harness.resolver.invalidatedTargetCount, 1)
        XCTAssertTrue(laneState(harness).isResolving(appID: safari.id))
        XCTAssertEqual(laneState(harness).queuedStartAppIDs, [music.id])
        XCTAssertEqual(harness.liveSessionManager.startCalls.count, 1)
        XCTAssertTrue(harness.sideEffects.statusMessages.isEmpty)

        harness.resolver.completeNext(.unavailable("No audio helper found"))
        await waitForPendingStart(harness, startCount: 2)

        XCTAssertEqual(harness.liveSessionManager.startCalls.last?.target.appID, music.id)
        await completeStart(harness, appID: music.id)
    }

    // MARK: - Harness

    private struct LaneHarness {
        let coordinator: ProductRealStartCoordinator
        let stateStore: ProductRealControlStateStore
        let liveSessionManager: FakeProductRealLiveSessionManager
        let settleGate: RecordingStartSettleGate
        let resolver: RecordingAppAudioTargetResolver
        // Held so the coordinator's `weak` seam references stay alive for the test's lifetime.
        let sideEffects: StubProductRealControlSideEffects
        let context: StubProductRealControlContext
    }

    /// Real App Control on; engine starts and helper resolutions suspend until the test completes
    /// them. A visible PID in `eligiblePIDs` starts directly; any other app needs a helper resolution.
    private func makeLaneHarness(apps: [MixerAppItem], eligiblePIDs: Set<Int32>) -> LaneHarness {
        let stateStore = ProductRealControlStateStore()
        let liveSessionManager = FakeProductRealLiveSessionManager()
        liveSessionManager.suspendsStarts = true
        let settleGate = RecordingStartSettleGate()
        let resolver = RecordingAppAudioTargetResolver()
        resolver.suspendsResolution = true
        let sideEffects = StubProductRealControlSideEffects()
        let context = StubProductRealControlContext()
        context.apps = apps
        context.isExperimentalRealAppControlEnabled = true
        let coordinator = ProductRealStartCoordinator(
            stateStore: stateStore,
            liveSessionManager: liveSessionManager,
            appAudioTargetResolver: resolver,
            startSettleGate: settleGate,
            processTapEligibility: { processIdentifier in
                guard let processIdentifier, eligiblePIDs.contains(processIdentifier) else {
                    return ProcessTapProcessEligibility(isEligible: false, reason: nil)
                }
                return .eligible
            },
            sideEffects: sideEffects,
            context: context
        )
        return LaneHarness(
            coordinator: coordinator,
            stateStore: stateStore,
            liveSessionManager: liveSessionManager,
            settleGate: settleGate,
            resolver: resolver,
            sideEffects: sideEffects,
            context: context
        )
    }

    private func laneState(_ harness: LaneHarness) -> ProductRealControlState {
        harness.stateStore.productRealControlState
    }

    private func makeApp(_ id: String, _ name: String, pid: Int32?, volume: Double = 50) -> MixerAppItem {
        MixerAppItem(id: id, name: name, icon: .systemSymbol("app"), processIdentifier: pid, volume: volume)
    }

    private func helperTarget(
        for app: MixerAppItem,
        pid: Int32,
        source: ResolvedAppAudioTarget.Source
    ) -> ResolvedAppAudioTarget {
        ResolvedAppAudioTarget(
            visibleAppID: app.id,
            visibleAppName: app.name,
            target: ProcessTapTarget(appID: "helper:\(app.id):\(pid)", appName: app.name, processIdentifier: pid),
            kind: .helper,
            source: source
        )
    }

    private func startedResult(_ sessionID: ProcessTapLiveSessionID) -> ProcessTapLiveSessionStartResult {
        ProcessTapLiveSessionStartResult(sessionID: sessionID, result: makeResult(.liveControlStarted))
    }

    private func makeResult(_ outcome: ProcessTapTestResult.Outcome) -> ProcessTapTestResult {
        ProcessTapTestResult(outcome: outcome, message: "test", severity: .info)
    }

    /// Waits until exactly one engine start is suspended in flight and `startCount` starts have reached
    /// the engine in total (the fake registers the continuation together with the record, so it can be
    /// completed as soon as this returns).
    private func waitForPendingStart(
        _ harness: LaneHarness,
        startCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await waitFor(file: file, line: line) {
            harness.liveSessionManager.pendingStartCount == 1
                && harness.liveSessionManager.startCalls.count == startCount
        }
    }

    /// Completes the oldest in-flight engine start successfully and waits until `appID`'s session is
    /// confirmed with that engine id (so its post-await block — lane release and drain — has run).
    @discardableResult
    private func completeStart(
        _ harness: LaneHarness,
        appID: MixerAppItem.ID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> ProcessTapLiveSessionID {
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.completeNextStart(startedResult(sessionID))
        await waitFor(file: file, line: line) {
            harness.stateStore.productRealControlState.activeSessionsByAppID[appID]?.liveSessionID == sessionID
        }
        return sessionID
    }

    /// Deadline-bounded observable wait: returns as soon as `condition` holds, cooperatively yielding
    /// otherwise; the deadline is a failure bound, not a sleep.
    private func waitFor(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
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
}
