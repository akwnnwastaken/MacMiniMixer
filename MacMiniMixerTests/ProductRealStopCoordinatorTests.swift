import XCTest
@testable import MacMiniMixer

@MainActor
final class ProductRealStopCoordinatorTests: XCTestCase {
    // MARK: - Per-app stop leaf

    func testStopExperimentalControlStopsSessionByIDWithReason() async {
        let harness = makeStopHarness()
        let app = makeApp()
        let sessionID = ProcessTapLiveSessionID()
        harness.stateStore.productRealControlState.beginSession(
            visibleAppID: app.id, displayName: app.name,
            controlledProcessIdentifier: app.processIdentifier,
            source: .directVisiblePID, liveSessionID: sessionID
        )

        harness.coordinator.stopExperimentalControl(for: app.id, reason: .targetAppExited)
        await waitUntil { !harness.liveSessionManager.stopSessionCalls.isEmpty }

        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.count, 1)
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.first?.id, sessionID)
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.first?.reason, .targetAppExited)
        // The live-session path does not clear the local session; the terminal clear is owned by the
        // stop callback. The session therefore remains present here.
        XCTAssertEqual(harness.stateStore.productRealControlState.activeSessionsByAppID[app.id]?.liveSessionID, sessionID)
    }

    func testStopExperimentalControlOptimisticWindowClearsLocallyWithoutStopSession() async {
        let harness = makeStopHarness()
        let app = makeApp()
        harness.stateStore.productRealControlState.beginSession(
            visibleAppID: app.id, displayName: app.name,
            controlledProcessIdentifier: app.processIdentifier,
            source: .directVisiblePID
        )

        harness.coordinator.stopExperimentalControl(for: app.id)
        await Task.yield()

        XCTAssertNil(harness.stateStore.productRealControlState.activeSessionsByAppID[app.id])
        XCTAssertTrue(harness.stateStore.productRealControlState.activeVisibleAppIDs.isEmpty)
        XCTAssertEqual(harness.sideEffects.activeNameHistory.last, .some(nil))
        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
        XCTAssertFalse(harness.stateStore.productRealControlState.isOperationPending(for: app.id))
    }

    func testStopExperimentalControlMarksOperationPendingForLiveSessionStop() {
        let harness = makeStopHarness()
        let app = makeApp()
        let sessionID = ProcessTapLiveSessionID()
        harness.stateStore.productRealControlState.beginSession(
            visibleAppID: app.id, displayName: app.name,
            controlledProcessIdentifier: app.processIdentifier,
            source: .directVisiblePID, liveSessionID: sessionID
        )

        harness.coordinator.stopExperimentalControl(for: app.id)

        XCTAssertTrue(harness.stateStore.productRealControlState.isOperationPending(for: app.id))
    }

    // MARK: - Stop-all core

    func testStopProductLiveSessionsStopsEveryActiveSession() async {
        let harness = makeStopHarness()
        let (_, _, sidA, sidB) = makeTwoConfirmedSessions(harness)

        harness.coordinator.stopProductLiveSessions(reason: .userStopped)
        await waitUntil { harness.liveSessionManager.stopSessionCalls.count == 2 }

        XCTAssertEqual(Set(harness.liveSessionManager.stopSessionCalls.map(\.id)), [sidA, sidB])
        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.allSatisfy { $0.reason == .userStopped })
        // A single batched teardown task is registered with the settle gate.
        XCTAssertEqual(harness.settleGate.registerStopCount, 1)
        XCTAssertFalse(harness.context.advancedManualLiveControlActive)
    }

    func testStopProductLiveSessionsHandlesNoActiveSessionsLikeBefore() async {
        let harness = makeStopHarness()
        let diagnostics = makeDiagnostics(callbackCount: 3)
        harness.context.processTapLiveDiagnostics = diagnostics

        harness.coordinator.stopProductLiveSessions(reason: .userStopped)
        await Task.yield()

        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
        XCTAssertEqual(harness.settleGate.registerStopCount, 0)
        // Same not-active display path: routes a `.liveControlNotActive` stop callback carrying the
        // current diagnostics through the shared display cleanup.
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.count, 1)
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.first?.result.outcome, .liveControlNotActive)
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.first?.diagnostics?.callbackCount, 3)
    }

    // MARK: - Stop callback

    func testHandleProductLiveControlStoppedClearsOnlyMatchingSession() {
        let harness = makeStopHarness()
        let (appA, appB, sidA, _) = makeTwoConfirmedSessions(harness)
        harness.stateStore.productRealControlState.beginOperation(for: appA.id)

        harness.coordinator.handleProductLiveControlStopped(
            sessionID: sidA, result: makeResult(.liveControlStopped), diagnostics: nil
        )

        XCTAssertNil(harness.stateStore.productRealControlState.activeSessionsByAppID[appA.id])
        XCTAssertNotNil(harness.stateStore.productRealControlState.activeSessionsByAppID[appB.id])
        XCTAssertFalse(harness.stateStore.productRealControlState.isOperationPending(for: appA.id))
        XCTAssertEqual(harness.sideEffects.activeNameHistory.last, appB.name)
    }

    func testHandleProductLiveControlStoppedUnknownSessionDoesNotDisturbActiveSessions() {
        let harness = makeStopHarness()
        let (appA, appB, _, _) = makeTwoConfirmedSessions(harness)
        harness.stateStore.productRealControlState.beginOperation(for: appA.id)

        harness.coordinator.handleProductLiveControlStopped(
            sessionID: ProcessTapLiveSessionID(), result: makeResult(.liveControlStopped), diagnostics: nil
        )

        XCTAssertNotNil(harness.stateStore.productRealControlState.activeSessionsByAppID[appA.id])
        XCTAssertNotNil(harness.stateStore.productRealControlState.activeSessionsByAppID[appB.id])
        XCTAssertTrue(harness.stateStore.productRealControlState.isOperationPending(for: appA.id))
        XCTAssertTrue(harness.sideEffects.stoppedDisplayCalls.isEmpty)
    }

    func testHandleProductLiveControlStoppedClearsPendingOperation() {
        let harness = makeStopHarness()
        let (appA, _, sidA, _) = makeTwoConfirmedSessions(harness)
        harness.stateStore.productRealControlState.beginOperation(for: appA.id)
        XCTAssertTrue(harness.stateStore.productRealControlState.isOperationPending(for: appA.id))

        harness.coordinator.handleProductLiveControlStopped(
            sessionID: sidA, result: makeResult(.liveControlStopped), diagnostics: nil
        )

        XCTAssertFalse(harness.stateStore.productRealControlState.isOperationPending(for: appA.id))
    }

    func testHandleProductLiveControlStoppedRoutesDisplayCleanupThroughSeam() {
        let harness = makeStopHarness()
        let (_, _, sidA, _) = makeTwoConfirmedSessions(harness)
        let result = makeResult(.liveControlStopped)
        let diagnostics = makeDiagnostics(callbackCount: 9)

        harness.coordinator.handleProductLiveControlStopped(
            sessionID: sidA, result: result, diagnostics: diagnostics
        )

        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.count, 1)
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.first?.result.outcome, result.outcome)
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.first?.diagnostics?.callbackCount, 9)
    }

    // Only per-callback live diagnostics are gated on the Advanced display being visible; the stop
    // display cleanup still carries the stopped session's final diagnostics while it is hidden.
    func testStopDisplayCleanupCarriesDiagnosticsWhileLiveDiagnosticsDisplayHidden() {
        let harness = makeStopHarness()
        harness.context.isLiveDiagnosticsDisplayVisible = false
        let (_, _, sidA, _) = makeTwoConfirmedSessions(harness)

        harness.coordinator.handleProductLiveControlStopped(
            sessionID: sidA, result: makeResult(.liveControlStopped), diagnostics: makeDiagnostics(callbackCount: 13)
        )

        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.count, 1)
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.first?.result.outcome, .liveControlStopped)
        XCTAssertEqual(harness.sideEffects.stoppedDisplayCalls.first?.diagnostics?.callbackCount, 13)
    }

    func testHandleProductLiveControlStoppedAppExitInvalidatesCachedTarget() {
        let harness = makeStopHarness()
        let (appA, _, sidA, _) = makeTwoConfirmedSessions(harness)

        harness.coordinator.handleProductLiveControlStopped(
            sessionID: sidA, result: makeResult(.liveControlAppExited), diagnostics: nil
        )

        // The app is still in the running list, so the app-exit outcome invalidates its cached target.
        XCTAssertEqual(harness.resolver.invalidatedTargetCount, 1)
        XCTAssertNil(harness.stateStore.productRealControlState.activeSessionsByAppID[appA.id])
    }

    // MARK: - App-exit stop slice

    func testStopRealControlForExitedTargetAppsStopsOnlyMissingApps() async {
        let harness = makeStopHarness()
        let (appA, appB, _, sidB) = makeTwoConfirmedSessions(harness)
        // appA still running, appB exited.
        harness.context.apps = [appA]

        harness.coordinator.stopRealControlForExitedTargetApps()
        await waitUntil { !harness.liveSessionManager.stopSessionCalls.isEmpty }

        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.count, 1)
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.first?.id, sidB)
        XCTAssertEqual(harness.liveSessionManager.stopSessionCalls.first?.reason, .targetAppExited)
        XCTAssertNotNil(harness.stateStore.productRealControlState.activeSessionsByAppID[appA.id])
        XCTAssertTrue(harness.stateStore.productRealControlState.isOperationPending(for: appB.id))
    }

    func testStopRealControlForExitedTargetAppsDoesNothingWhenAllTargetsStillRunning() async {
        let harness = makeStopHarness()
        let (appA, appB, _, _) = makeTwoConfirmedSessions(harness)

        harness.coordinator.stopRealControlForExitedTargetApps()
        await Task.yield()

        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
        XCTAssertTrue(harness.cancelResolutionSpy.reasons.isEmpty)
        XCTAssertNotNil(harness.stateStore.productRealControlState.activeSessionsByAppID[appA.id])
        XCTAssertNotNil(harness.stateStore.productRealControlState.activeSessionsByAppID[appB.id])
    }

    func testStopRealControlForExitedTargetAppsHandlesOptimisticSessionWithoutLiveID() async {
        let harness = makeStopHarness()
        let app = makeApp(id: "gone", name: "Gone", pid: 9)
        harness.stateStore.productRealControlState.beginSession(
            visibleAppID: app.id, displayName: app.name,
            controlledProcessIdentifier: app.processIdentifier, source: .directVisiblePID
        )
        harness.context.apps = []

        harness.coordinator.stopRealControlForExitedTargetApps()
        await Task.yield()

        XCTAssertNil(harness.stateStore.productRealControlState.activeSessionsByAppID[app.id])
        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
    }

    func testStopRealControlForExitedTargetAppsCancelsResolutionWhenResolvingTargetExits() {
        let harness = makeStopHarness()
        harness.stateStore.productRealControlState.beginResolution(for: "ghost")
        harness.context.apps = []

        harness.coordinator.stopRealControlForExitedTargetApps()

        // The exited resolving target routes a `.targetExited` cancel through the facade-wired closure.
        XCTAssertEqual(harness.cancelResolutionSpy.reasons, [.targetExited])
    }

    // MARK: - Hard-teardown state reset

    func testTearDownProductStateForHardStopClearsAllProductState() {
        let harness = makeStopHarness()
        let (appA, appB, _, _) = makeTwoConfirmedSessions(harness)
        let reqID = harness.stateStore.productRealControlState.beginStartRequest(for: appA.id)
        harness.stateStore.productRealControlState.beginResolution(for: "resolving-app")
        harness.stateStore.productRealControlState.beginOperation(for: appB.id)
        XCTAssertFalse(harness.stateStore.productRealControlState.activeVisibleAppIDs.isEmpty)

        harness.coordinator.tearDownProductStateForHardStop()

        let state = harness.stateStore.productRealControlState
        XCTAssertTrue(state.activeVisibleAppIDs.isEmpty)
        XCTAssertFalse(state.hasConfirmedLiveSession)
        XCTAssertFalse(state.isCurrentStartRequest(reqID, for: appA.id))
        XCTAssertTrue(state.resolvingAppIDs.isEmpty)
        XCTAssertFalse(state.isOperationPending(for: appA.id))
        XCTAssertFalse(state.isOperationPending(for: appB.id))
    }

    func testTearDownProductStateForHardStopClearsActiveName() {
        let harness = makeStopHarness()
        _ = makeTwoConfirmedSessions(harness)

        harness.coordinator.tearDownProductStateForHardStop()

        XCTAssertEqual(harness.sideEffects.activeNameHistory.last, .some(nil))
    }

    func testTearDownProductStateForHardStopDoesNotCallEngineStopSession() async {
        let harness = makeStopHarness()
        _ = makeTwoConfirmedSessions(harness)

        harness.coordinator.tearDownProductStateForHardStop()
        await Task.yield()

        XCTAssertTrue(harness.liveSessionManager.stopSessionCalls.isEmpty)
    }

    func testTearDownProductStateForHardStopDoesNotTouchAdvancedManualOrUnrelatedContext() {
        let harness = makeStopHarness()
        _ = makeTwoConfirmedSessions(harness)
        harness.context.advancedManualLiveControlActive = true
        harness.context.isProcessTapTesting = true

        harness.coordinator.tearDownProductStateForHardStop()

        XCTAssertTrue(harness.context.advancedManualLiveControlActive)
        XCTAssertTrue(harness.context.isProcessTapTesting)
        XCTAssertTrue(harness.cancelResolutionSpy.reasons.isEmpty)
    }

    // MARK: - Shared active-name helper

    func testUpdateActiveNamePreservesSurvivingConfirmedSessionName() {
        let harness = makeStopHarness()
        let app = makeApp(id: "b", name: "Bravo", pid: 2)
        harness.stateStore.productRealControlState.beginSession(
            visibleAppID: app.id, displayName: app.name,
            controlledProcessIdentifier: app.processIdentifier,
            source: .directVisiblePID, liveSessionID: ProcessTapLiveSessionID()
        )

        harness.coordinator.updateActiveLiveControlAppNameAfterProductChange()

        XCTAssertEqual(harness.sideEffects.activeNameHistory.last, "Bravo")
    }

    func testUpdateActiveNameShortCircuitsWhenAdvancedManualActive() {
        let harness = makeStopHarness()
        let app = makeApp()
        harness.stateStore.productRealControlState.beginSession(
            visibleAppID: app.id, displayName: app.name,
            controlledProcessIdentifier: app.processIdentifier,
            source: .directVisiblePID, liveSessionID: ProcessTapLiveSessionID()
        )
        harness.context.advancedManualLiveControlActive = true

        harness.coordinator.updateActiveLiveControlAppNameAfterProductChange()

        // Advanced-manual owns the display, so the product path does not touch the active name.
        XCTAssertTrue(harness.sideEffects.activeNameHistory.isEmpty)
    }

    // MARK: - Harness

    private struct StopHarness {
        let coordinator: ProductRealStopCoordinator
        let stateStore: ProductRealControlStateStore
        let liveSessionManager: FakeProductRealLiveSessionManager
        let settleGate: RecordingStartSettleGate
        let resolver: RecordingAppAudioTargetResolver
        // Held so the coordinator's `weak` seam references stay alive for the test's lifetime.
        let sideEffects: StubProductRealControlSideEffects
        let context: StubProductRealControlContext
        let cancelResolutionSpy: CancelResolutionSpy
    }

    private func makeStopHarness() -> StopHarness {
        let stateStore = ProductRealControlStateStore()
        let liveSessionManager = FakeProductRealLiveSessionManager()
        let settleGate = RecordingStartSettleGate()
        let resolver = RecordingAppAudioTargetResolver()
        let sideEffects = StubProductRealControlSideEffects()
        let context = StubProductRealControlContext()
        let cancelResolutionSpy = CancelResolutionSpy()
        let coordinator = ProductRealStopCoordinator(
            stateStore: stateStore,
            liveSessionManager: liveSessionManager,
            startSettleGate: settleGate,
            appAudioTargetResolver: resolver,
            sideEffects: sideEffects,
            context: context,
            cancelResolution: { reason in cancelResolutionSpy.record(reason) }
        )
        return StopHarness(
            coordinator: coordinator,
            stateStore: stateStore,
            liveSessionManager: liveSessionManager,
            settleGate: settleGate,
            resolver: resolver,
            sideEffects: sideEffects,
            context: context,
            cancelResolutionSpy: cancelResolutionSpy
        )
    }

    /// Confirms two Product Real sessions (a, b) with engine ids in the shared store.
    private func makeTwoConfirmedSessions(
        _ harness: StopHarness
    ) -> (appA: MixerAppItem, appB: MixerAppItem, sidA: ProcessTapLiveSessionID, sidB: ProcessTapLiveSessionID) {
        let appA = makeApp(id: "a", name: "Alpha", pid: 1)
        let appB = makeApp(id: "b", name: "Bravo", pid: 2)
        let sidA = ProcessTapLiveSessionID()
        let sidB = ProcessTapLiveSessionID()
        harness.context.apps = [appA, appB]
        harness.stateStore.productRealControlState.beginSession(
            visibleAppID: appA.id, displayName: appA.name,
            controlledProcessIdentifier: appA.processIdentifier,
            source: .directVisiblePID, liveSessionID: sidA
        )
        harness.stateStore.productRealControlState.beginSession(
            visibleAppID: appB.id, displayName: appB.name,
            controlledProcessIdentifier: appB.processIdentifier,
            source: .directVisiblePID, liveSessionID: sidB
        )
        return (appA, appB, sidA, sidB)
    }

    private func makeApp(id: String = "safari", name: String = "Safari", pid: Int32? = 100) -> MixerAppItem {
        MixerAppItem(id: id, name: name, icon: .systemSymbol("app"), processIdentifier: pid, volume: 50)
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

    private func makeResult(_ outcome: ProcessTapTestResult.Outcome) -> ProcessTapTestResult {
        ProcessTapTestResult(outcome: outcome, message: "test", severity: .info)
    }

    /// Polls a deterministic condition via cooperative yields — no sleeps. Bounded so a logic error
    /// fails fast instead of hanging.
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, iterations: Int = 5000) async {
        var i = 0
        while !condition() && i < iterations {
            await Task.yield()
            i += 1
        }
        XCTAssertTrue(condition(), "waitUntil condition not met within \(iterations) iterations")
    }
}

/// Records the `cancelResolution` closure invocations the facade wires into the stop coordinator.
@MainActor
final class CancelResolutionSpy {
    private(set) var reasons: [ProcessTapCandidateProbeStopReason] = []
    func record(_ reason: ProcessTapCandidateProbeStopReason) {
        reasons.append(reason)
    }
}
