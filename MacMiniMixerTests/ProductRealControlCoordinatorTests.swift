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

    // MARK: - Harness

    private struct Harness {
        let coordinator: ProductRealControlCoordinator
        let liveSessionManager: FakeProductRealLiveSessionManager
        // Held so the coordinator's `weak` seam references stay alive for the test's lifetime.
        let sideEffects: StubProductRealControlSideEffects
        let context: StubProductRealControlContext
    }

    private func makeHarness() -> Harness {
        let liveSessionManager = FakeProductRealLiveSessionManager()
        let sideEffects = StubProductRealControlSideEffects()
        let context = StubProductRealControlContext()
        let coordinator = ProductRealControlCoordinator(
            liveSessionManager: liveSessionManager,
            appAudioTargetResolver: InertAppAudioTargetResolver(),
            startSettleGate: ProductRealStartSettleGate(),
            processTapEligibility: { _ in ProcessTapProcessEligibility(isEligible: false, reason: nil) },
            sideEffects: sideEffects,
            context: context
        )
        return Harness(
            coordinator: coordinator,
            liveSessionManager: liveSessionManager,
            sideEffects: sideEffects,
            context: context
        )
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

private final class InertAppAudioTargetResolver: AppAudioTargetResolving, @unchecked Sendable {
    func resolveTarget(
        for request: AppAudioTargetRequest,
        allowsCachedLookup: Bool,
        onProgress: @escaping @Sendable (AppAudioResolutionProgress) -> Void
    ) async -> AppAudioTargetResolutionResult {
        .cancelled
    }

    func cancelCurrentResolution(reason: ProcessTapCandidateProbeStopReason) {}
    func invalidateCachedTarget(for request: AppAudioTargetRequest) {}
    func invalidateAllCachedTargets() {}
}

private final class StubProductRealControlSideEffects: ProductRealControlSideEffects {
    func showProductRealStatus(_ text: String, style: MixerStatusMessage.Style, action: MixerStatusMessage.Action?) {}
    func setActiveLiveControlAppName(_ name: String?) {}
    func setProcessTapLiveDiagnostics(_ diagnostics: ProcessTapLiveDiagnostics?) {}
    func setLiveControlDiagnosticResult(_ result: ProcessTapTestResult) {}
    func setLiveControlDiagnosticProgress(_ progress: ProcessTapDiagnosticProgress?) {}
    func setLiveControlDiagnosticRunning(_ isRunning: Bool) {}
}

private final class StubProductRealControlContext: ProductRealControlContext {
    var apps: [MixerAppItem] { [] }
    var isExperimentalRealAppControlEnabled: Bool { false }
    var advancedManualLiveControlActive: Bool { false }
    var selectedProcessTapAppID: MixerAppItem.ID? { nil }
    var isTwoAppReadinessRunning: Bool { false }
    var isProcessTapTesting: Bool { false }
    var isHelperBusy: Bool { false }
    var isAppAudioTargetResolving: Bool { false }
}
