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

    private func makeCoordinator(
        apps: [MixerAppItem],
        tester: FakeProcessTapDiagnosticsTester = FakeProcessTapDiagnosticsTester(),
        eligibility: @escaping @Sendable (Int32?) -> ProcessTapProcessEligibility = { _ in .eligible }
    ) -> AdvancedProcessTapDiagnosticsCoordinator {
        AdvancedProcessTapDiagnosticsCoordinator(
            processTapTester: tester,
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
