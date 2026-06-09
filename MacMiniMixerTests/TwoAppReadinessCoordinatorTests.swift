import XCTest
@testable import MacMiniMixer

@MainActor
final class TwoAppReadinessCoordinatorTests: XCTestCase {
    func testVisibleTargetsAreExposedAndInitialSelectionsPreferFirstTwoEligibleApps() {
        let coordinator = makeCoordinator()
        let targets = coordinator.targetOptions(apps: makeCoordinatorApps(), advancedTarget: nil)

        XCTAssertEqual(targets.filter { !$0.isHelper }.map(\.id), ["spotify", "music", "youtube"])
        XCTAssertEqual(coordinator.selectedAppAID, "spotify")
        XCTAssertEqual(coordinator.selectedAppBID, "music")
    }

    func testAdvancedHelperTargetIsIncludedWhenEligible() {
        let coordinator = makeCoordinator(eligibilityByPID: [201: .eligible])
        let helper = makeAdvancedTarget(pid: 201)

        let helperTarget = coordinator.targetOptions(
            apps: makeCoordinatorApps(),
            advancedTarget: helper
        ).first { $0.isHelper }

        XCTAssertEqual(helperTarget?.target.processIdentifier, 201)
        XCTAssertEqual(helperTarget?.title, "Helper: YouTube PID 201")
    }

    func testDuplicateSameProcessSelectionsAreRejectedBeforeServiceStart() {
        let tester = FakeCoordinatorReadinessTester()
        let apps = [
            makeCoordinatorApp(id: "spotify", name: "Spotify", pid: 101),
            makeCoordinatorApp(id: "spotify-copy", name: "Spotify Copy", pid: 101)
        ]
        let coordinator = makeCoordinator(apps: apps, tester: tester)

        coordinator.startTest(
            apps: apps,
            advancedTarget: nil,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { _ in }
        )

        XCTAssertTrue(tester.startRequests.isEmpty)
        XCTAssertEqual(coordinator.result?.outcome, .invalidTarget)
        XCTAssertEqual(coordinator.result?.message, "Choose two different process targets")
    }

    func testVisibleAppPlusVisibleAppStartForwardsTargetsAndGain() async {
        let tester = FakeCoordinatorReadinessTester()
        let coordinator = makeCoordinator(tester: tester)
        let gain = ProcessTapReplayGainOption.options[0]

        coordinator.selectGain(gain)
        coordinator.startTest(
            apps: makeCoordinatorApps(),
            advancedTarget: nil,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { _ in }
        )
        await waitFor { coordinator.result?.outcome == .running }

        let request = tester.startRequests.first
        XCTAssertEqual(request?.appA.appID, "spotify")
        XCTAssertEqual(request?.appA.processIdentifier, 101)
        XCTAssertEqual(request?.appB.appID, "music")
        XCTAssertEqual(request?.appB.processIdentifier, 102)
        XCTAssertEqual(request?.gain, gain)
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertEqual(coordinator.result?.outcome, .running)
    }

    func testSelectedDurationForwardsToTester() async {
        let tester = FakeCoordinatorReadinessTester()
        let coordinator = makeCoordinator(tester: tester)

        XCTAssertEqual(coordinator.selectedDuration, .short)
        coordinator.selectDuration(.fiveMinutes)
        XCTAssertEqual(coordinator.selectedDuration, .fiveMinutes)

        coordinator.startTest(
            apps: makeCoordinatorApps(),
            advancedTarget: nil,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { _ in }
        )
        await waitFor { coordinator.result?.outcome == .running }

        XCTAssertEqual(tester.startRequests.first?.duration, ProcessTapTwoAppReadinessDurationOption.fiveMinutes.duration)
    }

    func testDurationSelectionIsBlockedWhileRunning() async {
        let tester = FakeCoordinatorReadinessTester()
        let coordinator = makeCoordinator(tester: tester)

        coordinator.startTest(
            apps: makeCoordinatorApps(),
            advancedTarget: nil,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { _ in }
        )
        await waitFor { coordinator.isRunning }

        coordinator.selectDuration(.oneMinute)

        XCTAssertEqual(coordinator.selectedDuration, .short)
    }

    func testVisibleAppPlusHelperTargetStartForwardsHelperPID() async throws {
        let tester = FakeCoordinatorReadinessTester()
        let helper = makeAdvancedTarget(pid: 201)
        let coordinator = makeCoordinator(tester: tester, eligibilityByPID: [201: .eligible])
        let targets = coordinator.targetOptions(apps: makeCoordinatorApps(), advancedTarget: helper)
        let helperID = try XCTUnwrap(targets.first { $0.isHelper }?.id)

        coordinator.selectAppA("spotify", targets: targets)
        coordinator.selectAppB(helperID, targets: targets)
        coordinator.startTest(
            apps: makeCoordinatorApps(),
            advancedTarget: helper,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { _ in }
        )
        await waitFor { tester.startRequests.count == 1 }

        let request = tester.startRequests.first
        XCTAssertEqual(request?.appA.processIdentifier, 101)
        XCTAssertEqual(request?.appB.processIdentifier, 201)
        XCTAssertEqual(request?.appB.appName, "Helper: YouTube PID 201")
    }

