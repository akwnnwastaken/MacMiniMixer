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

    func testThirtyMinuteDurationOptionHasExpectedValueAndLabel() {
        XCTAssertEqual(ProcessTapTwoAppReadinessDurationOption.thirtyMinutes.duration, 1_800)
        XCTAssertEqual(ProcessTapTwoAppReadinessDurationOption.thirtyMinutes.label, "30 min")
    }

    func testThirtyMinuteOptionAppearsExactlyOnceInAllCases() {
        let matches = ProcessTapTwoAppReadinessDurationOption.allCases.filter { $0 == .thirtyMinutes }
        XCTAssertEqual(matches.count, 1)
    }

    func testExistingDurationOptionValuesAreUnchanged() {
        XCTAssertEqual(ProcessTapTwoAppReadinessDurationOption.short.duration, 10)
        XCTAssertEqual(ProcessTapTwoAppReadinessDurationOption.oneMinute.duration, 60)
        XCTAssertEqual(ProcessTapTwoAppReadinessDurationOption.fiveMinutes.duration, 300)
    }

    func testExistingDurationOptionLabelsAndIDsAreUnchanged() {
        XCTAssertEqual(ProcessTapTwoAppReadinessDurationOption.short.label, "10s")
        XCTAssertEqual(ProcessTapTwoAppReadinessDurationOption.oneMinute.label, "1 min")
        XCTAssertEqual(ProcessTapTwoAppReadinessDurationOption.fiveMinutes.label, "5 min")
        XCTAssertEqual(ProcessTapTwoAppReadinessDurationOption.short.id, "short")
        XCTAssertEqual(ProcessTapTwoAppReadinessDurationOption.oneMinute.id, "oneMinute")
        XCTAssertEqual(ProcessTapTwoAppReadinessDurationOption.fiveMinutes.id, "fiveMinutes")
    }

    func testDefaultDurationOptionIsUnchanged() {
        XCTAssertEqual(ProcessTapTwoAppReadinessDurationOption.defaultOption, .short)
        let coordinator = makeCoordinator()
        XCTAssertEqual(coordinator.selectedDuration, .short)
    }

    func testSelectedThirtyMinuteDurationForwardsAsExactly1800Seconds() async {
        let tester = FakeCoordinatorReadinessTester()
        let coordinator = makeCoordinator(tester: tester)

        coordinator.selectDuration(.thirtyMinutes)
        XCTAssertEqual(coordinator.selectedDuration, .thirtyMinutes)

        coordinator.startTest(
            apps: makeCoordinatorApps(),
            advancedTarget: nil,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { _ in }
        )
        // Wait on the exact observable this test asserts — the duration the fake tester recorded —
        // not the coordinator's separately-propagated `.running` result. The fake appends the
        // request before returning, so this is the earliest and most direct settle signal; waiting
        // on the later `result` hop is what let this flake under loaded CI.
        await waitFor { tester.startRequests.first?.duration == 1_800 }

        XCTAssertEqual(tester.startRequests.first?.duration, 1_800)
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
        let changeSpy = CallbackSpy<Void>()
        coordinator.setOnWillChange {
            changeSpy.record(())
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

        XCTAssertGreaterThan(changeSpy.count, 0)
        XCTAssertEqual(coordinator.snapshot.sessions.map(\.appName), ["Spotify", "Music"])
    }

    func testFinishClearsRunningStateAndWarningCallbackFiresOnce() async {
        let tester = FakeCoordinatorReadinessTester()
        let coordinator = makeCoordinator(tester: tester)
        let warningSpy = CallbackSpy<String>()

        coordinator.startTest(
            apps: makeCoordinatorApps(),
            advancedTarget: nil,
            isProcessTapTesting: false,
            isLiveControlActive: false,
            isAppAudioTargetResolving: false,
            onWarning: { warningSpy.record($0) }
        )
        await waitFor { coordinator.result?.outcome == .running }

        tester.emitFinished(
            result: ProcessTapTwoAppReadinessResult(
                outcome: .timedOut,
                message: "Two-app test timed out",
                severity: .warning
            )
        )
        // Wait on the full final state the test asserts (running cleared, result settled, warning
        // delivered exactly once) instead of the `!isRunning` proxy alone. The finish callback
        // hops through `Task { @MainActor }`, so observing only `!isRunning` could race ahead of
        // the warning record under load; this single combined condition removes that window.
        await waitFor {
            !coordinator.isRunning
                && coordinator.result?.outcome == .timedOut
                && warningSpy.values == ["Two-app test timed out"]
        }

        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(coordinator.result?.outcome, .timedOut)
        XCTAssertEqual(warningSpy.values, ["Two-app test timed out"])
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

    // MARK: - Aggregate cleanup-failure reporting (Faz 4f-1)
    //
    // These exercise the pure aggregation `TwoAppReadinessState.aggregateResult(reason:snapshot:)`
    // directly with synthesized snapshots. They prove a per-session cleanup failure is surfaced
    // (not masked under a normal timeout/stopped result) and that the clean path is unchanged.
    // NOTE: these fakes model only per-session result/phase forwarding — they do NOT and cannot
    // reproduce real Core Audio Process Tap destroy behavior, the muted-tap symptom, or audio
    // glitches; those remain real-hardware concerns.

    func testTimeoutWithAppACleanupFailureIsNotReportedAsCleanTimeout() {
        let snapshot = makeReadinessSnapshot(
            appA: failedSession(slot: .appA, appName: "Spotify", detail: "destroy tap 'who?'"),
            appB: cleanSession(slot: .appB, appName: "Music")
        )

        let result = TwoAppReadinessState.aggregateResult(reason: .timedOut, snapshot: snapshot)

        XCTAssertNotEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.outcome, .cleanupWarning)
        XCTAssertEqual(result.severity, .warning)
        XCTAssertTrue(result.detail?.contains("Spotify") == true)
        XCTAssertTrue(result.detail?.contains("destroy tap 'who?'") == true)
    }

    func testUserStopWithAppBCleanupFailureIsNotReportedAsCleanStop() {
        let snapshot = makeReadinessSnapshot(
            appA: cleanSession(slot: .appA, appName: "Spotify"),
            appB: failedSession(slot: .appB, appName: "Music", detail: "destroy aggregate 'err'")
        )

        let result = TwoAppReadinessState.aggregateResult(reason: .userStopped, snapshot: snapshot)

        XCTAssertNotEqual(result.outcome, .stopped)
        XCTAssertEqual(result.outcome, .cleanupWarning)
        XCTAssertEqual(result.severity, .warning)
        XCTAssertTrue(result.detail?.contains("Music") == true)
        XCTAssertTrue(result.detail?.contains("destroy aggregate 'err'") == true)
    }

    func testOneCleanOneFailedKeepsFailureAndNotesCleanSession() {
        let snapshot = makeReadinessSnapshot(
            appA: cleanSession(slot: .appA, appName: "Spotify"),
            appB: failedSession(slot: .appB, appName: "Music", detail: "destroy tap 'err'")
        )

        let result = TwoAppReadinessState.aggregateResult(reason: .timedOut, snapshot: snapshot)

        XCTAssertEqual(result.outcome, .cleanupWarning)
        // Failed session info is not lost...
        XCTAssertTrue(result.detail?.contains("Music") == true)
        XCTAssertTrue(result.detail?.contains("destroy tap 'err'") == true)
        // ...and the clean session is still acknowledged.
        XCTAssertTrue(result.detail?.contains("Spotify") == true)
    }

    func testBothSessionsCleanupFailureSurfaceBothInDetail() {
        let snapshot = makeReadinessSnapshot(
            appA: failedSession(slot: .appA, appName: "Spotify", detail: "destroy tap A"),
            appB: failedSession(slot: .appB, appName: "Music", detail: "destroy tap B")
        )

        let result = TwoAppReadinessState.aggregateResult(reason: .userStopped, snapshot: snapshot)

        XCTAssertEqual(result.outcome, .cleanupWarning)
        XCTAssertEqual(result.severity, .warning)
        XCTAssertTrue(result.detail?.contains("Spotify") == true)
        XCTAssertTrue(result.detail?.contains("destroy tap A") == true)
        XCTAssertTrue(result.detail?.contains("Music") == true)
        XCTAssertTrue(result.detail?.contains("destroy tap B") == true)
    }

    func testTwoCleanSessionsTimeoutKeepsExistingTimedOutResult() {
        let snapshot = makeReadinessSnapshot(
            appA: cleanSession(slot: .appA, appName: "Spotify"),
            appB: cleanSession(slot: .appB, appName: "Music")
        )

        let result = TwoAppReadinessState.aggregateResult(reason: .timedOut, snapshot: snapshot)

        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.message, "Two-app test stopped: timeout")
        XCTAssertEqual(result.severity, .warning)
    }

    func testTwoCleanSessionsUserStopKeepsExistingStoppedResult() {
        let snapshot = makeReadinessSnapshot(
            appA: cleanSession(slot: .appA, appName: "Spotify"),
            appB: cleanSession(slot: .appB, appName: "Music")
        )

        let result = TwoAppReadinessState.aggregateResult(reason: .userStopped, snapshot: snapshot)

        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(result.message, "Two-app test stopped")
        XCTAssertEqual(result.severity, .info)
    }

    func testTwoCleanSessionsSystemSleepKeepsControlledStoppedResult() {
        let snapshot = makeReadinessSnapshot(
            appA: cleanSession(slot: .appA, appName: "Spotify"),
            appB: cleanSession(slot: .appB, appName: "Music")
        )

        let result = TwoAppReadinessState.aggregateResult(reason: .systemSleep, snapshot: snapshot)

        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(result.message, "Two-app test stopped: system sleep")
        XCTAssertEqual(result.severity, .info)
    }

    func testTwoCleanSessionsOutputDeviceChangeKeepsExistingOutcome() {
        let snapshot = makeReadinessSnapshot(
            appA: cleanSession(slot: .appA, appName: "Spotify"),
            appB: cleanSession(slot: .appB, appName: "Music")
        )

        let result = TwoAppReadinessState.aggregateResult(reason: .outputDeviceChanged, snapshot: snapshot)

        XCTAssertEqual(result.outcome, .outputDeviceChanged)
        XCTAssertEqual(result.message, "Two-app test stopped: output changed")
        XCTAssertEqual(result.severity, .warning)
    }

    private func cleanSession(
        slot: ProcessTapTwoAppReadinessSlot,
        appName: String
    ) -> ProcessTapTwoAppReadinessSessionSnapshot {
        ProcessTapTwoAppReadinessSessionSnapshot(
            slot: slot,
            sessionID: ProcessTapLiveSessionID(),
            appName: appName,
            phase: .stopped,
            selectedGain: ProcessTapReplayGainOption.options[0],
            diagnostics: nil,
            message: nil
        )
    }

    private func failedSession(
        slot: ProcessTapTwoAppReadinessSlot,
        appName: String,
        detail: String
    ) -> ProcessTapTwoAppReadinessSessionSnapshot {
        ProcessTapTwoAppReadinessSessionSnapshot(
            slot: slot,
            sessionID: ProcessTapLiveSessionID(),
            appName: appName,
            phase: .failed,
            selectedGain: ProcessTapReplayGainOption.options[0],
            diagnostics: nil,
            message: "Live control cleanup warning",
            cleanupFailureDetail: detail
        )
    }

    private func makeReadinessSnapshot(
        appA: ProcessTapTwoAppReadinessSessionSnapshot,
        appB: ProcessTapTwoAppReadinessSessionSnapshot
    ) -> ProcessTapTwoAppReadinessSnapshot {
        ProcessTapTwoAppReadinessSnapshot(sessions: [appA, appB])
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

/// Thread-safe sink for callbacks (onWarning / onWillChange). The coordinator invokes these
/// from `Task { @MainActor }` continuations while the test asserts on the MainActor; recording
/// through a lock removes the raw captured-`var` data race that made finish-callback tests flake
/// under full-suite load.
private final class CallbackSpy<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func record(_ value: Value) {
        lock.withLock { storage.append(value) }
    }

    var values: [Value] {
        lock.withLock { storage }
    }

    var count: Int {
        lock.withLock { storage.count }
    }
}

