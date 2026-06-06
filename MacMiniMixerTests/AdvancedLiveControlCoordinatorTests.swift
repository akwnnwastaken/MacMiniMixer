import XCTest
@testable import MacMiniMixer

@MainActor
final class AdvancedLiveControlCoordinatorTests: XCTestCase {
    func testStartLiveControlUsesSelectedVisibleAppAndGain() async {
        let liveController = FakeAdvancedLiveController()
        let diagnostics = makeDiagnosticsCoordinator()
        let coordinator = AdvancedLiveControlCoordinator(
            liveController: liveController,
            diagnostics: diagnostics
        )
        let apps = [makeAdvancedLiveApp(id: "music", name: "Music", pid: 102)]
        var startedAppName: String?
        var liveDiagnostics: ProcessTapLiveDiagnostics?

        let selectedGain = ProcessTapReplayGainOption.options[3]

        coordinator.startLiveControl(
            apps: apps,
            selectedAppID: "music",
            gain: selectedGain,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        ) { diagnostics in
            liveDiagnostics = diagnostics
        } onStarted: { appName in
            startedAppName = appName
        } onFailed: { _ in
            XCTFail("Expected live control to start")
        } onStopped: { _, _ in }

        await waitFor { liveController.startedTargets.count == 1 && startedAppName != nil }

        XCTAssertEqual(liveController.startedTargets.map(\.appID), ["music"])
        XCTAssertEqual(liveController.startedTargets.map(\.processIdentifier), [102])
        XCTAssertEqual(liveController.startedGains, [selectedGain])
        XCTAssertEqual(
            liveController.startTimeoutPolicies,
            [.limited(AppConstants.processTapLiveControlMaxDuration)]
        )
        XCTAssertEqual(startedAppName, "Music")
        XCTAssertEqual(liveDiagnostics?.selectedGain, selectedGain)
        XCTAssertEqual(diagnostics.result?.outcome, .liveControlStarted)
        XCTAssertFalse(diagnostics.isRunningDiagnostics)
    }

    func testStartLiveControlWithNoSelectedAppSetsInvalidTargetResult() async {
        let liveController = FakeAdvancedLiveController()
        let diagnostics = makeDiagnosticsCoordinator(apps: [])
        let coordinator = AdvancedLiveControlCoordinator(
            liveController: liveController,
            diagnostics: diagnostics
        )

        coordinator.startLiveControl(
            apps: [],
            selectedAppID: nil,
            gain: .defaultOption,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        ) { _ in
            XCTFail("No diagnostics should be emitted")
        } onStarted: { _ in
            XCTFail("No app should start")
        } onFailed: { _ in
            XCTFail("Invalid target is handled by result state before start")
        } onStopped: { _, _ in }

        await drainMainActor()

        XCTAssertTrue(liveController.startedTargets.isEmpty)
        XCTAssertEqual(diagnostics.result?.outcome, .invalidTarget)
        XCTAssertEqual(diagnostics.result?.message, "Select a running app")
    }

    func testStartLiveControlIsBlockedByActiveLiveSession() async {
        let liveController = FakeAdvancedLiveController()
        let diagnostics = makeDiagnosticsCoordinator()
        let coordinator = AdvancedLiveControlCoordinator(
            liveController: liveController,
            diagnostics: diagnostics
        )

        coordinator.startLiveControl(
            apps: [makeAdvancedLiveApp(id: "music", name: "Music", pid: 102)],
            selectedAppID: "music",
            gain: .defaultOption,
            isLiveControlActive: true,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        ) { _ in
            XCTFail("No diagnostics should be emitted")
        } onStarted: { _ in
            XCTFail("No app should start")
        } onFailed: { _ in
            XCTFail("Blocked starts should not produce a failure callback")
        } onStopped: { _, _ in }

        await drainMainActor()

        XCTAssertTrue(liveController.startedTargets.isEmpty)
        XCTAssertNil(diagnostics.result)
    }