    func testMissingTargetsBlockStart() {
        let tester = FakeCoordinatorReadinessTester()
        let apps = [makeCoordinatorApp(id: "spotify", name: "Spotify", pid: 101)]
        let coordinator = makeCoordinator(apps: apps, tester: tester)

        coordinator.startTest(
            apps: apps,
            advancedTarget: nil,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { _ in }
        )

        XCTAssertTrue(tester.startRequests.isEmpty)
        XCTAssertEqual(coordinator.result?.outcome, .invalidTarget)
        XCTAssertEqual(coordinator.result?.message, "Select two targets")
    }

    func testStartIsBlockedByBusyStates() {
        let cases: [(testing: Bool, live: Bool, resolving: Bool)] = [
            (true, false, false),
            (false, true, false),
            (false, false, true)
        ]

        for busyCase in cases {
            let tester = FakeCoordinatorReadinessTester()
            let coordinator = makeCoordinator(tester: tester)

            coordinator.startTest(
                apps: makeCoordinatorApps(),
                advancedTarget: nil,
                isProcessTapTesting: busyCase.testing,
                isLiveControlActive: busyCase.live,
                isAppAudioTargetResolving: busyCase.resolving,
                onWarning: { _ in }
            )

            XCTAssertTrue(tester.startRequests.isEmpty)
            XCTAssertEqual(coordinator.result?.outcome, .setupFailed)
            XCTAssertEqual(coordinator.result?.message, "Stop active Process Tap work first")
        }
    }

    func testSnapshotUpdatesNotifyAndAreStored() async {
        let tester = FakeCoordinatorReadinessTester()
        let coordinator = makeCoordinator(tester: tester)
        var changeCount = 0
        coordinator.setOnWillChange {
            changeCount += 1
        }

        coordinator.startTest(
            apps: makeCoordinatorApps(),
            advancedTarget: nil,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { _ in }
        )
        await waitFor { coordinator.snapshot.sessions.map(\.phase) == [.active, .active] }

        XCTAssertGreaterThan(changeCount, 0)
        XCTAssertEqual(coordinator.snapshot.sessions.map(\.appName), ["Spotify", "Music"])
    }

    func testFinishClearsRunningStateAndWarningCallbackFiresOnce() async {
        let tester = FakeCoordinatorReadinessTester()
        let coordinator = makeCoordinator(tester: tester)
        var warnings: [String] = []

        coordinator.startTest(
            apps: makeCoordinatorApps(),
            advancedTarget: nil,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { warnings.append($0) }
        )
        await waitFor { coordinator.result?.outcome == .running }

        tester.emitFinished(
            result: ProcessTapTwoAppReadinessResult(
                outcome: .timedOut,
                message: "Two-app test timed out",
                severity: .warning
            )
        )
        await waitFor { !coordinator.isRunning }

        XCTAssertEqual(coordinator.result?.outcome, .timedOut)
        XCTAssertEqual(warnings, ["Two-app test timed out"])
    }

    func testExplicitStopAllForwardsUserStopped() async {
        let tester = FakeCoordinatorReadinessTester()
        let coordinator = makeCoordinator(tester: tester)

        coordinator.startTest(
            apps: makeCoordinatorApps(),
            advancedTarget: nil,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { _ in }
        )
        await waitFor { coordinator.isRunning }

        coordinator.stop(reason: .userStopped)
        await waitFor { !tester.stopReasons.isEmpty }

        XCTAssertEqual(tester.stopReasons, [.userStopped])
        await waitFor { !coordinator.isRunning }
    }

    func testOutputDeviceStopForwardsReason() async {
        let tester = FakeCoordinatorReadinessTester()
        let coordinator = makeCoordinator(tester: tester)

        coordinator.startTest(
            apps: makeCoordinatorApps(),
            advancedTarget: nil,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { _ in }
        )
        await waitFor { coordinator.isRunning }

        coordinator.stop(reason: .outputDeviceChanged)
        await waitFor { !tester.stopReasons.isEmpty }

        XCTAssertEqual(tester.stopReasons, [.outputDeviceChanged])
    }

