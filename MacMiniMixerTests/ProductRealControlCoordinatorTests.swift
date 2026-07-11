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

    func testOnStoppedRoutesThroughSideEffectsHandler() async {
        let harness = makeHarness()
        let app = makeApp()
        harness.context.apps = [app]
        let sessionID = ProcessTapLiveSessionID()
        harness.liveSessionManager.configureStart(result: startedResult(sessionID))
        harness.liveSessionManager.configureEmitStopped(id: sessionID, result: makeResult(.liveControlStopped), diagnostics: nil)

        harness.coordinator.startExperimentalControl(for: app, target: makeTarget(for: app))
        await waitUntil { !harness.sideEffects.stoppedCalls.isEmpty }

        XCTAssertEqual(harness.sideEffects.stoppedCalls.first?.sessionID, sessionID)
        XCTAssertEqual(harness.sideEffects.stoppedCalls.first?.result.outcome, .liveControlStopped)
    }

    // Cached-helper retry (a `.cachedHelper` failure re-attempting with `allowsCachedLookup: false`)
    // is exercised end-to-end by the existing MixerViewModelLiveControlTests; reproducing its
    // two-phase resolve + eligibility fixture at the coordinator unit level would be broad and
    // brittle, so it is intentionally left to the VM suite.

    // MARK: - Harness

    private struct Harness {
        let coordinator: ProductRealControlCoordinator
        let liveSessionManager: FakeProductRealLiveSessionManager
        let resolver: RecordingAppAudioTargetResolver
        // Held so the coordinator's `weak` seam references stay alive for the test's lifetime.
        let sideEffects: StubProductRealControlSideEffects
        let context: StubProductRealControlContext
    }

    private func makeHarness(visibleProcessEligible: Bool = false) -> Harness {
        let liveSessionManager = FakeProductRealLiveSessionManager()
        let resolver = RecordingAppAudioTargetResolver()
        let sideEffects = StubProductRealControlSideEffects()
        let context = StubProductRealControlContext()
        let coordinator = ProductRealControlCoordinator(
            liveSessionManager: liveSessionManager,
            appAudioTargetResolver: resolver,
            startSettleGate: ProductRealStartSettleGate(),
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

    var stopSessionCalls: [(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason)] {
        lock.withLock { recordedStopSessionCalls }
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
            (configuredStartResult, diagnosticsToEmit, stoppedToEmit)
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
    private(set) var stoppedCalls: [(sessionID: ProcessTapLiveSessionID?, result: ProcessTapTestResult, diagnostics: ProcessTapLiveDiagnostics?)] = []

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
    func handleProductLiveControlStopped(
        sessionID: ProcessTapLiveSessionID?,
        result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?
    ) {
        stoppedCalls.append((sessionID, result, diagnostics))
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
