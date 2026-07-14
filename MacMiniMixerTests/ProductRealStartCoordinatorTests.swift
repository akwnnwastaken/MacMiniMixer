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

    private func makeStartHarness(visibleProcessEligible: Bool = false) -> StartHarness {
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
            context: context
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