private final class FakeCoordinatorReadinessTester: ProcessTapTwoAppReadinessTesting, @unchecked Sendable {
    // The coordinator drives these methods from an off-MainActor task while tests read the
    // recorded arrays on the MainActor. Guard all mutable state with a lock and run callbacks
    // outside the lock, so reads are never racing a partial mutation (the source of the CI flake).
    private let lock = NSLock()
    private var startRequestsStorage: [(appA: ProcessTapTarget, appB: ProcessTapTarget, gain: ProcessTapReplayGainOption, duration: TimeInterval)] = []
    private var stopReasonsStorage: [ProcessTapLiveStopReason] = []
    private var lastSnapshot = ProcessTapTwoAppReadinessSnapshot.empty
    private var onFinished: (@Sendable (ProcessTapTwoAppReadinessResult, ProcessTapTwoAppReadinessSnapshot) -> Void)?

    var startRequests: [(appA: ProcessTapTarget, appB: ProcessTapTarget, gain: ProcessTapReplayGainOption, duration: TimeInterval)] {
        lock.withLock { startRequestsStorage }
    }

    var stopReasons: [ProcessTapLiveStopReason] {
        lock.withLock { stopReasonsStorage }
    }

    func startTest(
        appA: ProcessTapTarget,
        appB: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        duration: TimeInterval,
        onUpdate: @escaping @Sendable (ProcessTapTwoAppReadinessSnapshot) -> Void,
        onFinished: @escaping @Sendable (ProcessTapTwoAppReadinessResult, ProcessTapTwoAppReadinessSnapshot) -> Void
    ) async -> ProcessTapTwoAppReadinessResult {
        let snapshot = ProcessTapTwoAppReadinessSnapshot(
            sessions: [
                activeSnapshot(slot: .appA, target: appA, gain: gain),
                activeSnapshot(slot: .appB, target: appB, gain: gain)
            ]
        )
        lock.withLock {
            startRequestsStorage.append((appA, appB, gain, duration))
            self.onFinished = onFinished
            lastSnapshot = snapshot
        }
        onUpdate(snapshot)
        return ProcessTapTwoAppReadinessResult(
            outcome: .running,
            message: "Two-app test running",
            severity: .info
        )
    }

