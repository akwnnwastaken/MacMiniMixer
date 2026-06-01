import XCTest
@testable import MacMiniMixer

@MainActor
final class AdvancedProcessTapDiagnosticsCoordinatorTests: XCTestCase {
    func testVisibleAppProcessTapTestUpdatesProgressAndResult() async {
        let tester = FakeProcessTapDiagnosticsTester()
        tester.progress = ProcessTapDiagnosticProgress(
            callbackCount: 4,
            peakLevel: 0.25,
            rmsLevel: 0.1,
            audioDetected: true
        )
        tester.result = ProcessTapTestResult(
            outcome: .streamDiagnosticsDetectedAudio,
            message: "Audio detected",
            severity: .info
        )
        let apps = [makeDiagnosticsApp(id: "spotify", name: "Spotify", pid: 100)]
        let coordinator = makeCoordinator(apps: apps, tester: tester)

        await coordinator.testSelectedProcessTapAppNow(
            apps: apps,
            advancedTarget: nil,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertEqual(tester.targets.map(\.appName), ["Spotify"])
        XCTAssertEqual(tester.targets.map(\.processIdentifier), [100])
        XCTAssertEqual(tester.modes, [.diagnostics])
        XCTAssertEqual(coordinator.result?.outcome, .streamDiagnosticsDetectedAudio)
        XCTAssertNil(coordinator.progress)
        XCTAssertFalse(coordinator.isRunningDiagnostics)
    }

    func testAdvancedHelperTargetIsUsedForProcessTapTest() async {
        let tester = FakeProcessTapDiagnosticsTester()
        let apps = [makeDiagnosticsApp(id: "youtube", name: "YouTube", pid: 100)]
        let coordinator = makeCoordinator(apps: apps, tester: tester)
        let helperTarget = makeAdvancedTarget(parentName: "YouTube", pid: 201)

        await coordinator.testSelectedProcessTapAppNow(
            apps: apps,
            advancedTarget: helperTarget,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertEqual(tester.targets.map(\.appName), ["com.apple.WebKit.GPU"])
        XCTAssertEqual(tester.targets.map(\.processIdentifier), [201])
        XCTAssertEqual(tester.modes, [.diagnostics])
    }

    func testMuteProbeIgnoresAdvancedHelperTargetAndUsesVisibleApp() async {
        let tester = FakeProcessTapDiagnosticsTester()
        let apps = [makeDiagnosticsApp(id: "youtube", name: "YouTube", pid: 100)]
        let coordinator = makeCoordinator(apps: apps, tester: tester)

        await coordinator.testSelectedProcessTapMuteProbeNow(
            apps: apps,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertEqual(tester.targets.map(\.appName), ["YouTube"])
        XCTAssertEqual(tester.targets.map(\.processIdentifier), [100])
        XCTAssertEqual(tester.modes, [.muteBehaviorProbe])
    }

    func testNoSelectedAppOrTargetReturnsUnavailableResult() async {
        let tester = FakeProcessTapDiagnosticsTester()
        let coordinator = makeCoordinator(apps: [], tester: tester)

        await coordinator.testSelectedProcessTapAppNow(
            apps: [],
            advancedTarget: nil,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertTrue(tester.targets.isEmpty)
        XCTAssertEqual(coordinator.result?.outcome, .invalidTarget)
        XCTAssertEqual(coordinator.result?.message, "Select a running app or Advanced target")
    }

    func testSelectionChangeClearsPreviousResultAndProgress() {
        let apps = [
            makeDiagnosticsApp(id: "spotify", name: "Spotify", pid: 100),
            makeDiagnosticsApp(id: "music", name: "Music", pid: 200)
        ]
        let coordinator = makeCoordinator(apps: apps)
        coordinator.setResult(ProcessTapTestResult(outcome: .streamDiagnosticsDetectedAudio, message: "Audio detected", severity: .info))
        coordinator.setProgress(ProcessTapDiagnosticProgress(callbackCount: 3, peakLevel: 0.2, rmsLevel: 0.1, audioDetected: true))

        let didSelect = coordinator.selectApp(
            "music",
            apps: apps,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertTrue(didSelect)
        XCTAssertEqual(coordinator.selectedAppID, "music")
        XCTAssertNil(coordinator.result)
        XCTAssertNil(coordinator.progress)
    }

    func testProgressCallbackUpdatesStateBeforeCompletion() async {
        let tester = FakeProcessTapDiagnosticsTester()
        tester.progress = ProcessTapDiagnosticProgress(
            callbackCount: 9,
            peakLevel: 0.4,
            rmsLevel: 0.2,
            audioDetected: true
        )
        let apps = [makeDiagnosticsApp(id: "spotify", name: "Spotify", pid: 100)]
        let coordinator = makeCoordinator(apps: apps, tester: tester)

        await coordinator.testSelectedProcessTapAppNow(
            apps: apps,
            advancedTarget: nil,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertEqual(tester.observedProgress, tester.progress)
    }

    func testRunningFlagClearsAfterResult() async {
        let tester = FakeProcessTapDiagnosticsTester()
        let apps = [makeDiagnosticsApp(id: "spotify", name: "Spotify", pid: 100)]
        let coordinator = makeCoordinator(apps: apps, tester: tester)

        await coordinator.testSelectedProcessTapAppNow(
            apps: apps,
            advancedTarget: nil,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertFalse(coordinator.isRunningDiagnostics)
        XCTAssertNotNil(coordinator.result)
    }

    func testSelectedAppDisappearanceSelectsPreferredFallbackAndClearsState() {
        let coordinator = makeCoordinator(apps: [makeDiagnosticsApp(id: "spotify", name: "Spotify", pid: 100)])
        coordinator.setResult(ProcessTapTestResult(outcome: .streamDiagnosticsDetectedAudio, message: "Audio detected", severity: .info))
        coordinator.setProgress(ProcessTapDiagnosticProgress(callbackCount: 3, peakLevel: 0.2, rmsLevel: 0.1, audioDetected: true))

        coordinator.selectPreferredAppAfterAppRefresh(
            apps: [makeDiagnosticsApp(id: "music", name: "Music", pid: 200)]
        )

        XCTAssertEqual(coordinator.selectedAppID, "music")
        XCTAssertNil(coordinator.result)
        XCTAssertNil(coordinator.progress)
    }

    func testExternalBusyStateBlocksStart() async {
        let tester = FakeProcessTapDiagnosticsTester()
        let apps = [makeDiagnosticsApp(id: "spotify", name: "Spotify", pid: 100)]
        let coordinator = makeCoordinator(apps: apps, tester: tester)

        await coordinator.testSelectedProcessTapAppNow(
            apps: apps,
            advancedTarget: nil,
            isLiveControlActive: true,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertTrue(tester.targets.isEmpty)
        XCTAssertNil(coordinator.result)
        XCTAssertFalse(coordinator.isRunningDiagnostics)
    }

    func testVisibleAppReplayProbeUsesSelectedVisibleApp() async {
        let replayProbe = FakeProcessTapReplayProbe()
        let apps = [makeDiagnosticsApp(id: "spotify", name: "Spotify", pid: 100)]
        let coordinator = makeCoordinator(apps: apps, replayProbe: replayProbe)

        await coordinator.testSelectedReplayProbeNow(
            apps: apps,
            advancedTarget: nil,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertEqual(replayProbe.targets.map(\.appName), ["Spotify"])
        XCTAssertEqual(replayProbe.targets.map(\.processIdentifier), [100])
        XCTAssertEqual(replayProbe.gains, [.defaultOption])
        XCTAssertEqual(coordinator.result?.outcome, .replayProbeCompleted)
        XCTAssertNil(coordinator.progress)
        XCTAssertFalse(coordinator.isRunningDiagnostics)
        XCTAssertFalse(coordinator.isReplayProbeRunning)
    }

    func testAdvancedHelperTargetIsUsedForReplayProbe() async {
        let replayProbe = FakeProcessTapReplayProbe()
        let apps = [makeDiagnosticsApp(id: "youtube", name: "YouTube", pid: 100)]
        let coordinator = makeCoordinator(apps: apps, replayProbe: replayProbe)
        let helperTarget = makeAdvancedTarget(parentName: "YouTube", pid: 201)

        await coordinator.testSelectedReplayProbeNow(
            apps: apps,
            advancedTarget: helperTarget,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertEqual(replayProbe.targets.map(\.appName), ["com.apple.WebKit.GPU"])
        XCTAssertEqual(replayProbe.targets.map(\.processIdentifier), [201])
    }

    func testReplayGainSelectionUpdatesStateAndClearsResultAndProgress() {
        let coordinator = makeCoordinator(apps: [makeDiagnosticsApp(id: "spotify", name: "Spotify", pid: 100)])
        coordinator.setResult(ProcessTapTestResult(outcome: .streamDiagnosticsDetectedAudio, message: "Audio detected", severity: .info))
        coordinator.setProgress(ProcessTapDiagnosticProgress(callbackCount: 3, peakLevel: 0.2, rmsLevel: 0.1, audioDetected: true))

        let didSelect = coordinator.selectReplayGain(
            ProcessTapReplayGainOption.options[0],
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false
        )

        XCTAssertTrue(didSelect)
        XCTAssertEqual(coordinator.selectedReplayGain, ProcessTapReplayGainOption.options[0])
        XCTAssertNil(coordinator.result)
        XCTAssertNil(coordinator.progress)
    }

    func testNoVisibleAppOrHelperTargetReturnsReplayInvalidTargetResult() async {
        let replayProbe = FakeProcessTapReplayProbe()
        let coordinator = makeCoordinator(apps: [], replayProbe: replayProbe)

        await coordinator.testSelectedReplayProbeNow(
            apps: [],
            advancedTarget: nil,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertTrue(replayProbe.targets.isEmpty)
        XCTAssertEqual(coordinator.result?.outcome, .invalidTarget)
        XCTAssertEqual(coordinator.result?.message, "Select a running app or Advanced target")
    }

    func testUnavailableHelperTargetDoesNotStartReplayProbe() async {
        let replayProbe = FakeProcessTapReplayProbe()
        let apps = [makeDiagnosticsApp(id: "youtube", name: "YouTube", pid: 100)]
        let coordinator = makeCoordinator(
            apps: apps,
            replayProbe: replayProbe,
            eligibility: { _ in .unavailable("Core Audio process unavailable") }
        )

        await coordinator.testSelectedReplayProbeNow(
            apps: apps,
            advancedTarget: makeAdvancedTarget(parentName: "YouTube", pid: 201),
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertTrue(replayProbe.targets.isEmpty)
        XCTAssertEqual(coordinator.result?.outcome, .processNotFound)
        XCTAssertEqual(coordinator.result?.message, "Advanced target unavailable")
    }

    func testReplayStartSetsRunningStateAndInitialProgress() async {
        let replayProbe = FakeProcessTapReplayProbe()
        let apps = [makeDiagnosticsApp(id: "spotify", name: "Spotify", pid: 100)]
        let coordinator = makeCoordinator(apps: apps, replayProbe: replayProbe)
        var observedRunningState = false
        var observedInitialProgress: ProcessTapDiagnosticProgress?

        replayProbe.onRun = {
            observedRunningState = coordinator.isRunningDiagnostics && coordinator.isReplayProbeRunning
            observedInitialProgress = coordinator.progress
        }

        await coordinator.testSelectedReplayProbeNow(
            apps: apps,
            advancedTarget: nil,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertTrue(observedRunningState)
        XCTAssertEqual(observedInitialProgress?.callbackCount, 0)
        XCTAssertEqual(observedInitialProgress?.audioDetected, false)
    }

    func testReplayProgressCallbackUpdatesStateBeforeCompletion() async {
        let replayProbe = FakeProcessTapReplayProbe()
        replayProbe.progress = ProcessTapDiagnosticProgress(
            callbackCount: 7,
            peakLevel: 0.3,
            rmsLevel: 0.12,
            audioDetected: true
        )
        let apps = [makeDiagnosticsApp(id: "spotify", name: "Spotify", pid: 100)]
        let coordinator = makeCoordinator(apps: apps, replayProbe: replayProbe)
        var observedProgress: ProcessTapDiagnosticProgress?

        replayProbe.onProgressSent = {
            observedProgress = coordinator.progress
        }

        await coordinator.testSelectedReplayProbeNow(
            apps: apps,
            advancedTarget: nil,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertEqual(observedProgress, replayProbe.progress)
    }

    func testStopReplayProbeForwardsReason() {
        let replayProbe = FakeProcessTapReplayProbe()
        let coordinator = makeCoordinator(apps: [], replayProbe: replayProbe)

        coordinator.stopReplayProbe(reason: .outputDeviceChanged)

        XCTAssertEqual(replayProbe.stopReasons.count, 1)
        guard case .outputDeviceChanged? = replayProbe.stopReasons.first else {
            return XCTFail("Expected output-device-change stop reason")
        }
    }

    func testReplayProbeBusyStateBlocksStart() async {
        let replayProbe = FakeProcessTapReplayProbe()
        let apps = [makeDiagnosticsApp(id: "spotify", name: "Spotify", pid: 100)]
        let coordinator = makeCoordinator(apps: apps, replayProbe: replayProbe)
        coordinator.setRunning(true)

        await coordinator.testSelectedReplayProbeNow(
            apps: apps,
            advancedTarget: nil,
            isLiveControlActive: false,
            isTwoAppReadinessRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertTrue(replayProbe.targets.isEmpty)
    }

    private func makeCoordinator(
        apps: [MixerAppItem],
        tester: FakeProcessTapDiagnosticsTester = FakeProcessTapDiagnosticsTester(),
        replayProbe: FakeProcessTapReplayProbe = FakeProcessTapReplayProbe(),
        eligibility: @escaping @Sendable (Int32?) -> ProcessTapProcessEligibility = { _ in .eligible }
    ) -> AdvancedProcessTapDiagnosticsCoordinator {
        AdvancedProcessTapDiagnosticsCoordinator(
            processTapTester: tester,
            processTapReplayProbe: replayProbe,
            initialApps: apps,
            processTapEligibility: eligibility
        )
    }
}

private final class FakeProcessTapDiagnosticsTester: ProcessTapTesting, @unchecked Sendable {
    var result = ProcessTapTestResult(
        outcome: .streamDiagnosticsNoAudio,
        message: "No audio detected",
        severity: .info
    )
    var progress = ProcessTapDiagnosticProgress(
        callbackCount: 1,
        peakLevel: 0,
        rmsLevel: 0,
        audioDetected: false
    )
    private(set) var observedProgress: ProcessTapDiagnosticProgress?
    private(set) var targets: [ProcessTapTarget] = []
    private(set) var modes: [ProcessTapTestMode] = []

    func testProcessTap(
        for target: ProcessTapTarget,
        mode: ProcessTapTestMode,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult {
        targets.append(target)
        modes.append(mode)
        observedProgress = progress
        onProgress(progress)
        return result
    }
}

private final class FakeProcessTapReplayProbe: ProcessTapReplayProbing, @unchecked Sendable {
    var result = ProcessTapReplayResult(
        outcome: .replayCompleted,
        message: "Replay probe completed",
        severity: .info
    )
    var progress = ProcessTapDiagnosticProgress(
        callbackCount: 1,
        peakLevel: 0,
        rmsLevel: 0,
        audioDetected: false
    )
    var onRun: (@MainActor () -> Void)?
    var onProgressSent: (@MainActor () -> Void)?
    private(set) var targets: [ProcessTapTarget] = []
    private(set) var gains: [ProcessTapReplayGainOption] = []
    private(set) var stopReasons: [ProcessTapReplayProbeStopReason] = []

    func runReplayProbe(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapReplayResult {
        targets.append(target)
        gains.append(gain)
        await MainActor.run {
            onRun?()
        }
        onProgress(progress)
        await MainActor.run {
            onProgressSent?()
        }
        return result
    }

    func stopCurrentReplayProbe(reason: ProcessTapReplayProbeStopReason) {
        stopReasons.append(reason)
    }
}

private func makeDiagnosticsApp(id: String, name: String, pid: Int32?) -> MixerAppItem {
    MixerAppItem(
        id: id,
        name: name,
        icon: .systemSymbol("app"),
        processIdentifier: pid,
        volume: 50
    )
}

private func makeAdvancedTarget(parentName: String, pid: Int32) -> AdvancedProcessTapTarget {
    AdvancedProcessTapTarget(
        target: ProcessTapTarget(
            appID: "helper:\(pid)",
            appName: "com.apple.WebKit.GPU",
            processIdentifier: pid
        ),
        parentAppName: parentName,
        relation: .child,
        eligibility: .eligible,
        probeResult: nil
    )
}
