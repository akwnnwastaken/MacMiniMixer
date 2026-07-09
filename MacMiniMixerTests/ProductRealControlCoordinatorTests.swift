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

        harness.coordinator.startResolvedExperimentalControl(for: app)

        XCTAssertEqual(harness.sideEffects.startResolvedCalls.count, 1)
        XCTAssertEqual(harness.sideEffects.startResolvedCalls.first?.app.id, app.id)
        XCTAssertNil(harness.sideEffects.startResolvedCalls.first?.source)
        // No resolution was needed, so no resolving state was entered.
        XCTAssertFalse(harness.coordinator.productRealControlState.isResolving)
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

        XCTAssertEqual(harness.sideEffects.startResolvedCalls.count, 1)
        XCTAssertEqual(harness.sideEffects.startResolvedCalls.first?.source, .discoveredHelper)
        XCTAssertFalse(harness.coordinator.productRealControlState.isResolving)
    }

    func testHandleUnavailableResultReportsReasonAndClearsResolving() {
        let harness = makeHarness()
        harness.coordinator.productRealControlState.beginResolution(for: "safari")

        harness.coordinator.handleAppAudioTargetResolution(.unavailable("No audio helper found"), for: "safari")

        XCTAssertEqual(harness.sideEffects.statusMessages, ["No audio helper found"])
        XCTAssertTrue(harness.sideEffects.startResolvedCalls.isEmpty)
        XCTAssertFalse(harness.coordinator.productRealControlState.isResolving)
    }

    func testHandleCancelledResultClearsResolvingWithoutStatus() {
        let harness = makeHarness()
        harness.coordinator.productRealControlState.beginResolution(for: "safari")

        harness.coordinator.handleAppAudioTargetResolution(.cancelled, for: "safari")

        XCTAssertTrue(harness.sideEffects.statusMessages.isEmpty)
        XCTAssertTrue(harness.sideEffects.startResolvedCalls.isEmpty)
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

        XCTAssertTrue(harness.sideEffects.startResolvedCalls.isEmpty)
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

    private func makeResult(_ outcome: ProcessTapTestResult.Outcome) -> ProcessTapTestResult {
        ProcessTapTestResult(outcome: outcome, message: "test", severity: .info)
    }
}

// MARK: - Fakes

private final class FakeProductRealLiveSessionManager: ProcessTapLiveControlling & ProcessTapLiveSessionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStopSessionCalls: [(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason)] = []

    var stopSessionCalls: [(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason)] {
        lock.withLock { recordedStopSessionCalls }
    }

    var activeSession: ProcessTapLiveSessionState? { nil }
    var activeSessions: [ProcessTapLiveSessionState] { [] }

    func startSession(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapLiveSessionStartResult {
        notActiveStartResult
    }

    func startSession(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapLiveSessionStartResult {
        notActiveStartResult
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
    private(set) var startResolvedCalls: [(app: MixerAppItem, target: ProcessTapTarget, source: ResolvedAppAudioTarget.Source?)] = []

    func showProductRealStatus(_ text: String, style: MixerStatusMessage.Style, action: MixerStatusMessage.Action?) {
        statusMessages.append(text)
    }
    func setActiveLiveControlAppName(_ name: String?) {}
    func setProcessTapLiveDiagnostics(_ diagnostics: ProcessTapLiveDiagnostics?) {}
    func setLiveControlDiagnosticResult(_ result: ProcessTapTestResult) {}
    func setLiveControlDiagnosticProgress(_ progress: ProcessTapDiagnosticProgress?) {}
    func setLiveControlDiagnosticRunning(_ isRunning: Bool) {}
    func startResolvedProductReal(app: MixerAppItem, target: ProcessTapTarget, resolutionSource: ResolvedAppAudioTarget.Source?) {
        startResolvedCalls.append((app, target, resolutionSource))
    }
}

private final class StubProductRealControlContext: ProductRealControlContext {
    var apps: [MixerAppItem] = []
    var isExperimentalRealAppControlEnabled: Bool { false }
    var advancedManualLiveControlActive: Bool { false }
    var selectedProcessTapAppID: MixerAppItem.ID? { nil }
    var isTwoAppReadinessRunning: Bool { false }
    var isProcessTapTesting: Bool { false }
    var isHelperBusy: Bool { false }
    var isAppAudioTargetResolving: Bool { false }
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