    func stopAll(reason: ProcessTapLiveStopReason) async -> ProcessTapTwoAppReadinessResult {
        let result = stopResult(for: reason)
        let (snapshot, finished) = lock.withLock { () -> (ProcessTapTwoAppReadinessSnapshot, (@Sendable (ProcessTapTwoAppReadinessResult, ProcessTapTwoAppReadinessSnapshot) -> Void)?) in
            stopReasonsStorage.append(reason)
            let snapshot = stoppedSnapshot(from: lastSnapshot)
            lastSnapshot = snapshot
            return (snapshot, onFinished)
        }
        finished?(result, snapshot)
        return result
    }

    func stopAllNow(reason: ProcessTapLiveStopReason) -> ProcessTapTwoAppReadinessResult? {
        lock.withLock { () -> ProcessTapTwoAppReadinessResult? in
            guard !lastSnapshot.sessions.isEmpty else {
                return nil
            }

            stopReasonsStorage.append(reason)
            return stopResult(for: reason)
        }
    }

    func emitFinished(result: ProcessTapTwoAppReadinessResult) {
        let (snapshot, finished) = lock.withLock { () -> (ProcessTapTwoAppReadinessSnapshot, (@Sendable (ProcessTapTwoAppReadinessResult, ProcessTapTwoAppReadinessSnapshot) -> Void)?) in
            let snapshot = stoppedSnapshot(from: lastSnapshot)
            lastSnapshot = snapshot
            return (snapshot, onFinished)
        }
        finished?(result, snapshot)
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