    func testAppRefreshRepairsDisappearedSelectionsWhenIdle() {
        let coordinator = makeCoordinator()
        let refreshedApps = [
            makeCoordinatorApp(id: "music", name: "Music", pid: 102),
            makeCoordinatorApp(id: "youtube", name: "YouTube", pid: 200)
        ]

        coordinator.refreshEligibility(apps: refreshedApps)
        coordinator.refreshSelectionsAfterAppRefresh(
            targets: coordinator.targetOptions(apps: refreshedApps, advancedTarget: nil)
        )

        XCTAssertEqual(coordinator.selectedAppAID, "music")
        XCTAssertEqual(coordinator.selectedAppBID, "youtube")
    }

    func testHelperTargetRemovalWhileIdleClearsAndRepairsSelection() throws {
        let helper = makeAdvancedTarget(pid: 201)
        let coordinator = makeCoordinator(eligibilityByPID: [201: .eligible])
        let targetsWithHelper = coordinator.targetOptions(apps: makeCoordinatorApps(), advancedTarget: helper)
        let helperID = try XCTUnwrap(targetsWithHelper.first { $0.isHelper }?.id)
        coordinator.selectAppB(helperID, targets: targetsWithHelper)

        coordinator.handleRemovedTarget(
            id: helperID,
            targets: coordinator.targetOptions(apps: makeCoordinatorApps(), advancedTarget: nil)
        )

        XCTAssertEqual(coordinator.selectedAppAID, "spotify")
        XCTAssertEqual(coordinator.selectedAppBID, "music")
    }

    func testHelperTargetRemovalWhileRunningStopsSafely() async throws {
        let tester = FakeCoordinatorReadinessTester()
        let helper = makeAdvancedTarget(pid: 201)
        let coordinator = makeCoordinator(tester: tester, eligibilityByPID: [201: .eligible])
        let targets = coordinator.targetOptions(apps: makeCoordinatorApps(), advancedTarget: helper)
        let helperID = try XCTUnwrap(targets.first { $0.isHelper }?.id)
        coordinator.selectAppB(helperID, targets: targets)

        coordinator.startTest(
            apps: makeCoordinatorApps(),
            advancedTarget: helper,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { _ in }
        )
        await waitFor { coordinator.isRunning }

        coordinator.handleRemovedTarget(
            id: helperID,
            targets: coordinator.targetOptions(apps: makeCoordinatorApps(), advancedTarget: nil)
        )
        await waitFor { !tester.stopReasons.isEmpty }

        XCTAssertEqual(tester.stopReasons, [.userStopped])
    }

    func testStopNowForTerminationIsSafeWhenActiveAndIdle() async {
        let activeTester = FakeCoordinatorReadinessTester()
        let activeCoordinator = makeCoordinator(tester: activeTester)
        activeCoordinator.startTest(
            apps: makeCoordinatorApps(),
            advancedTarget: nil,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { _ in }
        )
        await waitFor { activeCoordinator.result?.outcome == .running }

        _ = activeCoordinator.stopNow(reason: .appTerminating)

        XCTAssertEqual(activeTester.stopReasons, [.appTerminating])
        XCTAssertFalse(activeCoordinator.isRunning)

        let idleTester = FakeCoordinatorReadinessTester()
        let idleCoordinator = makeCoordinator(tester: idleTester)

        XCTAssertNil(idleCoordinator.stopNow(reason: .appTerminating))
        XCTAssertTrue(idleTester.stopReasons.isEmpty)
    }