    func testStopLiveControlForwardsReasonAndNotActiveCallback() async {
        let liveController = FakeAdvancedLiveController()
        let diagnostics = makeDiagnosticsCoordinator()
        let coordinator = AdvancedLiveControlCoordinator(
            liveController: liveController,
            diagnostics: diagnostics
        )
        var stoppedResult: ProcessTapTestResult?

        coordinator.stopLiveControl(
            reason: .userStopped,
            isLiveControlActive: true,
            currentDiagnostics: nil
        ) { result, _ in
            stoppedResult = result
        }

        await waitFor { stoppedResult != nil }

        XCTAssertEqual(liveController.stopReasons, [.userStopped])
        XCTAssertEqual(stoppedResult?.outcome, .liveControlNotActive)
    }

    private func makeDiagnosticsCoordinator(
        apps: [MixerAppItem] = [makeAdvancedLiveApp(id: "music", name: "Music", pid: 102)]
    ) -> AdvancedProcessTapDiagnosticsCoordinator {
        AdvancedProcessTapDiagnosticsCoordinator(
            processTapTester: FakeAdvancedLiveProcessTapTester(),
            processTapReplayProbe: FakeAdvancedLiveReplayProbe(),
            initialApps: apps,
            processTapEligibility: { _ in .eligible }
        )
    }

    private func waitFor(
        timeoutInYields: Int = 50,
        _ predicate: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<timeoutInYields {
            if predicate() {
                return
            }

            await Task.yield()
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private func drainMainActor(iterations: Int = 5) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }
}

private func makeAdvancedLiveApp(id: String, name: String, pid: Int32) -> MixerAppItem {
    MixerAppItem(
        id: id,
        name: name,
        icon: .systemSymbol("music.note"),
        processIdentifier: pid,
        volume: 50
    )
}

private final class FakeAdvancedLiveController: ProcessTapLiveControlling, @unchecked Sendable {
    private(set) var startedTargets: [ProcessTapTarget] = []
    private(set) var startedGains: [ProcessTapReplayGainOption] = []
    private(set) var startTimeoutPolicies: [ProcessTapLiveTimeoutPolicy] = []
    private(set) var stopReasons: [ProcessTapLiveStopReason] = []

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        startedTargets.append(target)
        startedGains.append(gain)
        startTimeoutPolicies.append(timeoutPolicy)
        onDiagnostics(
            ProcessTapLiveDiagnostics(
                selectedGain: gain,
                callbackCount: 3,
                peakLevel: 0.25,
                rmsLevel: 0.1,
                enqueuedBufferCount: 3,
                droppedBufferCount: 0,
                enqueueFailureCount: 0,
                copyFailureCount: 0
            )
        )
        return ProcessTapTestResult(
            outcome: .liveControlStarted,
            message: "Live control started",
            severity: .info
        )
    }

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        stopReasons.append(reason)
        return ProcessTapTestResult(
            outcome: .liveControlNotActive,
            message: "Live control is not active",
            severity: .info
        )
    }

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption) {}

    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult? {
        stopReasons.append(reason)
        return ProcessTapTestResult(
            outcome: .liveControlStopped,
            message: "Live control stopped",
            severity: .info
        )
    }
}

private final class FakeAdvancedLiveProcessTapTester: ProcessTapTesting, @unchecked Sendable {
    func testProcessTap(
        for target: ProcessTapTarget,
        mode: ProcessTapTestMode,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult {
        ProcessTapTestResult(
            outcome: .streamDiagnosticsNoAudio,
            message: "No audio detected",
            severity: .info
        )
    }
}

private final class FakeAdvancedLiveReplayProbe: ProcessTapReplayProbing, @unchecked Sendable {
    func runReplayProbe(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapReplayResult {
        ProcessTapReplayResult(
            outcome: .replayCompleted,
            message: "Replay probe completed",
            severity: .info
        )
    }

    func stopCurrentReplayProbe(reason: ProcessTapReplayProbeStopReason) {}
}