    private func makeCoordinator(
        apps: [MixerAppItem] = makeCoordinatorApps(),
        tester: FakeCoordinatorReadinessTester = FakeCoordinatorReadinessTester(),
        eligibilityByPID: [Int32: ProcessTapProcessEligibility] = [:]
    ) -> TwoAppReadinessCoordinator {
        TwoAppReadinessCoordinator(
            tester: tester,
            initialApps: apps,
            processTapEligibility: { processIdentifier in
                guard let processIdentifier else {
                    return .unavailable("Core Audio process unavailable")
                }

                return eligibilityByPID[processIdentifier] ?? .eligible
            }
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
}

private func makeCoordinatorApps() -> [MixerAppItem] {
    [
        makeCoordinatorApp(id: "spotify", name: "Spotify", pid: 101),
        makeCoordinatorApp(id: "music", name: "Music", pid: 102),
        makeCoordinatorApp(id: "youtube", name: "YouTube", pid: 200)
    ]
}

private func makeCoordinatorApp(id: String, name: String, pid: Int32?) -> MixerAppItem {
    MixerAppItem(
        id: id,
        name: name,
        icon: .systemSymbol("music.note"),
        processIdentifier: pid,
        volume: 50
    )
}

private func makeAdvancedTarget(pid: Int32) -> AdvancedProcessTapTarget {
    AdvancedProcessTapTarget(
        target: ProcessTapTarget(
            appID: "helper:youtube:\(pid)",
            appName: "com.apple.WebKit.GPU",
            processIdentifier: pid
        ),
        parentAppName: "YouTube",
        relation: .child,
        eligibility: .eligible,
        probeResult: ProcessTapTestResult(outcome: .streamDiagnosticsDetectedAudio, message: "Audio detected", severity: .info)
    )
}

private final class FakeCoordinatorReadinessTester: ProcessTapTwoAppReadinessTesting, @unchecked Sendable {
    private(set) var startRequests: [(appA: ProcessTapTarget, appB: ProcessTapTarget, gain: ProcessTapReplayGainOption, duration: TimeInterval)] = []
    private(set) var stopReasons: [ProcessTapLiveStopReason] = []
    private var lastSnapshot = ProcessTapTwoAppReadinessSnapshot.empty
    private var onFinished: (@Sendable (ProcessTapTwoAppReadinessResult, ProcessTapTwoAppReadinessSnapshot) -> Void)?

    func startTest(
        appA: ProcessTapTarget,
        appB: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        duration: TimeInterval,
        onUpdate: @escaping @Sendable (ProcessTapTwoAppReadinessSnapshot) -> Void,
        onFinished: @escaping @Sendable (ProcessTapTwoAppReadinessResult, ProcessTapTwoAppReadinessSnapshot) -> Void
    ) async -> ProcessTapTwoAppReadinessResult {
        startRequests.append((appA, appB, gain, duration))
        self.onFinished = onFinished
        lastSnapshot = ProcessTapTwoAppReadinessSnapshot(
            sessions: [
                activeSnapshot(slot: .appA, target: appA, gain: gain),
                activeSnapshot(slot: .appB, target: appB, gain: gain)
            ]
        )
        onUpdate(lastSnapshot)
        return ProcessTapTwoAppReadinessResult(
            outcome: .running,
            message: "Two-app test running",
            severity: .info
        )
    }

    func stopAll(reason: ProcessTapLiveStopReason) async -> ProcessTapTwoAppReadinessResult {
        stopReasons.append(reason)
        let result = stopResult(for: reason)
        let snapshot = stoppedSnapshot(from: lastSnapshot)
        lastSnapshot = snapshot
        onFinished?(result, snapshot)
        return result
    }

    func stopAllNow(reason: ProcessTapLiveStopReason) -> ProcessTapTwoAppReadinessResult? {
        guard !lastSnapshot.sessions.isEmpty else {
            return nil
        }

        stopReasons.append(reason)
        return stopResult(for: reason)
    }

    func emitFinished(result: ProcessTapTwoAppReadinessResult) {
        let snapshot = stoppedSnapshot(from: lastSnapshot)
        lastSnapshot = snapshot
        onFinished?(result, snapshot)
    }

    private func activeSnapshot(
        slot: ProcessTapTwoAppReadinessSlot,
        target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption
    ) -> ProcessTapTwoAppReadinessSessionSnapshot {
        ProcessTapTwoAppReadinessSessionSnapshot(
            slot: slot,
            sessionID: ProcessTapLiveSessionID(),
            appName: target.appName,
            phase: .active,
            selectedGain: gain,
            diagnostics: nil,
            message: nil
        )
    }

    private func stoppedSnapshot(
        from snapshot: ProcessTapTwoAppReadinessSnapshot
    ) -> ProcessTapTwoAppReadinessSnapshot {
        ProcessTapTwoAppReadinessSnapshot(
            sessions: snapshot.sessions.map { session in
                ProcessTapTwoAppReadinessSessionSnapshot(
                    slot: session.slot,
                    sessionID: session.sessionID,
                    appName: session.appName,
                    phase: .stopped,
                    selectedGain: session.selectedGain,
                    diagnostics: session.diagnostics,
                    message: session.message
                )
            }
        )
    }

    private func stopResult(for reason: ProcessTapLiveStopReason) -> ProcessTapTwoAppReadinessResult {
        switch reason {
        case .outputDeviceChanged:
            return ProcessTapTwoAppReadinessResult(
                outcome: .outputDeviceChanged,
                message: "Two-app test stopped: output device changed",
                severity: .warning
            )
        case .targetAppExited:
            return ProcessTapTwoAppReadinessResult(
                outcome: .appExited,
                message: "Two-app test stopped: app exited",
                severity: .warning
            )
        case .timedOut:
            return ProcessTapTwoAppReadinessResult(
                outcome: .timedOut,
                message: "Two-app test timed out",
                severity: .warning
            )
        default:
            return ProcessTapTwoAppReadinessResult(
                outcome: .stopped,
                message: "Two-app test stopped",
                severity: .info
            )
        }
    }
}
