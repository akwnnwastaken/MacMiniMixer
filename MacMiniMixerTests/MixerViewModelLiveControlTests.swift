import XCTest
@testable import MacMiniMixer

@MainActor
final class MixerViewModelLiveControlTests: XCTestCase {
    func testManualAdvancedLiveStartsSelectedVisibleAppOnly() async {
        let harness = makeHarness()
        harness.viewModel.selectProcessTapApp("music")

        harness.viewModel.startProcessTapLiveControl()
        await waitFor { harness.liveController.startedTargets.count == 1 }

        XCTAssertEqual(harness.liveController.startedTargets.map(\.appID), ["music"])
        XCTAssertEqual(harness.liveController.startedTargets.map(\.processIdentifier), [102])
        XCTAssertEqual(harness.liveController.startedTargets.map(\.appName), ["Music"])
        XCTAssertEqual(
            harness.liveController.startTimeoutPolicies,
            [.limited(AppConstants.processTapLiveControlMaxDuration)]
        )
    }

    func testManualAdvancedLiveIgnoresAdvancedHelperTarget() async {
        let processLister = FakeLiveControlProcessLister(processes: [
            SystemProcessInfo(processIdentifier: 200, parentProcessIdentifier: nil, name: "YouTube", executablePath: nil),
            SystemProcessInfo(processIdentifier: 201, parentProcessIdentifier: 200, name: "com.apple.WebKit.GPU", executablePath: nil)
        ])
        let harness = makeHarness(processLister: processLister)
        harness.viewModel.selectProcessTapApp("spotify")
        harness.viewModel.selectHelperDiscoveryApp("youtube")
        harness.viewModel.scanHelperProcesses()
        await waitFor { !harness.viewModel.helperProcessCandidates.isEmpty }

        harness.viewModel.useHelperCandidateAsAdvancedTarget(201)
        XCTAssertNotNil(harness.viewModel.advancedProcessTapTarget)

        harness.viewModel.startProcessTapLiveControl()
        await waitFor { harness.liveController.startedTargets.count == 1 }

        XCTAssertEqual(harness.liveController.startedTargets.first?.appID, "spotify")
        XCTAssertEqual(harness.liveController.startedTargets.first?.processIdentifier, 101)
    }

    func testProductDirectVisiblePIDStartUsesInteractedRowApp() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(42, for: "music")
        await waitFor { harness.liveController.startedTargets.count == 1 }

        XCTAssertEqual(harness.liveController.startedTargets.first?.appID, "music")
        XCTAssertEqual(harness.liveController.startedTargets.first?.appName, "Music")
        XCTAssertEqual(harness.liveController.startedTargets.first?.processIdentifier, 102)
        XCTAssertEqual(harness.liveController.startTimeoutPolicies, [.indefinite])
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "music")
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "Music")
    }

    func testProductHelperResolverStartUsesResolvedHelperPIDAndVisibleRowName() async {
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        ])
        let harness = makeHarness(
            appAudioTargetResolver: resolver,
            eligibilityByPID: [
                200: .unavailable("Core Audio process unavailable"),
                201: .eligible
            ]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(35, for: "youtube")
        await waitFor { harness.liveController.startedTargets.count == 1 }

        XCTAssertEqual(resolver.resolveRequests.map(\.appID), ["youtube"])
        XCTAssertEqual(harness.liveController.startedTargets.first?.processIdentifier, 201)
        XCTAssertEqual(harness.liveController.startedTargets.first?.appName, "YouTube")
        XCTAssertEqual(harness.liveController.startTimeoutPolicies, [.indefinite])
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "youtube")
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "YouTube")
    }

    // Multi-app invariant: confirmed Product sessions have no app-count limit by default (see
    // testThirdProductSessionAllowed / testFourthProductSessionAllowedWithDefaultUnlimitedLimit /
    // testManyProductSessionsRunConcurrentlyThroughRealSessionManagerWithDefaultLimit); an injected
    // cap is covered in ProductRealControlCoordinatorTests. What this test pins is the transient
    // *serialization* (queued start lane): while one Product start is still in flight (pending,
    // unconfirmed), a second Product start is QUEUED — not rejected — and only reaches the controller
    // once the first start finishes, while an Advanced Manual start is still rejected outright.
    // (Formerly testPendingProductStartBlocksAnotherProductAndManualStart, when the second Product
    // start was rejected with "Stop active live control first".)
    func testPendingProductStartQueuesAnotherProductStartButBlocksManualStart() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        // Spotify Product start is held in flight (its completion is suspended), so the start lane
        // and the shared "running" flag (isProcessTapTesting) are deterministically busy. Wait on real
        // state signals — the start reached the controller (pendingStartCount) AND the view model
        // marked itself busy (isProcessTapTesting) — not a fixed sleep/yield count.
        harness.viewModel.setAppVolume(40, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 && harness.viewModel.isProcessTapTesting }

        // While the first start is pending, attempt a second Product start and a manual start. Both
        // are handled synchronously: Music is queued (pending row, no warning), manual is rejected.
        harness.viewModel.setAppVolume(60, for: "music")
        harness.viewModel.startProcessTapLiveControl()

        XCTAssertEqual(controller.startedTargets.map(\.appID), ["spotify"])
        XCTAssertEqual(controller.pendingStartCount, 1)
        XCTAssertEqual(controller.legacyManualStartCount, 0)
        XCTAssertTrue(harness.viewModel.isExperimentalControlPending(for: "music"))
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertNil(harness.viewModel.statusMessage)

        // Completing the first start drains the queue: Music's start reaches the controller next.
        controller.completeNextStart(success: true)
        await waitFor {
            harness.viewModel.isExperimentalControlActive(for: "spotify")
                && controller.pendingStartCount == 1
                && controller.startedTargets.count == 2
        }
        XCTAssertEqual(controller.startedTargets.map(\.appID), ["spotify", "music"])

        controller.completeNextStart(success: true)
        await waitFor {
            harness.viewModel.isExperimentalControlActive(for: "music")
                && !harness.viewModel.isExperimentalControlPending(for: "music")
                && !harness.viewModel.isProcessTapTesting
        }
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertEqual(controller.legacyManualStartCount, 0)
        XCTAssertNil(harness.viewModel.statusMessage)
    }

    // MARK: - Queued Product start lane

    // A slider start for a direct-PID app while another app's helper resolution is in flight is queued
    // (no "Finish resolving app audio first"), then starts — with the slider's latest gain — once the
    // resolution finishes.
    func testSliderStartForDirectAppWhileHelperResolvingIsQueuedThenStarts() async {
        let resolver = FakeAppAudioTargetResolver(suspendsWhenNoResultIsAvailable: true)
        let harness = makeHarness(
            appAudioTargetResolver: resolver,
            eligibilityByPID: [200: .unavailable("Core Audio process unavailable"), 201: .eligible]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(45, for: "youtube")
        await waitFor { resolver.resolveRequests.count == 1 }
        XCTAssertTrue(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))

        harness.viewModel.setAppVolume(60, for: "spotify")
        harness.viewModel.setAppVolume(65, for: "spotify")

        XCTAssertTrue(harness.viewModel.isExperimentalControlPending(for: "spotify"))
        XCTAssertNil(harness.viewModel.statusMessage)
        XCTAssertTrue(harness.liveController.startedTargets.isEmpty)

        resolver.completeNext(.unavailable("No active audio helper found"))
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        XCTAssertEqual(harness.liveController.startedTargets.map(\.appID), ["spotify"])
        XCTAssertEqual(harness.liveController.startGains.map(\.percentLabel), ["65%"])
        XCTAssertFalse(harness.viewModel.isExperimentalControlPending(for: "spotify"))
        XCTAssertFalse(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))
    }

    // Repeated slider moves (and a toggle) on a row whose start is queued are ignored: one start
    // drains for it, using the gain current at drain time.
    func testRepeatedSliderMovesOnQueuedRowAreIgnored() async {
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(liveController: liveController)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }

        harness.viewModel.setAppVolume(40, for: "music")
        harness.viewModel.setAppVolume(55, for: "music")
        harness.viewModel.toggleExperimentalControl(for: "music")
        harness.viewModel.setAppVolume(70, for: "music")
        XCTAssertTrue(harness.viewModel.isExperimentalControlPending(for: "music"))
        XCTAssertEqual(liveController.startedTargets.map(\.appID), ["spotify"])

        liveController.completeNextStart()
        await waitFor { liveController.startedTargets.count == 2 }
        liveController.completeNextStart()
        await waitFor {
            harness.viewModel.isExperimentalControlActive(for: "music")
                && !harness.viewModel.isExperimentalControlPending(for: "music")
                && !harness.viewModel.isProcessTapTesting
        }

        XCTAssertEqual(liveController.startedTargets.map(\.appID), ["spotify", "music"])
        XCTAssertEqual(liveController.startGains.map(\.percentLabel), ["50%", "70%"])
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
    }

    /// Holds Spotify's Product start in flight and queues Music behind it on a controlled harness.
    private func makeHarnessWithQueuedMusicStart(
        controller: FakeControlledLiveController,
        outputDeviceLister: FakeLiveControlOutputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true)
        ])
    ) async -> ControlledHarness {
        let harness = makeControlledHarness(liveController: controller, outputDeviceLister: outputDeviceLister)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }
        harness.viewModel.setAppVolume(50, for: "music")
        XCTAssertTrue(harness.viewModel.isExperimentalControlPending(for: "music"))
        return harness
    }

    /// After a global teardown cleared the queue: completes Spotify's (now stale) in-flight start and
    /// waits until its orphan is torn down — that runs after the start released the lane and drained —
    /// then asserts the cleared Music entry never started.
    private func assertQueuedMusicNeverStartsAfterStaleSpotifyCompletes(
        _ harness: ControlledHarness,
        controller: FakeControlledLiveController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTAssertFalse(harness.viewModel.isExperimentalControlPending(for: "music"), file: file, line: line)
        let spotifyID = controller.startedSessionIDs[0]

        controller.completeNextStart(success: true)
        await waitFor({ controller.stoppedSessionIDs.contains(spotifyID) }, file: file, line: line)

        XCTAssertEqual(controller.startedTargets.map(\.appID), ["spotify"], file: file, line: line)
        XCTAssertEqual(controller.pendingStartCount, 0, file: file, line: line)
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "music"), file: file, line: line)
        XCTAssertFalse(harness.viewModel.isExperimentalControlPending(for: "music"), file: file, line: line)
    }

    func testQueuedStartIsClearedByStopAll() async {
        let controller = FakeControlledLiveController()
        let harness = await makeHarnessWithQueuedMusicStart(controller: controller)

        harness.viewModel.stopProcessTapLiveControl()

        await assertQueuedMusicNeverStartsAfterStaleSpotifyCompletes(harness, controller: controller)
    }

    func testQueuedStartIsClearedByGlobalRealControlOff() async {
        let controller = FakeControlledLiveController()
        let harness = await makeHarnessWithQueuedMusicStart(controller: controller)

        harness.viewModel.setExperimentalRealAppControlEnabled(false)

        await assertQueuedMusicNeverStartsAfterStaleSpotifyCompletes(harness, controller: controller)
    }

    func testQueuedStartIsClearedByOutputDeviceChange() async {
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true)
        ])
        let controller = FakeControlledLiveController()
        let harness = await makeHarnessWithQueuedMusicStart(controller: controller, outputDeviceLister: outputDeviceLister)

        outputDeviceLister.devices = [makeLiveControlOutputDevice(id: "airpods", isDefault: true)]
        harness.viewModel.refreshOutputDevices()

        await assertQueuedMusicNeverStartsAfterStaleSpotifyCompletes(harness, controller: controller)
    }

    func testSystemSleepClearsQueuedStartAndWakeRunsNothing() async {
        let controller = FakeControlledLiveController()
        let harness = await makeHarnessWithQueuedMusicStart(controller: controller)

        harness.viewModel.handleSystemWillSleep()
        harness.viewModel.handleSystemDidWake()

        await assertQueuedMusicNeverStartsAfterStaleSpotifyCompletes(harness, controller: controller)
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
    }

    func testTerminationClearsQueuedStart() async {
        let controller = FakeControlledLiveController()
        let harness = await makeHarnessWithQueuedMusicStart(controller: controller)

        harness.viewModel.stopProcessTapLiveControlForTermination()

        await assertQueuedMusicNeverStartsAfterStaleSpotifyCompletes(harness, controller: controller)
    }

    // A queued start whose app exits is dropped, while the other apps' sessions/starts carry on.
    func testQueuedStartDroppedWhenItsAppExitsWhileOthersRun() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        // Pin the Advanced diagnostic selection to a surviving app so removing YouTube only exercises
        // the per-app exit path (not the selection-driven global stop).
        harness.viewModel.selectProcessTapApp("spotify")
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { controller.pendingStartCount == 1 }
        harness.viewModel.setAppVolume(50, for: "youtube")
        XCTAssertTrue(harness.viewModel.isExperimentalControlPending(for: "youtube"))

        harness.appLister.apps = makeLiveControlApps().filter { $0.id != "youtube" }
        harness.viewModel.refreshApplications()
        XCTAssertFalse(harness.viewModel.isExperimentalControlPending(for: "youtube"))

        controller.completeNextStart(success: true)
        await waitFor {
            harness.viewModel.isExperimentalControlActive(for: "music")
                && !harness.viewModel.isProcessTapTesting
        }

        XCTAssertEqual(controller.startedTargets.map(\.appID), ["spotify", "music"])
        XCTAssertEqual(controller.pendingStartCount, 0)
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(controller.stoppedSessionIDs.isEmpty)
    }

    // Closing the panel drops queued starts (they must not drain into background helper probing) and
    // cancels the in-flight resolution, whose late result is then ignored.
    func testPanelCloseClearsQueuedStartsAndCancelsResolution() async {
        let resolver = FakeAppAudioTargetResolver(suspendsWhenNoResultIsAvailable: true)
        let harness = makeHarness(
            appAudioTargetResolver: resolver,
            eligibilityByPID: [200: .unavailable("Core Audio process unavailable"), 201: .eligible]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(45, for: "youtube")
        await waitFor { resolver.resolveRequests.count == 1 }
        harness.viewModel.setAppVolume(60, for: "spotify")
        XCTAssertTrue(harness.viewModel.isExperimentalControlPending(for: "spotify"))

        harness.viewModel.stopTwoAppReadinessForPanelClose()

        XCTAssertFalse(harness.viewModel.isExperimentalControlPending(for: "spotify"))
        XCTAssertFalse(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))
        XCTAssertEqual(resolver.cancelledReasons, [.userStopped])

        resolver.completeNext(
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        )

        // A fresh start only runs once the cancelled resolution task has finished (it holds the lane),
        // so once Spotify is active the late YouTube result has been handled — and ignored.
        harness.viewModel.setAppVolume(65, for: "spotify")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }
        XCTAssertEqual(harness.liveController.startedTargets.map(\.appID), ["spotify"])
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "youtube"))
    }

    // Stop All cancels an in-flight helper resolution, so its late result cannot start a session after
    // the user stopped everything.
    func testStopAllCancelsInFlightHelperResolutionAndIgnoresLateResult() async {
        let resolver = FakeAppAudioTargetResolver(suspendsWhenNoResultIsAvailable: true)
        let harness = makeHarness(
            appAudioTargetResolver: resolver,
            eligibilityByPID: [200: .unavailable("Core Audio process unavailable"), 201: .eligible]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(45, for: "youtube")
        await waitFor { resolver.resolveRequests.count == 1 }
        XCTAssertTrue(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))

        harness.viewModel.stopProcessTapLiveControl()

        XCTAssertEqual(resolver.cancelledReasons, [.userStopped])
        XCTAssertFalse(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))

        resolver.completeNext(
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        )

        // As above: Spotify's start can only run after the cancelled resolution task finished, so the
        // late YouTube result has been handled (and ignored) by the time Spotify is active.
        harness.viewModel.setAppVolume(60, for: "spotify")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }
        XCTAssertEqual(harness.liveController.startedTargets.map(\.appID), ["spotify"])
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "youtube"))
    }

    func testStopActiveSessionForwardsUserStoppedReason() async {
        let harness = makeHarness()
        harness.viewModel.startProcessTapLiveControl()
        await waitFor { harness.viewModel.isProcessTapLiveControlActive }

        harness.viewModel.stopProcessTapLiveControl()
        await waitFor { !harness.liveController.stopReasons.isEmpty }

        XCTAssertEqual(harness.liveController.stopReasons, [.userStopped])
        await waitFor { !harness.viewModel.isProcessTapLiveControlActive }
    }

    func testProductRowSliderUpdatesGainOnlyForActiveRow() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        harness.viewModel.setAppVolume(25, for: "music")
        await drainMainActor()
        XCTAssertTrue(harness.liveController.gainUpdates.isEmpty)

        harness.viewModel.setAppVolume(25, for: "spotify")

        XCTAssertEqual(harness.liveController.gainUpdates.map(\.percentLabel), ["25%"])
        XCTAssertEqual(harness.liveController.gainUpdates.map(\.scalar), [0.25])
    }

    func testTimeoutCallbackClearsActiveLiveState() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.viewModel.isProcessTapLiveControlActive }

        harness.liveController.emitStopped(
            ProcessTapTestResult(outcome: .liveControlTimedOut, message: "Live control timed out", severity: .warning)
        )
        await waitFor { !harness.viewModel.isProcessTapLiveControlActive }

        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)
    }

    func testAppExitCallbackClearsActiveStateAndInvalidatesTargetCache() async {
        let resolver = FakeAppAudioTargetResolver()
        let harness = makeHarness(appAudioTargetResolver: resolver)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        harness.liveController.emitStopped(
            ProcessTapTestResult(outcome: .liveControlAppExited, message: "Live control stopped: process exited", severity: .warning)
        )
        await waitFor { !harness.viewModel.isProcessTapLiveControlActive }

        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["spotify"])
    }

    func testOutputDeviceChangeStopsActiveSessionAndInvalidatesHelperCache() async {
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true),
            makeLiveControlOutputDevice(id: "airpods")
        ])
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        ])
        let harness = makeHarness(
            outputDeviceLister: outputDeviceLister,
            appAudioTargetResolver: resolver,
            eligibilityByPID: [
                200: .unavailable("Core Audio process unavailable"),
                201: .eligible
            ]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "youtube") }

        outputDeviceLister.devices = [
            makeLiveControlOutputDevice(id: "built-in"),
            makeLiveControlOutputDevice(id: "airpods", isDefault: true)
        ]
        harness.viewModel.refreshOutputDevices()
        await waitFor { !harness.liveController.stopReasons.isEmpty }

        XCTAssertEqual(harness.liveController.stopReasons, [.outputDeviceChanged])
        XCTAssertEqual(resolver.invalidateAllCount, 1)
    }

    func testCachedHelperSetupFailureInvalidatesCacheAndRetriesFreshResolveOnce() async {
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .cachedHelper
                )
            ),
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:202", appName: "YouTube", processIdentifier: 202),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        ])
        let liveController = FakeLiveControlController(startResults: [
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning),
            ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
        ])
        let harness = makeHarness(
            liveController: liveController,
            appAudioTargetResolver: resolver,
            eligibilityByPID: [
                200: .unavailable("Core Audio process unavailable"),
                201: .eligible,
                202: .eligible
            ]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { liveController.startedTargets.count == 2 }
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "youtube") }

        XCTAssertEqual(resolver.allowsCachedLookupRequests, [true, false])
        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["youtube"])
        XCTAssertEqual(liveController.startedTargets.map(\.processIdentifier), [201, 202])
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "youtube"))
    }

    // Same cached-helper recovery while another Product session (Spotify) is already confirmed:
    // the other session must not suppress the fresh-resolve retry, and it keeps running.
    func testCachedHelperSetupFailureRetriesFreshResolveWhileAnotherProductSessionIsActive() async {
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .cachedHelper
                )
            ),
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:202", appName: "YouTube", processIdentifier: 202),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        ])
        // Start results are consumed in order: Spotify, YouTube via the stale cached helper, then
        // YouTube via the freshly discovered helper.
        let liveController = FakeLiveControlController(startResults: [
            ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info),
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning),
            ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
        ])
        let harness = makeHarness(
            liveController: liveController,
            appAudioTargetResolver: resolver,
            eligibilityByPID: [
                200: .unavailable("Core Audio process unavailable"),
                201: .eligible,
                202: .eligible
            ]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)

        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor {
            harness.viewModel.confirmedProductRealControlSessionCount == 2 && !harness.viewModel.isProcessTapTesting
        }

        XCTAssertEqual(resolver.allowsCachedLookupRequests, [true, false])
        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["youtube"])
        XCTAssertEqual(liveController.startedTargets.map(\.processIdentifier), [101, 201, 202])
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "youtube"))
        XCTAssertTrue(liveController.stopReasons.isEmpty)
        XCTAssertNotEqual(harness.viewModel.statusMessage?.text, "Could not start live control for this app")
    }

    func testManualAdvancedLiveSetupFailureDoesNotTouchHelperCache() async {
        let resolver = FakeAppAudioTargetResolver()
        let liveController = FakeLiveControlController(startResults: [
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        ])
        let harness = makeHarness(liveController: liveController, appAudioTargetResolver: resolver)

        harness.viewModel.startProcessTapLiveControl()
        await waitFor { liveController.startedTargets.count == 1 }

        XCTAssertTrue(resolver.invalidatedRequests.isEmpty)
        XCTAssertEqual(resolver.invalidateAllCount, 0)
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
    }

    func testGlobalRealControlOffStopsActiveProductSessionAndInvalidatesCache() async {
        let resolver = FakeAppAudioTargetResolver()
        let harness = makeHarness(appAudioTargetResolver: resolver)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        harness.viewModel.setExperimentalRealAppControlEnabled(false)
        await waitFor { !harness.viewModel.isProcessTapLiveControlActive }

        XCTAssertEqual(harness.liveController.stopReasons, [.userStopped])
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)
        XCTAssertEqual(resolver.invalidateAllCount, 1)
    }

    func testGlobalRealControlOffCancelsInFlightHelperResolutionAndIgnoresLateCompletion() async {
        let resolver = FakeAppAudioTargetResolver(suspendsWhenNoResultIsAvailable: true)
        let harness = makeHarness(
            appAudioTargetResolver: resolver,
            eligibilityByPID: [
                200: .unavailable("Core Audio process unavailable"),
                201: .eligible
            ]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(45, for: "youtube")
        await waitFor { resolver.resolveRequests.count == 1 }
        XCTAssertTrue(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))

        harness.viewModel.setExperimentalRealAppControlEnabled(false)
        XCTAssertEqual(resolver.cancelledReasons, [.userStopped])
        XCTAssertEqual(resolver.invalidateAllCount, 1)
        XCTAssertFalse(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))

        resolver.completeNext(
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        )
        await drainMainActor()

        XCTAssertTrue(harness.liveController.startedTargets.isEmpty)
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)
    }

    func testProductControlDoesNotStartWhenGlobalRealControlIsOff() async {
        let resolver = FakeAppAudioTargetResolver()
        let harness = makeHarness(
            appAudioTargetResolver: resolver,
            eligibilityByPID: [
                200: .unavailable("Core Audio process unavailable"),
                201: .eligible
            ]
        )

        harness.viewModel.setAppVolume(33, for: "spotify")
        harness.viewModel.setMuted(true, for: "youtube")
        await drainMainActor()

        XCTAssertTrue(harness.liveController.startedTargets.isEmpty)
        XCTAssertTrue(resolver.resolveRequests.isEmpty)
        XCTAssertEqual(harness.audioController.appVolumeRequests.map(\.appID), ["spotify"])
        XCTAssertEqual(harness.audioController.appVolumeRequests.map(\.volume), [33])
        XCTAssertEqual(harness.audioController.appMutedRequests.map(\.appID), ["youtube"])
        XCTAssertEqual(harness.audioController.appMutedRequests.map(\.isMuted), [true])
    }

    func testProductRealControlSurvivesPanelCloseCleanup() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        harness.viewModel.stopTwoAppReadinessForPanelClose()
        await drainMainActor()

        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "spotify")
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "Spotify")
        XCTAssertEqual(harness.liveController.stopReasons, [])
        XCTAssertEqual(harness.liveController.startTimeoutPolicies, [.indefinite])
    }

    func testDirectVisiblePIDSetupFailureClearsProductStateAndAllowsRetry() async {
        // Drive both completions explicitly (controlled continuation), mirroring the stable
        // testDirectVisiblePIDSetupFailureAfterOptimisticStateClearsStateAndAllowsRetry. The
        // former version used non-waiting startResults, so the test depended on a background
        // startSession resolving its failure result and post-await within a fixed yield budget —
        // the window that flaked on loaded CI. Here each start is completed by the test, and the
        // retry waits on real settled ViewModel signals rather than a fake call count.
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(liveController: liveController)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }
        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        )

        // Wait for the failure to FULLY settle before retrying: the post-await acceptance ran
        // (isProcessTapTesting back to false), the optimistic Product state cleared, and the
        // derived live-control flag is down. These are real state signals, not a call count.
        await waitFor {
            harness.viewModel.activeExperimentalAppID == nil
                && !harness.viewModel.isProcessTapTesting
                && !harness.viewModel.isProcessTapLiveControlActive
        }
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)
        XCTAssertEqual(harness.viewModel.statusMessage?.text, "Could not start live control for this app")

        // Retry: a second start must reach the controller and confirm.
        harness.viewModel.setAppVolume(55, for: "spotify")
        await waitFor { liveController.startedTargets.count == 2 }
        liveController.completeNextStart()
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        XCTAssertEqual(liveController.startedTargets.map(\.appID), ["spotify", "spotify"])
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "Spotify")
    }

    func testPermissionDeniedStartFailureOffersSystemSettingsAction() async {
        let liveController = FakeLiveControlController(startResults: [
            ProcessTapTestResult(outcome: .permissionDenied, message: "Permission denied", severity: .warning)
        ])
        let harness = makeHarness(liveController: liveController)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }

        XCTAssertEqual(harness.viewModel.statusMessage?.text, "Could not start live control for this app")
        XCTAssertEqual(harness.viewModel.statusMessage?.action, .openSystemAudioRecordingSettings)
    }

    func testNonPermissionStartFailureHasNoSystemSettingsAction() async {
        let liveController = FakeLiveControlController(startResults: [
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        ])
        let harness = makeHarness(liveController: liveController)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }

        XCTAssertNil(harness.viewModel.statusMessage?.action)
    }

    func testSecondAppStartsConcurrentProductSession() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        // Wait until the start has fully settled: the session id is recorded by startSession
        // and the post-await has run (isProcessTapTesting back to false means setRunning(false)
        // and the confirming beginSession in the same synchronous block have completed). This
        // is deterministic, unlike a fixed drainMainActor yield count (which flakes on CI).
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { harness.liveController.startedSessionIDs.count == 2 && !harness.viewModel.isProcessTapTesting }

        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertEqual(Set(harness.liveController.startedTargets.map(\.appID)), ["spotify", "music"])
    }

    func testStoppingOneProductSessionLeavesTheOtherActive() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        // Wait until the start has fully settled: the session id is recorded by startSession
        // and the post-await has run (isProcessTapTesting back to false means setRunning(false)
        // and the confirming beginSession in the same synchronous block have completed). This
        // is deterministic, unlike a fixed drainMainActor yield count (which flakes on CI).
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { harness.liveController.startedSessionIDs.count == 2 && !harness.viewModel.isProcessTapTesting }

        harness.viewModel.toggleExperimentalControl(for: "spotify")
        await waitFor { !harness.viewModel.isExperimentalControlActive(for: "spotify") }

        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
    }

    // A third confirmed Product session is allowed (no app-count limit). Drives three direct
    // sessions (all default-eligible in the harness) and asserts all three are active.
    func testThirdProductSessionAllowed() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { harness.liveController.startedSessionIDs.count == 2 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { harness.liveController.startedSessionIDs.count == 3 && !harness.viewModel.isProcessTapTesting }

        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "youtube"))
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 3)
    }

    // No app-count limit by default (owner decision; `AppConstants.maxConcurrentLiveSessions` is
    // nil): a fourth Product start for a distinct eligible app is admitted exactly like the first
    // three and no limit message is shown. (Formerly testFourthProductSessionBlockedByCap; the cap
    // mechanism + configured-count message with an injected cap are now pinned in
    // ProductRealControlCoordinatorTests / ProductRealStartCoordinatorTests.)
    func testFourthProductSessionAllowedWithDefaultUnlimitedLimit() async {
        let apps = makeLiveControlApps() + [
            MixerAppItem(id: "podcasts", name: "Podcasts", icon: .systemSymbol("mic"), processIdentifier: 103, volume: 50)
        ]
        let harness = makeHarness(apps: apps)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { harness.liveController.startedSessionIDs.count == 2 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { harness.liveController.startedSessionIDs.count == 3 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "podcasts")
        await waitFor { harness.liveController.startedSessionIDs.count == 4 && !harness.viewModel.isProcessTapTesting }

        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "youtube"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "podcasts"))
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 4)
        XCTAssertFalse(harness.viewModel.statusMessage?.text.contains("apps at a time") ?? false)
    }

    // End-to-end "no limit" proof through the production session manager: the view model drives a
    // real `ProcessTapLiveSessionManager` built exactly as `MacMiniMixerApp` builds it (with
    // `AppConstants.maxConcurrentLiveSessions`, i.e. unlimited), with one fake controller per
    // session. Seven distinct eligible apps all become active at once and the manager holds all
    // seven; a per-app stop leaves the other six running; Stop All stops every one of them.
    // Deterministic: each step waits on observable state (deadline-bounded), no sleeps.
    func testManyProductSessionsRunConcurrentlyThroughRealSessionManagerWithDefaultLimit() async throws {
        let apps = makeLiveControlApps() + [
            MixerAppItem(id: "podcasts", name: "Podcasts", icon: .systemSymbol("mic"), processIdentifier: 103, volume: 50),
            MixerAppItem(id: "zoom", name: "Zoom", icon: .systemSymbol("video"), processIdentifier: 104, volume: 50),
            MixerAppItem(id: "safari", name: "Safari", icon: .systemSymbol("safari"), processIdentifier: 105, volume: 50),
            MixerAppItem(id: "slack", name: "Slack", icon: .systemSymbol("message"), processIdentifier: 106, volume: 50)
        ]
        let controllers = PerSessionFakeLiveControllerFactory()
        let manager = ProcessTapLiveSessionManager(maxSessions: AppConstants.maxConcurrentLiveSessions) {
            controllers.make()
        }
        let viewModel = makeViewModel(apps: apps, liveController: manager)
        viewModel.setExperimentalRealAppControlEnabled(true)

        for (index, app) in apps.enumerated() {
            viewModel.setAppVolume(50, for: app.id)
            await waitFor {
                viewModel.confirmedProductRealControlSessionCount == index + 1 && !viewModel.isProcessTapTesting
            }
        }

        // Every app is active at once and the real manager holds one live session per app.
        XCTAssertEqual(viewModel.confirmedProductRealControlSessionCount, apps.count)
        for app in apps {
            XCTAssertTrue(viewModel.isExperimentalControlActive(for: app.id), "\(app.id) should be active")
        }
        XCTAssertEqual(manager.activeSessions.count, apps.count)
        XCTAssertEqual(Set(manager.activeSessions.map(\.appID)), Set(apps.map(\.id)))
        XCTAssertEqual(controllers.controllers.count, apps.count)
        XCTAssertFalse(viewModel.statusMessage?.text.contains("apps at a time") ?? false)
        let banner = try XCTUnwrap(viewModel.realControlBannerPresentation)
        XCTAssertEqual(banner.summaryText, "Real control: Spotify, Music +5 more")
        XCTAssertEqual(banner.stopButtonTitle, "Stop All")

        // Per-app stop: only Music's session is torn down; the other six keep running.
        viewModel.toggleExperimentalControl(for: "music")
        await waitFor {
            !viewModel.isExperimentalControlActive(for: "music")
                && !viewModel.isExperimentalControlPending(for: "music")
                && manager.activeSessions.count == apps.count - 1
        }
        XCTAssertEqual(viewModel.confirmedProductRealControlSessionCount, apps.count - 1)
        XCTAssertFalse(manager.activeSessions.contains { $0.appID == "music" })
        for app in apps where app.id != "music" {
            XCTAssertTrue(viewModel.isExperimentalControlActive(for: app.id), "\(app.id) should still be active")
        }

        // Stop All stops every remaining session.
        viewModel.stopProcessTapLiveControl()
        await waitFor {
            viewModel.confirmedProductRealControlSessionCount == 0
                && manager.activeSessions.isEmpty
                && !viewModel.isProcessTapLiveControlActive
        }
        XCTAssertNil(viewModel.realControlBannerPresentation)
        // Each session's own controller was stopped exactly once, with the user-stop reason (Music
        // by the per-app stop, the other six by Stop All).
        XCTAssertTrue(controllers.controllers.allSatisfy { $0.stopReasons == [.userStopped] })
    }

    func testStoppingOneOfThreeProductSessionsLeavesTwoActive() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { harness.liveController.startedSessionIDs.count == 2 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { harness.liveController.startedSessionIDs.count == 3 && !harness.viewModel.isProcessTapTesting }

        harness.viewModel.toggleExperimentalControl(for: "music")
        await waitFor { !harness.viewModel.isExperimentalControlActive(for: "music") }

        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "youtube"))
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 2)
    }

    // MARK: - Rapid Product Real toggle guard

    func testRapidStartAttemptsWhilePendingDoNotCreateDuplicateProductSessions() async {
        // Hold the first start pending so repeated toggle/slider attempts land while it is in flight.
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(liveController: liveController)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }
        XCTAssertTrue(harness.viewModel.isExperimentalControlPending(for: "spotify"))

        // Spam more start attempts (slider drags + toggle) for the same row while pending. Each must
        // be ignored by the guard before it reaches the controller.
        harness.viewModel.setAppVolume(55, for: "spotify")
        harness.viewModel.setAppVolume(60, for: "spotify")
        harness.viewModel.toggleExperimentalControl(for: "spotify")
        await drainMainActor()
        XCTAssertEqual(liveController.startedTargets.count, 1)

        liveController.completeNextStart()
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }
        XCTAssertFalse(harness.viewModel.isExperimentalControlPending(for: "spotify"))
        XCTAssertEqual(liveController.startedTargets.count, 1)
    }

    func testPendingClearsAfterStartFailureAndAllowsRetry() async {
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(liveController: liveController)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }
        XCTAssertTrue(harness.viewModel.isExperimentalControlPending(for: "spotify"))

        // Fail the start: the pending flag must clear so the row can be retried.
        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        )
        await waitFor { !harness.viewModel.isExperimentalControlPending(for: "spotify") }
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))

        harness.viewModel.setAppVolume(55, for: "spotify")
        await waitFor { liveController.startedTargets.count == 2 }
        liveController.completeNextStart()
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }
        XCTAssertFalse(harness.viewModel.isExperimentalControlPending(for: "spotify"))
    }

    func testRapidStopTogglesWhilePendingAreIgnoredAndPendingClearsAfterStop() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        // First toggle stops the row and marks the stop transition pending (synchronously). A second
        // rapid toggle on the same MainActor turn must be ignored before the stop callback runs, so
        // only one stop reaches the controller.
        harness.viewModel.toggleExperimentalControl(for: "spotify")
        XCTAssertTrue(harness.viewModel.isExperimentalControlPending(for: "spotify"))
        harness.viewModel.toggleExperimentalControl(for: "spotify")

        await waitFor { !harness.viewModel.isExperimentalControlActive(for: "spotify") }
        XCTAssertFalse(harness.viewModel.isExperimentalControlPending(for: "spotify"))
        XCTAssertEqual(harness.liveController.stopReasons.count, 1)
    }

    func testGlobalRealControlOffClearsPendingOperation() async {
        // A start held pending, then global Real App Control turned off: the pending flag must clear
        // (global teardown) so no row is left visually stuck working.
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(liveController: liveController)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }
        XCTAssertTrue(harness.viewModel.isExperimentalControlPending(for: "spotify"))

        harness.viewModel.setExperimentalRealAppControlEnabled(false)
        XCTAssertFalse(harness.viewModel.isExperimentalControlPending(for: "spotify"))
    }

    func testOutputDeviceChangeStopsAllThreeProductSessions() async {
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true)
        ])
        let harness = makeHarness(outputDeviceLister: outputDeviceLister)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { harness.liveController.startedSessionIDs.count == 2 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { harness.liveController.startedSessionIDs.count == 3 && !harness.viewModel.isProcessTapTesting }

        outputDeviceLister.devices = [
            makeLiveControlOutputDevice(id: "built-in"),
            makeLiveControlOutputDevice(id: "airpods", isDefault: true)
        ]
        harness.viewModel.refreshOutputDevices()
        await waitFor { harness.viewModel.confirmedProductRealControlSessionCount == 0 }

        XCTAssertEqual(harness.liveController.stopReasons, [.outputDeviceChanged, .outputDeviceChanged, .outputDeviceChanged])
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
    }

    func testHelperResolvedSetupFailureInvalidatesMappingClearsStateAndAllowsLaterResolve() async {
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            ),
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:202", appName: "YouTube", processIdentifier: 202),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        ])
        let liveController = FakeLiveControlController(startResults: [
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning),
            ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
        ])
        let harness = makeHarness(
            liveController: liveController,
            appAudioTargetResolver: resolver,
            eligibilityByPID: [
                200: .unavailable("Core Audio process unavailable"),
                201: .eligible,
                202: .eligible
            ]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { liveController.startedTargets.count == 1 }
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }

        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["youtube"])
        XCTAssertFalse(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)

        harness.viewModel.setAppVolume(60, for: "youtube")
        await waitFor { liveController.startedTargets.count == 2 }
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "youtube") }

        XCTAssertEqual(resolver.resolveRequests.map(\.appID), ["youtube", "youtube"])
        XCTAssertEqual(liveController.startedTargets.map(\.processIdentifier), [201, 202])
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "YouTube")
    }

    func testSetMutedStartsDirectProductControlWithZeroGainAndUnmuteUpdatesGain() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setMuted(true, for: "spotify")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        XCTAssertEqual(harness.liveController.startedTargets.first?.appID, "spotify")
        XCTAssertEqual(harness.liveController.startGains.first?.scalar, 0)
        XCTAssertEqual(harness.liveController.startGains.first?.percentLabel, "0%")
        XCTAssertEqual(harness.audioController.appMutedRequests.map(\.appID), ["spotify"])
        XCTAssertEqual(harness.audioController.appMutedRequests.map(\.isMuted), [true])

        harness.viewModel.setMuted(false, for: "spotify")

        XCTAssertEqual(harness.liveController.gainUpdates.map(\.scalar), [0.5])
        XCTAssertEqual(harness.liveController.gainUpdates.map(\.percentLabel), ["50%"])
    }

    func testDirectActiveAppDisappearanceStopsProductControlAndInvalidatesCache() async {
        let resolver = FakeAppAudioTargetResolver()
        let harness = makeHarness(appAudioTargetResolver: resolver)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        harness.appLister.apps = makeLiveControlApps().filter { $0.id != "spotify" }
        harness.viewModel.refreshApplications()
        await waitFor { !harness.viewModel.isProcessTapLiveControlActive }

        XCTAssertFalse(harness.liveController.stopReasons.isEmpty)
        XCTAssertTrue(harness.liveController.stopReasons.allSatisfy { $0 == .targetAppExited })
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["spotify"])
    }

    func testHelperExitCallbackClearsProductStateAndInvalidatesHelperCache() async {
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        ])
        let harness = makeHarness(
            appAudioTargetResolver: resolver,
            eligibilityByPID: [
                200: .unavailable("Core Audio process unavailable"),
                201: .eligible
            ]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "youtube") }

        harness.liveController.emitStopped(
            ProcessTapTestResult(outcome: .liveControlAppExited, message: "Live control stopped: process exited", severity: .warning)
        )
        await waitFor { !harness.viewModel.isProcessTapLiveControlActive }

        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)
        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["youtube"])
    }

    func testAppDisappearsDuringHelperResolutionCancelsResolutionAndIgnoresLateCompletion() async {
        let resolver = FakeAppAudioTargetResolver(suspendsWhenNoResultIsAvailable: true)
        let harness = makeHarness(
            appAudioTargetResolver: resolver,
            eligibilityByPID: [
                200: .unavailable("Core Audio process unavailable"),
                201: .eligible
            ]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { resolver.resolveRequests.count == 1 }
        XCTAssertTrue(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))

        harness.appLister.apps = makeLiveControlApps().filter { $0.id != "youtube" }
        harness.viewModel.refreshApplications()

        XCTAssertEqual(resolver.cancelledReasons, [.targetExited])
        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["youtube"])
        XCTAssertFalse(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))

        resolver.completeNext(
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        )
        await drainMainActor()

        XCTAssertTrue(harness.liveController.startedTargets.isEmpty)
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
    }

    func testTerminationCleanupStopsActiveProductControlAndIsSafeWhenRepeated() async {
        let resolver = FakeAppAudioTargetResolver()
        let harness = makeHarness(appAudioTargetResolver: resolver)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        harness.viewModel.stopProcessTapLiveControlForTermination()
        harness.viewModel.stopProcessTapLiveControlForTermination()

        XCTAssertEqual(harness.liveController.stopReasons, [.appTerminating, .appTerminating])
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)
        XCTAssertEqual(resolver.invalidateAllCount, 2)
    }

    func testTerminationCleanupCancelsInFlightHelperResolutionAndIgnoresLateCompletion() async {
        let resolver = FakeAppAudioTargetResolver(suspendsWhenNoResultIsAvailable: true)
        let harness = makeHarness(
            appAudioTargetResolver: resolver,
            eligibilityByPID: [
                200: .unavailable("Core Audio process unavailable"),
                201: .eligible
            ]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { resolver.resolveRequests.count == 1 }

        harness.viewModel.stopProcessTapLiveControlForTermination()

        XCTAssertEqual(resolver.cancelledReasons, [.userStopped])
        XCTAssertEqual(resolver.invalidateAllCount, 1)
        XCTAssertFalse(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)

        resolver.completeNext(
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        )
        await drainMainActor()

        XCTAssertTrue(harness.liveController.startedTargets.isEmpty)
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
    }

    // MARK: - Ported from origin/main (Product start + output cleanup), adapted to multi-app

    func testPendingDirectProductStartRecordsVisibleIdentityBeforeLiveStartCompletes() async {
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(liveController: liveController)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(42, for: "music")
        await waitFor { liveController.startedTargets.count == 1 }

        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "music")
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "Music")
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertEqual(harness.liveController.startedTargets.first?.appID, "music")
        XCTAssertEqual(harness.liveController.startedTargets.first?.processIdentifier, 102)
        XCTAssertEqual(harness.liveController.startTimeoutPolicies, [.indefinite])

        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        )
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }
    }

    func testPendingHelperResolvedProductStartPreservesVisibleIdentityAndHidesHelperName() async {
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "com.apple.WebKit.GPU", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        ])
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(
            liveController: liveController,
            appAudioTargetResolver: resolver,
            eligibilityByPID: [200: .unavailable("Core Audio process unavailable"), 201: .eligible]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(35, for: "youtube")
        await waitFor { liveController.startedTargets.count == 1 }

        XCTAssertEqual(resolver.resolveRequests.map(\.appID), ["youtube"])
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "youtube")
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "YouTube")
        XCTAssertEqual(harness.liveController.startedTargets.first?.processIdentifier, 201)
        XCTAssertEqual(harness.liveController.startedTargets.first?.appName, "com.apple.WebKit.GPU")
        XCTAssertNotEqual(harness.viewModel.activeLiveControlAppName, "com.apple.WebKit.GPU")

        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        )
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }
    }

    func testOutputDeviceChangeCancelsInFlightHelperResolutionAndIgnoresLateCompletion() async {
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true),
            makeLiveControlOutputDevice(id: "airpods")
        ])
        let resolver = FakeAppAudioTargetResolver(suspendsWhenNoResultIsAvailable: true)
        let harness = makeHarness(
            outputDeviceLister: outputDeviceLister,
            appAudioTargetResolver: resolver,
            eligibilityByPID: [200: .unavailable("Core Audio process unavailable"), 201: .eligible]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { resolver.resolveRequests.count == 1 }
        XCTAssertTrue(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))

        outputDeviceLister.devices = [
            makeLiveControlOutputDevice(id: "built-in"),
            makeLiveControlOutputDevice(id: "airpods", isDefault: true)
        ]
        harness.viewModel.refreshOutputDevices()

        XCTAssertEqual(resolver.cancelledReasons, [.outputDeviceChanged])
        XCTAssertEqual(resolver.invalidateAllCount, 1)
        XCTAssertFalse(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))

        resolver.completeNext(
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        )
        await drainMainActor()

        XCTAssertTrue(harness.liveController.startedTargets.isEmpty)
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
    }

    func testOutputDeviceChangeInvalidatesHelperCacheWithoutActiveProductSession() {
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true),
            makeLiveControlOutputDevice(id: "airpods")
        ])
        let resolver = FakeAppAudioTargetResolver()
        let harness = makeHarness(outputDeviceLister: outputDeviceLister, appAudioTargetResolver: resolver)

        outputDeviceLister.devices = [
            makeLiveControlOutputDevice(id: "built-in"),
            makeLiveControlOutputDevice(id: "airpods", isDefault: true)
        ]
        harness.viewModel.refreshOutputDevices()

        XCTAssertEqual(resolver.invalidateAllCount, 1)
        XCTAssertTrue(harness.liveController.stopReasons.isEmpty)
    }

    func testOutputDeviceChangeStopsManualHelperProbe() async {
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true),
            makeLiveControlOutputDevice(id: "airpods")
        ])
        let helperProbe = FakeLiveControlCandidateAudioProbe(waitForStopBeforeReturning: true)
        let probeStarted = expectation(description: "Helper probe started")
        helperProbe.onProbeStarted = { probeStarted.fulfill() }
        let processLister = FakeLiveControlProcessLister(processes: [
            SystemProcessInfo(processIdentifier: 200, parentProcessIdentifier: nil, name: "YouTube", executablePath: nil),
            SystemProcessInfo(processIdentifier: 201, parentProcessIdentifier: 200, name: "com.apple.WebKit.GPU", executablePath: nil)
        ])
        let harness = makeHarness(
            outputDeviceLister: outputDeviceLister,
            processLister: processLister,
            helperProcessAudioProbe: helperProbe,
            eligibilityByPID: [200: .eligible, 201: .eligible]
        )
        harness.viewModel.refreshOutputDevices()

        harness.viewModel.selectHelperDiscoveryApp("youtube")
        harness.viewModel.scanHelperProcesses()
        await waitFor { harness.viewModel.helperProcessCandidates.contains { $0.process.processIdentifier == 201 } }
        harness.viewModel.probeHelperProcessCandidate(201)
        await fulfillment(of: [probeStarted], timeout: 1)
        XCTAssertEqual(harness.viewModel.helperProcessProbeRunningPID, 201)

        outputDeviceLister.devices = [
            makeLiveControlOutputDevice(id: "built-in"),
            makeLiveControlOutputDevice(id: "airpods", isDefault: true)
        ]
        harness.viewModel.refreshOutputDevices()
        await waitFor { helperProbe.stopReasons == [.outputDeviceChanged] }
    }

    func testOutputDeviceChangeStopsReplayProbe() async {
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true),
            makeLiveControlOutputDevice(id: "airpods")
        ])
        let replayProbe = FakeLiveControlReplayProbe(waitForStopBeforeReturning: true)
        let replayStarted = expectation(description: "Replay probe started")
        replayProbe.onReplayStarted = { replayStarted.fulfill() }
        let harness = makeHarness(outputDeviceLister: outputDeviceLister, processTapReplayProbe: replayProbe)
        harness.viewModel.refreshOutputDevices()

        harness.viewModel.selectProcessTapApp("spotify")
        harness.viewModel.testSelectedProcessTapReplayProbe()
        await fulfillment(of: [replayStarted], timeout: 1)
        XCTAssertTrue(harness.viewModel.isProcessTapTesting)

        outputDeviceLister.devices = [
            makeLiveControlOutputDevice(id: "built-in"),
            makeLiveControlOutputDevice(id: "airpods", isDefault: true)
        ]
        harness.viewModel.refreshOutputDevices()
        await waitFor { replayProbe.stopReasons == [.outputDeviceChanged] }
        await waitFor { !harness.viewModel.isProcessTapTesting }
    }

    func testDirectVisiblePIDSetupFailureAfterOptimisticStateClearsStateAndAllowsRetry() async {
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(liveController: liveController)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "spotify")
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)

        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        )
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)

        harness.viewModel.setAppVolume(55, for: "spotify")
        await waitFor { liveController.startedTargets.count == 2 }
        liveController.completeNextStart()
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }
    }

    func testHelperResolvedSetupFailureAfterOptimisticStateInvalidatesMappingAndAllowsRetry() async {
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(ResolvedAppAudioTarget(visibleAppID: "youtube", visibleAppName: "YouTube", target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201), kind: .helper, source: .discoveredHelper)),
            .resolved(ResolvedAppAudioTarget(visibleAppID: "youtube", visibleAppName: "YouTube", target: ProcessTapTarget(appID: "helper:youtube:202", appName: "YouTube", processIdentifier: 202), kind: .helper, source: .discoveredHelper))
        ])
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(
            liveController: liveController,
            appAudioTargetResolver: resolver,
            eligibilityByPID: [200: .unavailable("Core Audio process unavailable"), 201: .eligible, 202: .eligible]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { liveController.startedTargets.count == 1 }
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "youtube")

        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        )
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }
        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["youtube"])
        XCTAssertFalse(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))

        harness.viewModel.setAppVolume(60, for: "youtube")
        await waitFor { liveController.startedTargets.count == 2 }
        liveController.completeNextStart()
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "youtube") }
        XCTAssertEqual(liveController.startedTargets.map(\.processIdentifier), [201, 202])
    }

    func testStopCallbackWhileProductStartIsPendingDoesNotResurrectOnLateSuccess() async {
        // Adapted from origin's single-session test to the multi-app model: when the target
        // disappears while a Product start is still pending, state clears via per-app exit
        // teardown, and a late success is rejected (no resurrection) and its orphan torn down.
        let resolver = FakeAppAudioTargetResolver()
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(liveController: liveController, appAudioTargetResolver: resolver)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "spotify")

        harness.appLister.apps = makeLiveControlApps().filter { $0.id != "spotify" }
        harness.viewModel.refreshApplications()
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["spotify"])

        liveController.completeNextStart()
        await drainMainActor()
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))
    }

    func testSuccessfulProductStartTransitionsFromPendingToActiveWithoutChangingVisibleIdentity() async {
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(liveController: liveController)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "spotify")
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "Spotify")
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)

        liveController.completeNextStart()
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "spotify")
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "Spotify")
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertEqual(harness.liveController.startedTargets.map(\.processIdentifier), [101])
        XCTAssertEqual(harness.liveController.startTimeoutPolicies, [.indefinite])
    }

    private func makeHarness(
        apps: [MixerAppItem] = makeLiveControlApps(),
        outputDeviceLister: FakeLiveControlOutputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true)
        ]),
        liveController: FakeLiveControlController = FakeLiveControlController(),
        appAudioTargetResolver: FakeAppAudioTargetResolver = FakeAppAudioTargetResolver(),
        processLister: FakeLiveControlProcessLister = FakeLiveControlProcessLister(),
        processTapReplayProbe: FakeLiveControlReplayProbe = FakeLiveControlReplayProbe(),
        helperProcessAudioProbe: FakeLiveControlCandidateAudioProbe = FakeLiveControlCandidateAudioProbe(),
        twoAppReadinessTester: FakeLiveControlTwoAppReadinessTester = FakeLiveControlTwoAppReadinessTester(),
        systemVolumeReader: FakeLiveControlSystemVolumeReader = FakeLiveControlSystemVolumeReader(volumeScalar: 0.5),
        productRealStartSettleGate: ProductRealStartSettling = ProductRealStartSettleGate(sleeper: { _ in }),
        eligibilityByPID: [Int32: ProcessTapProcessEligibility] = [:]
    ) -> LiveControlHarness {
        let appLister = FakeLiveControlApplicationLister(apps: apps)
        let audioController = FakeLiveControlAudioController()
        let volumeReader = systemVolumeReader
        let volumeController = FakeLiveControlSystemVolumeController()
        let viewModel = MixerViewModel(
            applicationLister: appLister,
            audioController: audioController,
            outputDeviceLister: outputDeviceLister,
            outputDeviceController: FakeLiveControlOutputDeviceController(),
            systemVolumeReader: volumeReader,
            systemVolumeController: volumeController,
            processTapTester: FakeLiveControlProcessTapTester(),
            processTapReplayProbe: processTapReplayProbe,
            processTapLiveController: liveController,
            twoAppReadinessTester: twoAppReadinessTester,
            helperProcessAudioProbe: helperProcessAudioProbe,
            appAudioTargetResolver: appAudioTargetResolver,
            processLister: processLister,
            productRealStartSettleGate: productRealStartSettleGate,
            processTapEligibility: { processIdentifier in
                guard let processIdentifier else {
                    return .unavailable("Core Audio process unavailable")
                }

                return eligibilityByPID[processIdentifier] ?? .eligible
            }
        )

        return LiveControlHarness(
            viewModel: viewModel,
            appLister: appLister,
            audioController: audioController,
            outputDeviceLister: outputDeviceLister,
            liveController: liveController,
            appAudioTargetResolver: appAudioTargetResolver,
            twoAppReadinessTester: twoAppReadinessTester,
            systemVolumeReader: volumeReader
        )
    }

    private func waitFor(
        timeout: TimeInterval = 5,
        _ predicate: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // Exact observable wait: returns the instant `predicate` holds, so the happy path adds no
        // delay. It is bounded by a wall-clock deadline rather than a fixed `Task.yield()` count
        // because a yield budget does not map to real time — under full-suite parallel load the
        // background start Task (settle gate → startSession → MainActor propagation) can take longer
        // than a small yield budget to complete, which spuriously timed out this multi-round-trip
        // retry test. The deadline is a genuine failure bound (like an XCTest timeout), not a sleep.
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }

            await Task.yield()
        }
    }

    private func drainMainActor(iterations: Int = 5) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }

    // MARK: - Stale-start safety (controlled completion)

    func testStaleProductStartAfterGlobalToggleOffIsRejectedAndStopsOnlyStaleSession() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }

        // Disabling Real App Control synchronously invalidates every pending start request, so the
        // in-flight Spotify start's token is stale by the time it completes below — no fixed drain.
        harness.viewModel.setExperimentalRealAppControlEnabled(false)

        controller.completeNextStart(success: true)
        // The stale completion is rejected and its orphan engine session is torn down by id via an
        // async cleanup; wait on the exact asserted final state instead of a fixed yield count,
        // which flaked under full-suite scheduling load.
        await waitFor {
            !harness.viewModel.isExperimentalControlActive(for: "spotify")
                && !harness.viewModel.isProcessTapLiveControlActive
                && controller.stoppedSessionIDs.count == 1
        }

        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertEqual(controller.stoppedSessionIDs.count, 1)
    }

    func testStaleProductStartAfterOutputDeviceChangeIsRejectedAndStopsStaleSession() async {
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true)
        ])
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller, outputDeviceLister: outputDeviceLister)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }

        // `refreshOutputDevices()` is synchronous on the MainActor and invalidates every pending
        // Product start request before it returns, so the in-flight Spotify start's token is stale
        // by the time it completes below — no fixed drain needed here.
        outputDeviceLister.devices = [makeLiveControlOutputDevice(id: "airpods", isDefault: true)]
        harness.viewModel.refreshOutputDevices()

        controller.completeNextStart(success: true)
        // The stale completion is rejected and its orphan engine session is torn down by id via an
        // async cleanup. Wait on the exact asserted final state instead of a fixed yield count,
        // which flaked under full-suite scheduling load.
        await waitFor {
            !harness.viewModel.isExperimentalControlActive(for: "spotify")
                && controller.stoppedSessionIDs.count == 1
        }

        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertEqual(controller.stoppedSessionIDs.count, 1)
    }

    // The engine watchdog leg of the same lifecycle: a per-session output-changed stop arriving
    // from the engine (panel closed, no view-model trigger) must clear that session's row state
    // and surface the user-visible warning, without disturbing another app's session.
    func testEngineOutputDeviceChangedStopClearsSessionStateAndShowsWarning() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)
        let spotifyID = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)

        controller.emitSessionStopped(handlerForSessionID: spotifyID, outcome: .liveControlOutputChanged)
        await waitFor { !harness.viewModel.isExperimentalControlActive(for: "spotify") }

        XCTAssertEqual(harness.viewModel.statusMessage?.text, "Live control stopped: output device changed")
        XCTAssertEqual(harness.viewModel.statusMessage?.style, .warning)
        XCTAssertEqual(harness.appAudioTargetResolver.invalidateAllCount, 1)
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
    }

    // MARK: - Product Real teardown-settle gate wiring

    // A new Product Real start must consult the settle gate before the controller creates any
    // Core Audio objects, and must not proceed while the gate is still holding it.
    func testProductStartWaitsForSettleGateBeforeCreatingSession() async {
        let releaser = TestAsyncReleaser()
        let spyGate = SpyStartSettleGate(blockOn: releaser)
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller, productRealStartSettleGate: spyGate)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        // The start consulted the gate and is held there; no session has reached the controller.
        await waitFor { spyGate.waitCount == 1 }
        XCTAssertEqual(controller.startedTargets.count, 0)

        // Releasing the gate lets the start proceed to create the session. Wait on the pending
        // start (continuation registered) rather than startedTargets, so completeNextStart below
        // deterministically finds it under parallel-test load.
        releaser.release()
        await waitFor { controller.pendingStartCount == 1 }
        XCTAssertEqual(controller.startedTargets.count, 1)

        controller.completeNextStart(success: true)
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }
    }

    // Stopping a Product Real session registers its teardown with the gate, so the next start waits.
    func testProductStopRegistersTeardownWithSettleGate() async {
        let spyGate = SpyStartSettleGate()
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller, productRealStartSettleGate: spyGate)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        XCTAssertEqual(spyGate.registeredStopCount, 0)

        harness.viewModel.toggleExperimentalControl(for: "spotify")
        await waitFor { spyGate.registeredStopCount == 1 }
    }

    // Combination change: with app A active, stopping A and starting B makes B's start settle
    // exactly once (because A's teardown preceded it), proving the gate bridges stop A → start B.
    func testCombinationChangeStartBSettlesAfterStopATeardown() async {
        let sleeper = TestRecordingSleeper()
        let gate = ProductRealStartSettleGate(sleeper: { await sleeper.sleep($0) })
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller, productRealStartSettleGate: gate)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        // First start (A): no prior teardown, so no settle.
        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        XCTAssertEqual(sleeper.delays.count, 0)

        // Stop A.
        harness.viewModel.toggleExperimentalControl(for: "spotify")
        await waitFor { controller.stoppedSessionIDs.count == 1 }

        // Start B: the gate awaits A's teardown and settles once before B's session is created.
        // Wait on the pending start (settle already ran, continuation registered) so the
        // completion below is deterministic under parallel-test load.
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { controller.pendingStartCount == 1 && controller.startedTargets.contains { $0.appID == "music" } }
        XCTAssertEqual(sleeper.delays.count, 1)

        controller.completeNextStart(success: true)
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "music") }
    }

    // The stale-start orphan-cleanup path (a start that completed after being superseded) also
    // registers its teardown with the gate, so a later start waits for that orphan teardown too.
    func testStaleStartOrphanCleanupRegistersTeardownWithSettleGate() async {
        let spyGate = SpyStartSettleGate()
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true)
        ])
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(
            liveController: controller,
            outputDeviceLister: outputDeviceLister,
            productRealStartSettleGate: spyGate
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }

        // Output device change supersedes the pending start before it completes.
        outputDeviceLister.devices = [makeLiveControlOutputDevice(id: "airpods", isDefault: true)]
        harness.viewModel.refreshOutputDevices()

        // The stale start completes; its orphan session is cleaned up and registered with the gate.
        controller.completeNextStart(success: true)
        await waitFor { controller.stoppedSessionIDs.count == 1 && spyGate.registeredStopCount >= 1 }
    }

    func testToggleDuringPendingStartIsIgnoredWhileAnotherAppStaysActive() async {
        // Previously this exercised a per-app toggle-cancel of a pending start. The rapid-toggle
        // guard now intentionally ignores a toggle while that row's start is in flight, so this
        // pins the new behavior: the ignored toggles do not disturb Music, and Spotify's start
        // proceeds to active with no spurious stop. (Stale-start-vs-other-app isolation via app/
        // helper exit is covered by testVisibleAppExitWhileHelperLingers... and the unknown-callback
        // tests.)
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        // Music becomes a confirmed active session.
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { controller.pendingStartCount == 1 }
        controller.completeNextStart(success: true)
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "music") }

        // Spotify start is pending.
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }
        XCTAssertTrue(harness.viewModel.isExperimentalControlPending(for: "spotify"))

        // Toggle attempts on Spotify while its start is pending are ignored by the guard.
        harness.viewModel.toggleExperimentalControl(for: "spotify")
        harness.viewModel.toggleExperimentalControl(for: "spotify")
        controller.completeNextStart(success: true)
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertEqual(controller.stoppedSessionIDs.count, 0)
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
    }

    // Note: a same-app A1/A2 both-pending race is not reachable through the public API —
    // the queued start lane serialises Product starts, so a second start cannot begin
    // while the first is still in flight. The per-app token's same-app supersession is covered
    // by ProductRealControlStateTests.testNewStartRequestForSameAppSupersedesPrevious.

    func testStaleDiagnosticsAfterCancelledStartDoNotRepopulateState() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        // Display visible, so this exercises the stale-callback rejection, not the hidden-display gate.
        harness.viewModel.setLiveDiagnosticsDisplayVisible(true)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }
        harness.viewModel.setExperimentalRealAppControlEnabled(false)
        await drainMainActor()

        XCTAssertNil(harness.viewModel.processTapLiveDiagnostics)
        controller.emitDiagnosticsForPendingStart(at: 0)
        await drainMainActor()
        XCTAssertNil(harness.viewModel.processTapLiveDiagnostics)
    }

    // MARK: - Product live diagnostics are published only while the Advanced display is visible
    //
    // The fake controller emits one diagnostics snapshot (callbackCount 10) while a session starts,
    // before `startSession` returns, so its main-actor hop is handled before the start's post-await
    // block; once the start has settled (`!isProcessTapTesting`) the snapshot has been processed.

    func testLiveDiagnosticsDisplayDefaultsHiddenAndIsSettable() {
        let harness = makeHarness()
        XCTAssertFalse(harness.viewModel.isLiveDiagnosticsDisplayVisible)

        harness.viewModel.setLiveDiagnosticsDisplayVisible(true)
        XCTAssertTrue(harness.viewModel.isLiveDiagnosticsDisplayVisible)
        harness.viewModel.setLiveDiagnosticsDisplayVisible(false)
        XCTAssertFalse(harness.viewModel.isLiveDiagnosticsDisplayVisible)
    }

    func testProductLiveDiagnosticsNotPublishedWhileDisplayHidden() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        await drainMainActor()

        // The start itself still reports normally; only the per-callback snapshot is withheld, so
        // the shared surface keeps the start's cleared diagnostics and zero progress.
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertEqual(harness.viewModel.processTapTestResult?.outcome, .liveControlStarted)
        XCTAssertNil(harness.viewModel.processTapLiveDiagnostics)
        XCTAssertEqual(harness.viewModel.processTapDiagnosticProgress?.callbackCount, 0)
    }

    func testProductLiveDiagnosticsPublishedWhileDisplayVisible() async {
        let harness = makeHarness()
        harness.viewModel.setLiveDiagnosticsDisplayVisible(true)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor {
            harness.viewModel.processTapLiveDiagnostics?.callbackCount == 10
                && !harness.viewModel.isProcessTapTesting
        }

        XCTAssertEqual(harness.viewModel.processTapDiagnosticProgress?.callbackCount, 10)
        XCTAssertEqual(harness.viewModel.processTapTestResult?.outcome, .liveControlStarted)
    }

    func testProductStopResultDiagnosticsAppliedWhileDisplayHidden() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        XCTAssertNil(harness.viewModel.processTapLiveDiagnostics)

        // The stop display cleanup is not gated: the stopped session's final diagnostics and the
        // stop result reach the shared surface even while the display is hidden.
        harness.viewModel.toggleExperimentalControl(for: "spotify")
        await waitFor {
            !harness.viewModel.isExperimentalControlActive(for: "spotify")
                && harness.viewModel.processTapLiveDiagnostics?.callbackCount == 10
        }

        XCTAssertEqual(harness.viewModel.processTapTestResult?.outcome, .liveControlStopped)
        XCTAssertEqual(harness.viewModel.processTapDiagnosticProgress?.callbackCount, 10)
    }

    func testAdvancedManualLiveDiagnosticsUnaffectedByDisplayVisibility() async {
        let harness = makeHarness()
        XCTAssertFalse(harness.viewModel.isLiveDiagnosticsDisplayVisible)
        harness.viewModel.selectProcessTapApp("music")

        harness.viewModel.startProcessTapLiveControl()
        await waitFor {
            harness.viewModel.isProcessTapLiveControlActive
                && harness.viewModel.processTapLiveDiagnostics?.callbackCount == 10
        }

        XCTAssertEqual(harness.viewModel.processTapDiagnosticProgress?.callbackCount, 10)
    }

    func testPerAppStopOfConfirmedSessionDoesNotDisturbAnotherAppsPendingStart() async {
        // Per-app stop isolation with a pending peer: stopping one confirmed session (Music) while a
        // different app (Spotify) has a start still in flight must tear down only Music and leave
        // Spotify's pending start free to complete. (The former per-app toggle-cancel of a *pending*
        // start is no longer reachable — the rapid-toggle guard ignores a toggle while that same
        // row's start is pending.)
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { controller.pendingStartCount == 1 }
        controller.completeNextStart(success: true)
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "music") }

        // Spotify's start is pending (a different row from the one being stopped).
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }
        XCTAssertTrue(harness.viewModel.isExperimentalControlPending(for: "spotify"))

        // Stop Music (a confirmed session) per-app while Spotify's start is still pending.
        harness.viewModel.toggleExperimentalControl(for: "music")
        await waitFor { !harness.viewModel.isExperimentalControlActive(for: "music") }

        // Spotify's pending start was not disturbed: it completes and becomes active.
        controller.completeNextStart(success: true)
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertFalse(harness.viewModel.isExperimentalControlPending(for: "spotify"))
    }

    func testThreeConcurrentStartsPreservedWithControlledCompletion() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        // Three apps are confirmed one at a time through controlled
        // completion. `startConfirmedProductSession` waits for each start to fully settle
        // (session id recorded, isProcessTapTesting back to false) before the next, which keeps
        // the serialized start path deterministic instead of racing the next start.
        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "youtube", harness: harness, controller: controller)

        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "youtube"))
        XCTAssertEqual(controller.startTimeoutPolicies, [.indefinite, .indefinite, .indefinite])
    }

    // MARK: - Phase 4a: multi-app lifecycle isolation characterization
    //
    // These lock in the per-session lifecycle guarantees for two concurrent Product sessions:
    // output-device change tears both down by their own ids, an app/helper exit clears only the
    // exiting session, an unknown/stale callback clears nothing, and a global stop with a pending
    // start rejects the late completion. They are behaviour-neutral (no production changes) and
    // deterministic (controlled continuations + real state signals, no fixed sleeps/yields).

    /// Starts and confirms a Product session for `appID` on a controlled harness, returning the
    /// engine session id the view model now owns for it.
    private func startConfirmedProductSession(
        for appID: MixerAppItem.ID,
        harness: ControlledHarness,
        controller: FakeControlledLiveController
    ) async -> ProcessTapLiveSessionID {
        let alreadyStarted = controller.startedSessionIDs.count
        harness.viewModel.setAppVolume(50, for: appID)
        await waitFor { controller.pendingStartCount == 1 }
        controller.completeNextStart(success: true)
        await waitFor {
            harness.viewModel.isExperimentalControlActive(for: appID)
                && controller.startedSessionIDs.count == alreadyStarted + 1
                && !harness.viewModel.isProcessTapTesting
        }
        return controller.startedSessionIDs[alreadyStarted]
    }

    func testTwoActiveSessionsOutputDeviceChangeStopsBothByOwnIDAndInvalidatesCacheGlobally() async {
        let controller = FakeControlledLiveController()
        let resolver = FakeAppAudioTargetResolver()
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true)
        ])
        let harness = makeControlledHarness(
            liveController: controller,
            outputDeviceLister: outputDeviceLister,
            appAudioTargetResolver: resolver
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        let spotifyID = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        let musicID = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)

        // Two confirmed sessions with distinct, non-nil engine session ids.
        XCTAssertEqual(controller.startedSessionIDs, [spotifyID, musicID])
        XCTAssertEqual(Set([spotifyID, musicID]).count, 2)
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))

        // Trigger the output-device change through the real view model lifecycle path.
        outputDeviceLister.devices = [makeLiveControlOutputDevice(id: "airpods", isDefault: true)]
        harness.viewModel.refreshOutputDevices()
        await waitFor { controller.stoppedSessionIDs.count == 2 }
        await waitFor { !harness.viewModel.isProcessTapLiveControlActive }

        // Both sessions stopped, each by its own id, for the output-device-changed reason.
        XCTAssertEqual(Set(controller.stoppedSessionIDs), Set([spotifyID, musicID]))
        XCTAssertEqual(controller.stoppedReasons, [.outputDeviceChanged, .outputDeviceChanged])

        // Both apps cleared from Product active state.
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)

        // Helper cache invalidated globally exactly once for the device change.
        XCTAssertEqual(resolver.invalidateAllCount, 1)

        // No pending completion can resurrect a session: both starts were already confirmed, so
        // the pending-request invalidation + stale-late-completion sub-cases are covered by the
        // global-stop test below and the existing stale-output test. A no-op completion here must
        // not reactivate anything.
        controller.completeNextStart(success: true)
        await drainMainActor()
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
    }

    func testActiveSessionAppExitCallbackClearsOnlyThatSessionAndLeavesOtherActive() async {
        let controller = FakeControlledLiveController()
        let resolver = FakeAppAudioTargetResolver()
        let harness = makeControlledHarness(liveController: controller, appAudioTargetResolver: resolver)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        let spotifyID = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        let musicID = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)

        // App A (spotify) exits via the engine's per-session stopped callback.
        controller.emitSessionStopped(handlerForSessionID: spotifyID, outcome: .liveControlAppExited)
        await waitFor { !harness.viewModel.isExperimentalControlActive(for: "spotify") }

        // Only A is cleared; B (music) keeps its session, identity and active state.
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "music")

        // Only A's target cache is invalidated; no global stop (an exit arrives via onStopped,
        // never through stopSession, so stoppedSessionIDs stays empty and B is never stopped).
        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["spotify"])
        XCTAssertTrue(controller.stoppedSessionIDs.isEmpty)

        // B's slider still routes gain only to B's still-live session.
        harness.viewModel.setAppVolume(25, for: "music")
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))

        // A redelivered exit for the already-cleared session is idempotent (routed via B's
        // handler but reporting A's id): handleProductLiveControlStopped finds no such session
        // and returns without touching B.
        controller.emitSessionStopped(handlerForSessionID: musicID, reportedSessionID: spotifyID, outcome: .liveControlAppExited)
        await drainMainActor()
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["spotify"])
        XCTAssertTrue(controller.stoppedSessionIDs.isEmpty)
    }

    func testActiveSessionHelperExitCallbackClearsOnlyThatSessionAndInvalidatesItsHelperCache() async {
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        ])
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(
            liveController: controller,
            appAudioTargetResolver: resolver,
            eligibilityByPID: [200: .unavailable("Core Audio process unavailable"), 201: .eligible]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        // A = youtube via a resolved helper; B = spotify direct.
        let youtubeID = await startConfirmedProductSession(for: "youtube", harness: harness, controller: controller)
        let spotifyID = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        XCTAssertEqual(resolver.resolveRequests.map(\.appID), ["youtube"])
        XCTAssertNotEqual(youtubeID, spotifyID)

        // A's helper PID exits.
        controller.emitSessionStopped(handlerForSessionID: youtubeID, outcome: .liveControlAppExited)
        await waitFor { !harness.viewModel.isExperimentalControlActive(for: "youtube") }

        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "youtube"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
        // Helper cache invalidated for the visible app only; B untouched; no global stop.
        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["youtube"])
        XCTAssertTrue(controller.stoppedSessionIDs.isEmpty)
    }

    func testUnknownSessionStoppedCallbackLeavesBothActiveSessionsUntouched() async {
        let controller = FakeControlledLiveController()
        let resolver = FakeAppAudioTargetResolver()
        let harness = makeControlledHarness(liveController: controller, appAudioTargetResolver: resolver)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        let spotifyID = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)
        XCTAssertNil(harness.viewModel.statusMessage)

        // A stopped/exit callback whose reported id belongs to no tracked session (routed via
        // spotify's still-registered handler so the production onStopped path runs, but reporting
        // an unknown id). Neither session must be cleared.
        let unknownID = ProcessTapLiveSessionID()
        controller.emitSessionStopped(handlerForSessionID: spotifyID, reportedSessionID: unknownID, outcome: .liveControlAppExited)
        await drainMainActor()

        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNotNil(harness.viewModel.activeExperimentalAppID)
        // No spurious teardown, cache invalidation, or status/diagnostics clobbering.
        XCTAssertTrue(controller.stoppedSessionIDs.isEmpty)
        XCTAssertTrue(resolver.invalidatedRequests.isEmpty)
        XCTAssertEqual(resolver.invalidateAllCount, 0)
        XCTAssertNil(harness.viewModel.statusMessage)
    }

    func testGlobalStopWithConfirmedAndPendingSessionStopsConfirmedRejectsPendingLateSuccess() async {
        // Two simultaneous optimistic/pending Product starts are NOT reachable through the public
        // API: the queued start lane serialises Product starts, so a second start cannot
        // begin while the first is still pending (same-app or cross-app). The strongest reachable
        // mix is therefore one confirmed session plus one pending optimistic start.
        let controller = FakeControlledLiveController()
        let resolver = FakeAppAudioTargetResolver()
        let harness = makeControlledHarness(liveController: controller, appAudioTargetResolver: resolver)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        // A confirmed.
        let spotifyID = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)

        // B pending optimistic (start suspended, not yet confirmed).
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { controller.pendingStartCount == 1 }
        XCTAssertEqual(controller.startedSessionIDs.count, 2)
        let musicID = controller.startedSessionIDs[1]

        // Global stop (Real App Control OFF).
        harness.viewModel.setExperimentalRealAppControlEnabled(false)
        await waitFor { !harness.viewModel.isExperimentalControlActive(for: "spotify") }

        // The confirmed session is stopped by its own id; the pending one carries no live id yet.
        XCTAssertEqual(controller.stoppedSessionIDs, [spotifyID])

        // B's late success arrives — it is stale (pending request invalidated) and must not
        // reactivate; its orphan engine session is torn down by its own id.
        controller.completeNextStart(success: true)
        await waitFor { controller.stoppedSessionIDs.count == 2 }

        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
        XCTAssertEqual(Set(controller.stoppedSessionIDs), Set([spotifyID, musicID]))
        // Global helper cache clear preserved on the toggle-off path.
        XCTAssertEqual(resolver.invalidateAllCount, 1)
    }

    func testVisibleAppExitWhileHelperLingersTearsDownOnlyThatSessionLeavesOtherActive() async {
        // A = youtube via a resolved helper PID 201; B = spotify direct. When youtube's visible
        // app exits the app list (its helper PID may briefly linger), refreshApplications tears
        // down only youtube's session by its own id and leaves spotify untouched.
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        ])
        let liveController = FakeLiveControlController()
        let harness = makeHarness(
            liveController: liveController,
            appAudioTargetResolver: resolver,
            eligibilityByPID: [200: .unavailable("Core Audio process unavailable"), 201: .eligible]
        )
        // Point the Advanced diagnostic selection at the app that is about to exit. Losing the
        // selected app must stop only Advanced manual control (none is running here), never the
        // surviving product session — so this also covers the selection-refresh path.
        harness.viewModel.selectProcessTapApp("youtube")
        XCTAssertEqual(harness.viewModel.selectedProcessTapAppID, "youtube")
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        // Wait for each start to FULLY settle (post-await confirmation ran, session id recorded,
        // isProcessTapTesting back to false). isExperimentalControlActive alone is not a reliable
        // confirm signal for the second app: once the first session is confirmed the derived
        // live-control flag is already true, so it would read active during the second app's
        // optimistic (pre-confirm) window. This mirrors testSecondAppStartsConcurrentProductSession.
        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedSessionIDs.count == 2 && !harness.viewModel.isProcessTapTesting }
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "youtube"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))

        // youtube's visible app exits; its helper PID 201 stays eligible (lingers).
        harness.appLister.apps = makeLiveControlApps().filter { $0.id != "youtube" }
        harness.viewModel.refreshApplications()
        await waitFor { !harness.viewModel.isExperimentalControlActive(for: "youtube") }

        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
        // Only youtube's session was stopped, and for the target-app-exited reason.
        XCTAssertEqual(liveController.stopReasons, [.targetAppExited])
    }

    // MARK: - Advanced-selected app exit with several Product sessions
    //
    // The Advanced picker defaults to the first eligible app, so quitting that app used to route
    // through the global stop and tear down every Product session. Losing the selection now stops
    // only Advanced manual control; Product sessions are stopped per exited app only. The spy gate
    // records each teardown synchronously, so the stop count is asserted without any waiting.

    func testQuittingAdvancedSelectedAppStopsOnlyItsOwnProductSessionAndLeavesOthersRunning() async {
        let spyGate = SpyStartSettleGate()
        let harness = makeHarness(productRealStartSettleGate: spyGate)
        // Production default: the Advanced picker selects the first eligible app (Spotify).
        XCTAssertEqual(harness.viewModel.selectedProcessTapAppID, "spotify")
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { harness.liveController.startedSessionIDs.count == 2 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { harness.liveController.startedSessionIDs.count == 3 && !harness.viewModel.isProcessTapTesting }
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 3)

        // The Advanced-selected app (Spotify) quits.
        harness.appLister.apps = makeLiveControlApps().filter { $0.id != "spotify" }
        harness.viewModel.refreshApplications()

        // Exactly one teardown was issued (Spotify's per-app stop); no global stop of all sessions.
        XCTAssertEqual(spyGate.registeredStopCount, 1)

        await waitFor {
            !harness.viewModel.isExperimentalControlActive(for: "spotify")
                && !harness.viewModel.isExperimentalControlPending(for: "spotify")
        }

        XCTAssertEqual(harness.liveController.stopReasons, [.targetAppExited])
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "youtube"))
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlAppNames, ["Music", "YouTube"])
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
        // The Advanced picker falls back to a surviving app.
        XCTAssertEqual(harness.viewModel.selectedProcessTapAppID, "music")
    }

    func testQuittingAdvancedSelectedAppWithoutProductSessionLeavesEveryProductSessionRunning() async {
        let spyGate = SpyStartSettleGate()
        let harness = makeHarness(productRealStartSettleGate: spyGate)
        XCTAssertEqual(harness.viewModel.selectedProcessTapAppID, "spotify")
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        // Product sessions run for Music and YouTube; the Advanced-selected app (Spotify) has none.
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { harness.liveController.startedSessionIDs.count == 2 && !harness.viewModel.isProcessTapTesting }

        harness.appLister.apps = makeLiveControlApps().filter { $0.id != "spotify" }
        harness.viewModel.refreshApplications()

        // No teardown at all: neither product session belongs to the quitting app.
        XCTAssertEqual(spyGate.registeredStopCount, 0)
        await drainMainActor()

        XCTAssertTrue(harness.liveController.stopReasons.isEmpty)
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "youtube"))
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 2)
        XCTAssertFalse(harness.viewModel.isExperimentalControlPending(for: "music"))
        XCTAssertFalse(harness.viewModel.isExperimentalControlPending(for: "youtube"))
        XCTAssertEqual(harness.viewModel.selectedProcessTapAppID, "music")
    }

    // The guard still stops Advanced manual control when its (selected) target app quits.
    func testQuittingAdvancedSelectedAppStillStopsAdvancedManualLiveControl() async {
        let harness = makeHarness()
        harness.viewModel.selectProcessTapApp("music")
        harness.viewModel.startProcessTapLiveControl()
        await waitFor { harness.viewModel.isProcessTapLiveControlActive }

        harness.appLister.apps = makeLiveControlApps().filter { $0.id != "music" }
        harness.viewModel.refreshApplications()
        await waitFor { !harness.viewModel.isProcessTapLiveControlActive }

        XCTAssertEqual(harness.liveController.stopReasons, [.targetAppExited])
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
    }

    // MARK: - Phase 3d-iii step 1: confirmed Product Real Control banner model
    //
    // These lock in the data the multi-app banner will read: the visible app names of confirmed
    // Product sessions, in stable apps order, excluding pending starts, hiding helper identity,
    // and never counting Advanced Manual Live control as a Product session. Pure/computed only —
    // no SwiftUI here. Deterministic (controlled continuations + real state signals).

    func testBannerModelIsEmptyWithNoConfirmedSessionAndIgnoresPendingStart() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        XCTAssertEqual(harness.viewModel.confirmedProductRealControlAppNames, [])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 0)

        // A pending (optimistic, not-yet-confirmed) start must not appear as confirmed.
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlAppNames, [])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 0)
    }

    func testBannerModelReportsSingleConfirmedDirectSession() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)

        XCTAssertEqual(harness.viewModel.confirmedProductRealControlAppNames, ["Spotify"])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 1)
    }

    func testBannerModelUsesVisibleAppNameForHelperControlledSessionAndHidesHelperName() async {
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    // Helper process name deliberately differs from the visible app name.
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "com.apple.WebKit.GPU", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        ])
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(
            liveController: controller,
            appAudioTargetResolver: resolver,
            eligibilityByPID: [200: .unavailable("Core Audio process unavailable"), 201: .eligible]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "youtube", harness: harness, controller: controller)

        XCTAssertEqual(harness.viewModel.confirmedProductRealControlAppNames, ["YouTube"])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 1)
        XCTAssertFalse(harness.viewModel.confirmedProductRealControlAppNames.contains("com.apple.WebKit.GPU"))
    }

    func testBannerModelReportsTwoConfirmedSessionsInAppsOrder() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)

        // apps order is [spotify, music, youtube].
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlAppNames, ["Spotify", "Music"])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 2)
    }

    func testBannerModelOrderFollowsAppsListNotSessionInsertionOrder() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        // Start in reverse apps order: music (apps index 1) before spotify (apps index 0).
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)

        // Result still follows apps order, not dictionary insertion order.
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlAppNames, ["Spotify", "Music"])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 2)
    }

    func testBannerModelExcludesPendingSessionWhileIncludingConfirmedOne() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)

        // music is pending optimistic (start suspended, not confirmed).
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { controller.pendingStartCount == 1 }

        XCTAssertEqual(harness.viewModel.confirmedProductRealControlAppNames, ["Spotify"])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 1)
    }

    func testBannerModelUpdatesWhenOneOfTwoSessionsIsStopped() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 2)

        harness.viewModel.toggleExperimentalControl(for: "spotify")
        await waitFor { !harness.viewModel.isExperimentalControlActive(for: "spotify") }

        XCTAssertEqual(harness.viewModel.confirmedProductRealControlAppNames, ["Music"])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 1)
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
    }

    func testBannerModelClearsAfterGlobalStop() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)

        harness.viewModel.setExperimentalRealAppControlEnabled(false)
        await waitFor { !harness.viewModel.isProcessTapLiveControlActive }

        XCTAssertEqual(harness.viewModel.confirmedProductRealControlAppNames, [])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 0)
    }

    func testBannerModelUnchangedByUnknownStoppedCallback() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        let spotifyID = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)

        // A stopped callback reporting a session id that belongs to no tracked session.
        let unknownID = ProcessTapLiveSessionID()
        controller.emitSessionStopped(handlerForSessionID: spotifyID, reportedSessionID: unknownID, outcome: .liveControlAppExited)
        await drainMainActor()

        XCTAssertEqual(harness.viewModel.confirmedProductRealControlAppNames, ["Spotify", "Music"])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 2)
    }

    func testBannerModelDoesNotCountAdvancedManualLiveControlAsProductSession() async {
        let harness = makeHarness()
        harness.viewModel.selectProcessTapApp("music")
        harness.viewModel.startProcessTapLiveControl()
        await waitFor { harness.viewModel.isProcessTapLiveControlActive }

        // Advanced Manual Live is active, but it is not a Product session.
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlAppNames, [])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 0)
        // Existing manual banner state is preserved.
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "Music")
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
    }

    // MARK: - Phase 3d-iii step 2: Real Control banner presentation
    //
    // These lock in the pure presentation the SwiftUI banner reads: summary text, stop-button
    // title (Stop vs Stop All), and accessibility wording — for Product (1/2 apps), pending
    // exclusion, stop/global-stop updates, stale-callback stability, and Advanced Manual mode.

    func testBannerPresentationProductSingleSessionUsesStopAndAppName() async throws {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)

        let banner = try XCTUnwrap(harness.viewModel.realControlBannerPresentation)
        XCTAssertEqual(banner.mode, .product)
        XCTAssertEqual(banner.appNames, ["Spotify"])
        XCTAssertEqual(banner.confirmedCount, 1)
        XCTAssertEqual(banner.summaryText, "Real control: Spotify")
        XCTAssertEqual(banner.stopButtonTitle, "Stop")
        XCTAssertEqual(banner.accessibilityLabel, "Real control active for Spotify")
        XCTAssertEqual(banner.stopAccessibilityLabel, "Stop real control for Spotify")
    }

    func testBannerPresentationProductTwoSessionsUsesStopAllAndBothNames() async throws {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)

        let banner = try XCTUnwrap(harness.viewModel.realControlBannerPresentation)
        XCTAssertEqual(banner.mode, .product)
        XCTAssertEqual(banner.appNames, ["Spotify", "Music"])
        XCTAssertEqual(banner.confirmedCount, 2)
        XCTAssertEqual(banner.summaryText, "Real control: Spotify, Music")
        XCTAssertEqual(banner.stopButtonTitle, "Stop All")
        XCTAssertEqual(banner.accessibilityLabel, "Real control active for 2 apps: Spotify, Music")
        XCTAssertEqual(banner.stopAccessibilityLabel, "Stop real control for all apps")
    }

    // 3+ banner: the visible summary collapses to "first two + N more" so the one-line panel
    // does not truncate mid-name, while the accessibility label keeps the full ordered list.
    func testBannerPresentationThreeSessionsShowsFirstTwoPlusMore() async throws {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "youtube", harness: harness, controller: controller)

        let banner = try XCTUnwrap(harness.viewModel.realControlBannerPresentation)
        XCTAssertEqual(banner.mode, .product)
        XCTAssertEqual(banner.appNames, ["Spotify", "Music", "YouTube"])
        XCTAssertEqual(banner.confirmedCount, 3)
        XCTAssertEqual(banner.summaryText, "Real control: Spotify, Music +1 more")
        XCTAssertEqual(banner.stopButtonTitle, "Stop All")
        XCTAssertEqual(banner.accessibilityLabel, "Real control active for 3 apps: Spotify, Music, YouTube")
        XCTAssertEqual(banner.stopAccessibilityLabel, "Stop real control for all apps")
    }

    func testBannerPresentationOrderFollowsAppsListNotInsertionOrder() async throws {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        // Start in reverse apps order.
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)

        let banner = try XCTUnwrap(harness.viewModel.realControlBannerPresentation)
        XCTAssertEqual(banner.summaryText, "Real control: Spotify, Music")
    }

    func testBannerPresentationHelperSessionShowsVisibleNameNotHelperName() async throws {
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "com.apple.WebKit.GPU", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        ])
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(
            liveController: controller,
            appAudioTargetResolver: resolver,
            eligibilityByPID: [200: .unavailable("Core Audio process unavailable"), 201: .eligible]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "youtube", harness: harness, controller: controller)

        let banner = try XCTUnwrap(harness.viewModel.realControlBannerPresentation)
        XCTAssertEqual(banner.summaryText, "Real control: YouTube")
        XCTAssertFalse(banner.summaryText.contains("com.apple.WebKit.GPU"))
        XCTAssertFalse(banner.accessibilityLabel.contains("com.apple.WebKit.GPU"))
    }

    func testBannerPresentationExcludesPendingSessionFromSummary() async throws {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { controller.pendingStartCount == 1 }

        let banner = try XCTUnwrap(harness.viewModel.realControlBannerPresentation)
        XCTAssertEqual(banner.summaryText, "Real control: Spotify")
        XCTAssertEqual(banner.confirmedCount, 1)
        XCTAssertEqual(banner.stopButtonTitle, "Stop")
    }

    func testBannerPresentationAdvancedManualKeepsSingleAppNameAndStop() async throws {
        let harness = makeHarness()
        harness.viewModel.selectProcessTapApp("music")
        harness.viewModel.startProcessTapLiveControl()
        await waitFor { harness.viewModel.isProcessTapLiveControlActive }

        let banner = try XCTUnwrap(harness.viewModel.realControlBannerPresentation)
        XCTAssertEqual(banner.mode, .advancedManual)
        XCTAssertEqual(banner.summaryText, "Real control: Music")
        XCTAssertEqual(banner.stopButtonTitle, "Stop")
        XCTAssertEqual(banner.confirmedCount, 0)
        XCTAssertEqual(banner.accessibilityLabel, "Real control active for Music")
    }

    func testBannerPresentationIsNilWhenNothingActive() {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
    }

    func testBannerPresentationUpdatesFromTwoToOneAfterStoppingOne() async throws {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)

        harness.viewModel.toggleExperimentalControl(for: "spotify")
        await waitFor { !harness.viewModel.isExperimentalControlActive(for: "spotify") }

        let banner = try XCTUnwrap(harness.viewModel.realControlBannerPresentation)
        XCTAssertEqual(banner.summaryText, "Real control: Music")
        XCTAssertEqual(banner.stopButtonTitle, "Stop")
        XCTAssertEqual(banner.confirmedCount, 1)
    }

    func testBannerPresentationIsNilAfterGlobalStop() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)

        harness.viewModel.setExperimentalRealAppControlEnabled(false)
        await waitFor { !harness.viewModel.isProcessTapLiveControlActive }

        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
    }

    func testBannerPresentationUnchangedByUnknownStoppedCallback() async throws {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        let spotifyID = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)
        _ = await startConfirmedProductSession(for: "music", harness: harness, controller: controller)

        let unknownID = ProcessTapLiveSessionID()
        controller.emitSessionStopped(handlerForSessionID: spotifyID, reportedSessionID: unknownID, outcome: .liveControlAppExited)
        await drainMainActor()

        let banner = try XCTUnwrap(harness.viewModel.realControlBannerPresentation)
        XCTAssertEqual(banner.summaryText, "Real control: Spotify, Music")
        XCTAssertEqual(banner.stopButtonTitle, "Stop All")
        XCTAssertEqual(banner.confirmedCount, 2)
    }

    // MARK: - Phase 4c-2: system sleep teardown (handleSystemWillSleep)
    //
    // handleSystemWillSleep() is the directly-callable @MainActor cleanup the willSleep observer
    // invokes synchronously on the main thread. These tests call it directly (no real system sleep,
    // and no panel/onAppear — the observer is owned by the app-lifetime view model, so cleanup is
    // independent of panel lifecycle). They lock in: confirmed Product teardown with .systemSleep,
    // banner/state clearing, helper cache invalidation, pending/late-completion stale safety,
    // Advanced Manual stop, Two-App Readiness reason forwarding, idempotency, and sleep-then-quit.

    func testSystemSleepTearsDownConfirmedProductSessionsAndClearsBanner() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { harness.liveController.startedSessionIDs.count == 2 && !harness.viewModel.isProcessTapTesting }
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 2)

        harness.viewModel.handleSystemWillSleep()

        // Engine torn down with the system-sleep reason; all Product/banner state cleared; helper
        // cache globally invalidated.
        XCTAssertEqual(harness.liveController.stopReasons, [.systemSleep])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 0)
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)
        XCTAssertGreaterThanOrEqual(harness.appAudioTargetResolver.invalidateAllCount, 1)
    }

    func testSystemSleepWithConfirmedAndPendingRejectsLateSuccessWithoutResurrection() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        _ = await startConfirmedProductSession(for: "spotify", harness: harness, controller: controller)

        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { controller.pendingStartCount == 1 }
        XCTAssertEqual(controller.startedSessionIDs.count, 2)
        let musicID = controller.startedSessionIDs[1]

        harness.viewModel.handleSystemWillSleep()

        // Confirmed app's Product state is cleared immediately; banner gone.
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)

        // The pending start's late success is stale (token invalidated); its orphan engine session
        // is torn down by its own id, and nothing is reactivated.
        controller.completeNextStart(success: true)
        await waitFor { controller.stoppedSessionIDs.contains(musicID) }

        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
    }

    func testSystemSleepDuringPendingDirectStartRejectsLateCompletion() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }
        let spotifyID = controller.startedSessionIDs[0]

        harness.viewModel.handleSystemWillSleep()

        controller.completeNextStart(success: true)
        await waitFor { controller.stoppedSessionIDs.contains(spotifyID) }

        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
    }

    func testSystemSleepCancelsInFlightHelperResolutionAndIgnoresLateResult() async {
        let resolver = FakeAppAudioTargetResolver(suspendsWhenNoResultIsAvailable: true)
        let harness = makeHarness(
            appAudioTargetResolver: resolver,
            eligibilityByPID: [200: .unavailable("Core Audio process unavailable"), 201: .eligible]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "youtube")
        await waitFor { resolver.resolveRequests.count == 1 }
        XCTAssertTrue(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))

        harness.viewModel.handleSystemWillSleep()

        XCTAssertEqual(resolver.cancelledReasons, [.userStopped])
        XCTAssertFalse(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))
        XCTAssertGreaterThanOrEqual(resolver.invalidateAllCount, 1)

        resolver.completeNext(
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(appID: "helper:youtube:201", appName: "YouTube", processIdentifier: 201),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        )
        await drainMainActor()

        XCTAssertTrue(harness.liveController.startedTargets.isEmpty)
        XCTAssertFalse(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
    }

    func testSystemSleepStopsAdvancedManualLiveControl() async {
        let harness = makeHarness()
        harness.viewModel.selectProcessTapApp("music")
        harness.viewModel.startProcessTapLiveControl()
        await waitFor { harness.viewModel.isProcessTapLiveControlActive }

        harness.viewModel.handleSystemWillSleep()

        XCTAssertEqual(harness.liveController.stopReasons, [.systemSleep])
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
    }

    func testSystemSleepForwardsSystemSleepReasonToTwoAppReadiness() async {
        let tester = FakeLiveControlTwoAppReadinessTester()
        let harness = makeHarness(twoAppReadinessTester: tester)

        harness.viewModel.handleSystemWillSleep()

        // The two-app readiness test is torn down through its synchronous stop path with the
        // system-sleep reason (a normal controlled stop, not timeout/failure).
        XCTAssertEqual(tester.stopAllNowReasons, [.systemSleep])
    }

    func testRepeatedSystemSleepIsIdempotent() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }

        harness.viewModel.handleSystemWillSleep()
        harness.viewModel.handleSystemWillSleep()

        XCTAssertEqual(harness.liveController.stopReasons, [.systemSleep, .systemSleep])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 0)
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
    }

    func testSystemSleepThenTerminationIsSafe() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }

        harness.viewModel.handleSystemWillSleep()
        harness.viewModel.stopProcessTapLiveControlForTermination()

        // Each teardown carries its own reason; the second is a safe no-op over already-clear state.
        XCTAssertEqual(harness.liveController.stopReasons, [.systemSleep, .appTerminating])
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 0)
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
    }

    // MARK: - Phase 4c-3: system wake refresh (handleSystemDidWake)
    //
    // handleSystemDidWake() is refresh-only: it reconciles output devices, system volume, and the
    // app list after wake, but never restarts a Product session, resolves helpers, or changes the
    // Real App Control toggle. Tests call it directly (no real wake, no panel/onAppear).

    func testSystemDidWakeDoesNotStartProductSession() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.handleSystemDidWake()

        XCTAssertTrue(harness.liveController.startedTargets.isEmpty)
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 0)
    }

    func testSystemDidWakeDoesNotChangeRealControlToggle() async {
        let enabledHarness = makeHarness()
        enabledHarness.viewModel.setExperimentalRealAppControlEnabled(true)
        enabledHarness.viewModel.handleSystemDidWake()
        XCTAssertTrue(enabledHarness.viewModel.isExperimentalRealAppControlEnabled)

        let disabledHarness = makeHarness()
        disabledHarness.viewModel.handleSystemDidWake()
        XCTAssertFalse(disabledHarness.viewModel.isExperimentalRealAppControlEnabled)
    }

    func testSystemDidWakeRefreshesOutputDeviceList() async {
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true)
        ])
        let harness = makeHarness(outputDeviceLister: outputDeviceLister)

        outputDeviceLister.devices = [
            makeLiveControlOutputDevice(id: "built-in"),
            makeLiveControlOutputDevice(id: "airpods", isDefault: true)
        ]
        harness.viewModel.handleSystemDidWake()

        XCTAssertTrue(harness.viewModel.outputDevices.contains { $0.id == "airpods" })
        XCTAssertEqual(harness.viewModel.selectedOutputDeviceName, "airpods")
    }

    func testSystemDidWakeRefreshesSystemOutputVolume() async {
        let reader = FakeLiveControlSystemVolumeReader(volumeScalar: 0.5)
        let harness = makeHarness(systemVolumeReader: reader)

        reader.volumeScalar = 0.9
        harness.viewModel.handleSystemDidWake()

        XCTAssertEqual(harness.viewModel.systemVolume, 90, accuracy: 0.5)
    }

    func testSystemDidWakeRefreshesVisibleAppList() async {
        let harness = makeHarness()

        harness.appLister.apps = makeLiveControlApps().filter { $0.id != "youtube" }
        harness.viewModel.handleSystemDidWake()

        XCTAssertFalse(harness.viewModel.apps.contains { $0.id == "youtube" })
        XCTAssertTrue(harness.viewModel.apps.contains { $0.id == "spotify" })
    }

    func testSystemSleepThenWakeDoesNotRestoreProductBannerOrSession() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 1)

        harness.viewModel.handleSystemWillSleep()
        harness.viewModel.handleSystemDidWake()

        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 0)
        // No new start was issued by wake (only the single pre-sleep start exists).
        XCTAssertEqual(harness.liveController.startedSessionIDs.count, 1)
    }

    func testSystemDidWakeInvalidatesHelperCacheForRemovedAppViaRefresh() async {
        let resolver = FakeAppAudioTargetResolver()
        let harness = makeHarness(appAudioTargetResolver: resolver)

        harness.appLister.apps = makeLiveControlApps().filter { $0.id != "youtube" }
        harness.viewModel.handleSystemDidWake()

        XCTAssertTrue(resolver.invalidatedRequests.map(\.appID).contains("youtube"))
    }

    func testSystemDidWakeWithOutputDeviceChangeIsIdempotentAndQuiet() async {
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true)
        ])
        let resolver = FakeAppAudioTargetResolver()
        let harness = makeHarness(outputDeviceLister: outputDeviceLister, appAudioTargetResolver: resolver)

        // Output device changed during sleep; nothing is active at wake.
        outputDeviceLister.devices = [
            makeLiveControlOutputDevice(id: "built-in"),
            makeLiveControlOutputDevice(id: "airpods", isDefault: true)
        ]
        harness.viewModel.handleSystemDidWake()

        // No teardown of running work (nothing was running) and no user-facing warning.
        XCTAssertTrue(harness.liveController.stopReasons.isEmpty)
        XCTAssertNil(harness.viewModel.statusMessage)
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)

        // Repeating wake stays safe.
        harness.viewModel.handleSystemDidWake()
        XCTAssertTrue(harness.liveController.stopReasons.isEmpty)
        XCTAssertNil(harness.viewModel.statusMessage)
    }

    func testRepeatedSystemDidWakeIsSafe() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.handleSystemDidWake()
        harness.viewModel.handleSystemDidWake()
        harness.viewModel.handleSystemDidWake()

        XCTAssertTrue(harness.liveController.startedTargets.isEmpty)
        XCTAssertTrue(harness.viewModel.isExperimentalRealAppControlEnabled)
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
    }

    func testUserCanStartNewProductSessionAfterSystemDidWake() async {
        let harness = makeHarness()
        harness.viewModel.handleSystemDidWake()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertEqual(harness.liveController.startedTargets.map(\.appID), ["spotify"])
    }

    func testSystemSleepThenWakeThenTerminationIsSafe() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { harness.liveController.startedSessionIDs.count == 1 && !harness.viewModel.isProcessTapTesting }

        harness.viewModel.handleSystemWillSleep()
        harness.viewModel.handleSystemDidWake()
        harness.viewModel.stopProcessTapLiveControlForTermination()

        XCTAssertEqual(harness.viewModel.confirmedProductRealControlSessionCount, 0)
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.realControlBannerPresentation)
        XCTAssertTrue(harness.liveController.stopReasons.contains(.systemSleep))
        XCTAssertTrue(harness.liveController.stopReasons.contains(.appTerminating))
    }

    // MARK: - Test fake concurrency (regression for the FakeLiveControlController data race)
    //
    // Drives many concurrent startSession/stopSession calls directly against the fake — the same
    // off-actor concurrent access to its `sessionOnStopped` dictionary that previously corrupted
    // the heap and crashed. With the fake's single lock the bookkeeping stays consistent. Uses
    // real task-group concurrency (no sleeps); deterministic post-fix (always passes), where the
    // pre-fix fake would intermittently crash.
    func testFakeControllerConcurrentStartStopBookkeepingIsRaceFree() async {
        let controller = FakeLiveControlController()
        let sessionCount = 64

        let startedIDs = await withTaskGroup(of: ProcessTapLiveSessionID?.self) { group in
            for index in 0..<sessionCount {
                group.addTask {
                    let result = await controller.startSession(
                        for: ProcessTapTarget(appID: "app\(index)", appName: "App \(index)", processIdentifier: Int32(1000 + index)),
                        gain: .defaultOption,
                        onDiagnostics: { _, _ in },
                        onStopped: { _, _, _ in }
                    )
                    return result.sessionID
                }
            }

            var ids: [ProcessTapLiveSessionID] = []
            for await id in group {
                if let id {
                    ids.append(id)
                }
            }
            return ids
        }

        XCTAssertEqual(startedIDs.count, sessionCount)
        XCTAssertEqual(controller.startedSessionIDs.count, sessionCount)
        XCTAssertEqual(Set(startedIDs).count, sessionCount)

        await withTaskGroup(of: Void.self) { group in
            for id in startedIDs {
                group.addTask {
                    _ = await controller.stopSession(id: id, reason: .userStopped)
                }
            }
            for await _ in group {}
        }

        XCTAssertEqual(controller.stopReasons.count, sessionCount)
        XCTAssertTrue(controller.stopReasons.allSatisfy { $0 == .userStopped })
    }

    /// Builds a view model around an arbitrary live-session manager — e.g. a real
    /// `ProcessTapLiveSessionManager` with fake per-session controllers — using the same fakes,
    /// no-op settle sleeper, and all-eligible PID policy as `makeHarness`.
    private func makeViewModel(
        apps: [MixerAppItem],
        liveController: ProcessTapLiveControlling & ProcessTapLiveSessionManaging
    ) -> MixerViewModel {
        MixerViewModel(
            applicationLister: FakeLiveControlApplicationLister(apps: apps),
            audioController: FakeLiveControlAudioController(),
            outputDeviceLister: FakeLiveControlOutputDeviceLister(),
            outputDeviceController: FakeLiveControlOutputDeviceController(),
            systemVolumeReader: FakeLiveControlSystemVolumeReader(volumeScalar: 0.5),
            systemVolumeController: FakeLiveControlSystemVolumeController(),
            processTapTester: FakeLiveControlProcessTapTester(),
            processTapReplayProbe: FakeLiveControlReplayProbe(),
            processTapLiveController: liveController,
            twoAppReadinessTester: FakeLiveControlTwoAppReadinessTester(),
            helperProcessAudioProbe: FakeLiveControlCandidateAudioProbe(),
            appAudioTargetResolver: FakeAppAudioTargetResolver(),
            processLister: FakeLiveControlProcessLister(),
            productRealStartSettleGate: ProductRealStartSettleGate(sleeper: { _ in }),
            processTapEligibility: { processIdentifier in
                guard processIdentifier != nil else {
                    return .unavailable("Core Audio process unavailable")
                }

                return .eligible
            }
        )
    }

    private func makeControlledHarness(
        liveController: FakeControlledLiveController,
        outputDeviceLister: FakeLiveControlOutputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true)
        ]),
        appAudioTargetResolver: FakeAppAudioTargetResolver = FakeAppAudioTargetResolver(),
        productRealStartSettleGate: ProductRealStartSettling = ProductRealStartSettleGate(sleeper: { _ in }),
        eligibilityByPID: [Int32: ProcessTapProcessEligibility] = [:]
    ) -> ControlledHarness {
        let appLister = FakeLiveControlApplicationLister(apps: makeLiveControlApps())
        let viewModel = MixerViewModel(
            applicationLister: appLister,
            audioController: FakeLiveControlAudioController(),
            outputDeviceLister: outputDeviceLister,
            outputDeviceController: FakeLiveControlOutputDeviceController(),
            systemVolumeReader: FakeLiveControlSystemVolumeReader(volumeScalar: 0.5),
            systemVolumeController: FakeLiveControlSystemVolumeController(),
            processTapTester: FakeLiveControlProcessTapTester(),
            processTapReplayProbe: FakeLiveControlReplayProbe(),
            processTapLiveController: liveController,
            twoAppReadinessTester: FakeLiveControlTwoAppReadinessTester(),
            helperProcessAudioProbe: FakeLiveControlCandidateAudioProbe(),
            appAudioTargetResolver: appAudioTargetResolver,
            processLister: FakeLiveControlProcessLister(),
            productRealStartSettleGate: productRealStartSettleGate,
            processTapEligibility: { processIdentifier in
                guard let processIdentifier else {
                    return .unavailable("Core Audio process unavailable")
                }

                return eligibilityByPID[processIdentifier] ?? .eligible
            }
        )

        return ControlledHarness(
            viewModel: viewModel,
            appLister: appLister,
            liveController: liveController,
            outputDeviceLister: outputDeviceLister,
            appAudioTargetResolver: appAudioTargetResolver
        )
    }
}

private struct LiveControlHarness {
    let viewModel: MixerViewModel
    let appLister: FakeLiveControlApplicationLister
    let audioController: FakeLiveControlAudioController
    let outputDeviceLister: FakeLiveControlOutputDeviceLister
    let liveController: FakeLiveControlController
    let appAudioTargetResolver: FakeAppAudioTargetResolver
    let twoAppReadinessTester: FakeLiveControlTwoAppReadinessTester
    let systemVolumeReader: FakeLiveControlSystemVolumeReader
}

private struct ControlledHarness {
    let viewModel: MixerViewModel
    let appLister: FakeLiveControlApplicationLister
    let liveController: FakeControlledLiveController
    let outputDeviceLister: FakeLiveControlOutputDeviceLister
    let appAudioTargetResolver: FakeAppAudioTargetResolver
}

/// Live controller fake whose Product `startSession` suspends until the test explicitly
/// completes it, so stale-start races can be exercised deterministically (no sleeps). Fully
/// thread-safe: `startSession` runs on the view model's background task while the test drives
/// completion from the main actor.
private final class FakeControlledLiveController: ProcessTapLiveControlling, ProcessTapLiveSessionManaging, @unchecked Sendable {
    private let lock = NSLock()

    private struct PendingStart {
        let sessionID: ProcessTapLiveSessionID
        let onDiagnostics: @Sendable (ProcessTapLiveSessionID, ProcessTapLiveDiagnostics) -> Void
        let continuation: CheckedContinuation<ProcessTapTestResult, Never>
    }

    private var pendingStarts: [PendingStart] = []
    private var sessionOnStopped: [ProcessTapLiveSessionID: @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void] = [:]
    private var startedTargetsStorage: [ProcessTapTarget] = []
    private var startedSessionIDsStorage: [ProcessTapLiveSessionID] = []
    private var startTimeoutPoliciesStorage: [ProcessTapLiveTimeoutPolicy] = []
    private var stoppedSessionIDsStorage: [ProcessTapLiveSessionID] = []
    private var stoppedReasonsStorage: [ProcessTapLiveStopReason] = []
    private var legacyManualStartCountStorage = 0

    var pendingStartCount: Int { lock.lock(); defer { lock.unlock() }; return pendingStarts.count }
    var startedTargets: [ProcessTapTarget] { lock.lock(); defer { lock.unlock() }; return startedTargetsStorage }
    /// Session ids handed back by `startSession`, in start order, so multi-session tests can
    /// address a specific session (e.g. emit an exit callback for app A while B stays active).
    var startedSessionIDs: [ProcessTapLiveSessionID] { lock.lock(); defer { lock.unlock() }; return startedSessionIDsStorage }
    var startTimeoutPolicies: [ProcessTapLiveTimeoutPolicy] { lock.lock(); defer { lock.unlock() }; return startTimeoutPoliciesStorage }
    var stoppedSessionIDs: [ProcessTapLiveSessionID] { lock.lock(); defer { lock.unlock() }; return stoppedSessionIDsStorage }
    var stoppedReasons: [ProcessTapLiveStopReason] { lock.lock(); defer { lock.unlock() }; return stoppedReasonsStorage }
    /// How many times the Advanced Manual Live path (`startLiveControl`) reached this controller.
    /// Lets a test assert a manual start was rejected upstream (never reached the engine).
    var legacyManualStartCount: Int { lock.lock(); defer { lock.unlock() }; return legacyManualStartCountStorage }

    /// Completes the oldest pending start with success or setup failure.
    func completeNextStart(success: Bool = true) {
        lock.lock()
        guard !pendingStarts.isEmpty else {
            lock.unlock()
            return
        }
        let pending = pendingStarts.removeFirst()
        lock.unlock()

        let result = success
            ? ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
            : ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        pending.continuation.resume(returning: result)
    }

    /// Fires the diagnostics callback for a still-pending start, to simulate a (possibly
    /// stale) diagnostics update arriving while the start is in flight.
    func emitDiagnosticsForPendingStart(at index: Int) {
        lock.lock()
        guard index < pendingStarts.count else {
            lock.unlock()
            return
        }
        let pending = pendingStarts[index]
        lock.unlock()
        pending.onDiagnostics(pending.sessionID, Self.makeDiagnostics())
    }

    /// Mirrors the engine delivering a per-session stopped callback (app/helper exit, output
    /// change) straight to the owning session's `onStopped`, without going through
    /// `stopSession`. This is how an autonomous teardown reaches the view model.
    ///
    /// Pass a distinct `reportedSessionID` to simulate an unknown/stale callback that no longer
    /// owns a live session: the reported id is forwarded but `handlerForSessionID`'s session is
    /// left registered, so the real session keeps running. The handler is resumed outside the
    /// lock.
    func emitSessionStopped(
        handlerForSessionID handlerID: ProcessTapLiveSessionID,
        reportedSessionID: ProcessTapLiveSessionID? = nil,
        outcome: ProcessTapTestResult.Outcome
    ) {
        lock.lock()
        let handler: (@Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void)?
        if reportedSessionID == nil {
            handler = sessionOnStopped.removeValue(forKey: handlerID)
        } else {
            handler = sessionOnStopped[handlerID]
        }
        lock.unlock()

        let reported = reportedSessionID ?? handlerID
        handler?(
            reported,
            ProcessTapTestResult(outcome: outcome, message: "Live control stopped", severity: .warning),
            nil
        )
    }

    // MARK: ProcessTapLiveSessionManaging

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
        let sessionID = ProcessTapLiveSessionID()
        lock.withLock {
            startedTargetsStorage.append(target)
            startedSessionIDsStorage.append(sessionID)
            startTimeoutPoliciesStorage.append(timeoutPolicy)
            sessionOnStopped[sessionID] = onStopped
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ProcessTapTestResult, Never>) in
            lock.withLock {
                pendingStarts.append(PendingStart(sessionID: sessionID, onDiagnostics: onDiagnostics, continuation: continuation))
            }
        }

        if result.outcome == .liveControlStarted {
            return ProcessTapLiveSessionStartResult(sessionID: sessionID, result: result)
        }

        lock.withLock {
            _ = sessionOnStopped.removeValue(forKey: sessionID)
        }
        return ProcessTapLiveSessionStartResult(sessionID: nil, result: result)
    }

    func stopSession(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        let handler = lock.withLock { () -> (@Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void)? in
            stoppedSessionIDsStorage.append(id)
            stoppedReasonsStorage.append(reason)
            return sessionOnStopped.removeValue(forKey: id)
        }

        handler?(id, ProcessTapTestResult(outcome: .liveControlStopped, message: "Live control stopped", severity: .info), nil)
        return ProcessTapTestResult(outcome: .liveControlNotActive, message: "Live control is not active", severity: .info)
    }

    func stopAll(reason: ProcessTapLiveStopReason) async -> [ProcessTapTestResult] {
        let ids = lock.withLock { Array(sessionOnStopped.keys) }

        var results: [ProcessTapTestResult] = []
        for id in ids {
            results.append(await stopSession(id: id, reason: reason))
        }
        return results
    }

    func updateGain(sessionID: ProcessTapLiveSessionID, gain: ProcessTapReplayGainOption) {}

    // MARK: ProcessTapLiveControlling (Advanced manual path — not exercised by these tests)

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        lock.withLock { legacyManualStartCountStorage += 1 }
        return ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
    }

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        ProcessTapTestResult(outcome: .liveControlNotActive, message: "Live control is not active", severity: .info)
    }

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption) {}

    @discardableResult
    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult? {
        nil
    }

    private static func makeDiagnostics() -> ProcessTapLiveDiagnostics {
        ProcessTapLiveDiagnostics(
            selectedGain: .defaultOption,
            callbackCount: 10,
            peakLevel: 0.2,
            rmsLevel: 0.05,
            enqueuedBufferCount: 10,
            droppedBufferCount: 0,
            enqueueFailureCount: 0,
            copyFailureCount: 0
        )
    }
}

private func makeLiveControlApps() -> [MixerAppItem] {
    [
        MixerAppItem(id: "spotify", name: "Spotify", icon: .systemSymbol("music.note"), processIdentifier: 101, volume: 50),
        MixerAppItem(id: "music", name: "Music", icon: .systemSymbol("music.quarternote.3"), processIdentifier: 102, volume: 50),
        MixerAppItem(id: "youtube", name: "YouTube", icon: .systemSymbol("play.rectangle"), processIdentifier: 200, volume: 50)
    ]
}

private func makeLiveControlOutputDevice(id: String, isDefault: Bool = false) -> OutputDeviceItem {
    OutputDeviceItem(
        id: id,
        name: id,
        iconSystemName: "speaker.wave.2.fill",
        isSystemDefault: isDefault
    )
}

private final class FakeLiveControlApplicationLister: ApplicationListing {
    var apps: [MixerAppItem]

    init(apps: [MixerAppItem]) {
        self.apps = apps
    }

    func listApplications() -> [MixerAppItem] {
        apps
    }
}

private final class FakeLiveControlAudioController: AudioControlling {
    private(set) var systemVolume: Double = 50
    private(set) var appVolumeRequests: [(volume: Double, appID: MixerAppItem.ID)] = []
    private(set) var appMutedRequests: [(isMuted: Bool, appID: MixerAppItem.ID)] = []

    func setSystemVolume(_ volume: Double) {
        systemVolume = volume
    }

    func setVolume(_ volume: Double, for appID: MixerAppItem.ID) {
        appVolumeRequests.append((volume, appID))
    }

    func setMuted(_ isMuted: Bool, for appID: MixerAppItem.ID) {
        appMutedRequests.append((isMuted, appID))
    }
}

/// Records gate interactions for Product Real start/stop wiring assertions. Optionally suspends
/// `waitForReadyToStart` on a releaser so a test can prove a start is held until the gate clears.
private final class SpyStartSettleGate: ProductRealStartSettling, @unchecked Sendable {
    private let lock = NSLock()
    private var registeredStops = 0
    private var waits = 0
    private let blockOn: TestAsyncReleaser?

    init(blockOn: TestAsyncReleaser? = nil) {
        self.blockOn = blockOn
    }

    var registeredStopCount: Int { lock.withLock { registeredStops } }
    var waitCount: Int { lock.withLock { waits } }

    func registerStop(_ stop: Task<Void, Never>) {
        lock.withLock { registeredStops += 1 }
    }

    func waitForReadyToStart() async {
        lock.withLock { waits += 1 }
        if let blockOn {
            await blockOn.wait()
        }
    }
}

private final class FakeLiveControlOutputDeviceLister: OutputDeviceListing {
    var devices: [OutputDeviceItem]

    init(devices: [OutputDeviceItem] = [makeLiveControlOutputDevice(id: "built-in", isDefault: true)]) {
        self.devices = devices
    }

    func listOutputDevices() -> [OutputDeviceItem] {
        devices
    }
}

private final class FakeLiveControlOutputDeviceController: OutputDeviceControlling {
    func setDefaultOutputDevice(_ device: OutputDeviceItem) -> Bool {
        true
    }
}

private final class FakeLiveControlSystemVolumeReader: SystemVolumeReading {
    var volumeScalar: Double?

    init(volumeScalar: Double?) {
        self.volumeScalar = volumeScalar
    }

    func readCurrentOutputVolumeScalar() -> Double? {
        volumeScalar
    }
}

private final class FakeLiveControlSystemVolumeController: SystemVolumeControlling {
    func setCurrentOutputVolumeScalar(_ volumeScalar: Double) -> Bool {
        true
    }
}

private final class FakeLiveControlProcessTapTester: ProcessTapTesting, @unchecked Sendable {
    func testProcessTap(
        for target: ProcessTapTarget,
        mode: ProcessTapTestMode,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult {
        ProcessTapTestResult(outcome: .streamDiagnosticsNoAudio, message: "No audio detected", severity: .info)
    }
}

private final class FakeLiveControlReplayProbe: ProcessTapReplayProbing, @unchecked Sendable {
    private let waitForStopBeforeReturning: Bool
    var onReplayStarted: (@Sendable () -> Void)?
    private var pendingContinuation: CheckedContinuation<ProcessTapReplayResult, Never>?
    private let lock = NSLock()
    private(set) var stopReasons: [ProcessTapReplayProbeStopReason] = []

    init(waitForStopBeforeReturning: Bool = false) {
        self.waitForStopBeforeReturning = waitForStopBeforeReturning
    }

    func runReplayProbe(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapReplayResult {
        guard waitForStopBeforeReturning else {
            return ProcessTapReplayResult(outcome: .replayCompleted, message: "Replay probe completed", severity: .info)
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            pendingContinuation = continuation
            let onReplayStarted = onReplayStarted
            lock.unlock()
            onReplayStarted?()
        }
    }

    func stopCurrentReplayProbe(reason: ProcessTapReplayProbeStopReason) {
        lock.lock()
        stopReasons.append(reason)
        let continuation = pendingContinuation
        pendingContinuation = nil
        lock.unlock()
        continuation?.resume(
            returning: ProcessTapReplayResult(outcome: .stopped, message: "Replay probe stopped", severity: .warning)
        )
    }
}

private final class FakeLiveControlController: ProcessTapLiveControlling, ProcessTapLiveSessionManaging, @unchecked Sendable {
    // Single synchronization policy: every read and write of the mutable state below goes through
    // `lock` (via `withLock`). The async session methods run off the main actor (the view model
    // `await`s a non-isolated fake), so two starts/stops can execute in parallel; without the lock
    // their concurrent mutation of `sessionOnStopped` corrupted the dictionary. Continuations and
    // onStopped/onDiagnostics callbacks are always invoked OUTSIDE the lock — values are extracted
    // under the lock first, then resumed/called after it is released (no recursive locking).
    private let lock = NSLock()
    private var startResults: [ProcessTapTestResult]
    private var startedTargetsStorage: [ProcessTapTarget] = []
    private var startGainsStorage: [ProcessTapReplayGainOption] = []
    private var startTimeoutPoliciesStorage: [ProcessTapLiveTimeoutPolicy] = []
    private var gainUpdatesStorage: [ProcessTapReplayGainOption] = []
    private var stopReasonsStorage: [ProcessTapLiveStopReason] = []
    private var startedSessionIDsStorage: [ProcessTapLiveSessionID] = []
    private var sessionGainUpdatesStorage: [(id: ProcessTapLiveSessionID, gain: ProcessTapReplayGainOption)] = []
    private var onStopped: (@Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void)?
    private var sessionOnStopped: [ProcessTapLiveSessionID: @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void] = [:]
    private let waitForStartCompletion: Bool
    private var pendingStartContinuations: [CheckedContinuation<ProcessTapTestResult, Never>] = []

    var startedTargets: [ProcessTapTarget] { lock.withLock { startedTargetsStorage } }
    var startGains: [ProcessTapReplayGainOption] { lock.withLock { startGainsStorage } }
    var startTimeoutPolicies: [ProcessTapLiveTimeoutPolicy] { lock.withLock { startTimeoutPoliciesStorage } }
    var gainUpdates: [ProcessTapReplayGainOption] { lock.withLock { gainUpdatesStorage } }
    var stopReasons: [ProcessTapLiveStopReason] { lock.withLock { stopReasonsStorage } }
    var startedSessionIDs: [ProcessTapLiveSessionID] { lock.withLock { startedSessionIDsStorage } }
    var sessionGainUpdates: [(id: ProcessTapLiveSessionID, gain: ProcessTapReplayGainOption)] { lock.withLock { sessionGainUpdatesStorage } }

    init(
        startResults: [ProcessTapTestResult] = [
            ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
        ],
        waitForStartCompletion: Bool = false
    ) {
        self.startResults = startResults
        self.waitForStartCompletion = waitForStartCompletion
    }

    /// Completes the oldest pending (suspended) Product start with `result`. Resumes outside
    /// the lock. When no start is pending yet, the result is queued for the next start.
    func completeNextStart(
        _ result: ProcessTapTestResult = ProcessTapTestResult(
            outcome: .liveControlStarted,
            message: "Live control started",
            severity: .info
        )
    ) {
        let continuation: CheckedContinuation<ProcessTapTestResult, Never>? = lock.withLock {
            guard !pendingStartContinuations.isEmpty else {
                startResults.append(result)
                return nil
            }
            return pendingStartContinuations.removeFirst()
        }
        continuation?.resume(returning: result)
    }

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        let result: ProcessTapTestResult = lock.withLock {
            startedTargetsStorage.append(target)
            startGainsStorage.append(gain)
            startTimeoutPoliciesStorage.append(timeoutPolicy)
            self.onStopped = onStopped
            guard !startResults.isEmpty else {
                return ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
            }
            return startResults.removeFirst()
        }
        onDiagnostics(makeLiveDiagnostics(gain: gain))
        return result
    }

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        let (handler, gain) = lock.withLock {
            stopReasonsStorage.append(reason)
            return (onStopped, startGainsStorage.last ?? .defaultOption)
        }
        let result = ProcessTapTestResult(outcome: .liveControlStopped, message: "Live control stopped", severity: .info)
        handler?(result, makeLiveDiagnostics(gain: gain))
        return ProcessTapTestResult(outcome: .liveControlNotActive, message: "Live control is not active", severity: .info)
    }

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption) {
        lock.withLock { gainUpdatesStorage.append(gain) }
    }

    @discardableResult
    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult? {
        lock.withLock { stopReasonsStorage.append(reason) }
        return ProcessTapTestResult(outcome: .liveControlStopped, message: "Live control stopped", severity: .info)
    }

    // MARK: ProcessTapLiveSessionManaging

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
        if waitForStartCompletion {
            // Deferred completion. Register the continuation BEFORE recording startedTargets so
            // that a test waiting on `startedTargets.count` is guaranteed the pending start is
            // already resumable by completeNextStart(_:) (avoids a count-visible-before-pending
            // race). An initial diagnostics callback is surfaced during the pending window.
            let sessionID = ProcessTapLiveSessionID()
            lock.withLock { sessionOnStopped[sessionID] = onStopped }
            let result = await withCheckedContinuation { continuation in
                lock.withLock {
                    pendingStartContinuations.append(continuation)
                    startedTargetsStorage.append(target)
                    startGainsStorage.append(gain)
                    startTimeoutPoliciesStorage.append(timeoutPolicy)
                }
                onDiagnostics(sessionID, makeLiveDiagnostics(gain: gain))
            }
            guard result.outcome == .liveControlStarted else {
                lock.withLock { sessionOnStopped[sessionID] = nil }
                return ProcessTapLiveSessionStartResult(sessionID: nil, result: result)
            }
            lock.withLock { startedSessionIDsStorage.append(sessionID) }
            return ProcessTapLiveSessionStartResult(sessionID: sessionID, result: result)
        }

        let started: (sessionID: ProcessTapLiveSessionID?, result: ProcessTapTestResult) = lock.withLock {
            startedTargetsStorage.append(target)
            startGainsStorage.append(gain)
            startTimeoutPoliciesStorage.append(timeoutPolicy)
            let result = startResults.isEmpty
                ? ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
                : startResults.removeFirst()
            guard result.outcome == .liveControlStarted else {
                return (nil, result)
            }
            let sessionID = ProcessTapLiveSessionID()
            startedSessionIDsStorage.append(sessionID)
            sessionOnStopped[sessionID] = onStopped
            return (sessionID, result)
        }
        guard let sessionID = started.sessionID else {
            return ProcessTapLiveSessionStartResult(sessionID: nil, result: started.result)
        }
        onDiagnostics(sessionID, makeLiveDiagnostics(gain: gain))
        return ProcessTapLiveSessionStartResult(sessionID: sessionID, result: started.result)
    }

    func stopSession(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        let (handler, gain) = lock.withLock {
            stopReasonsStorage.append(reason)
            return (sessionOnStopped.removeValue(forKey: id), startGainsStorage.last ?? .defaultOption)
        }
        let result = ProcessTapTestResult(outcome: .liveControlStopped, message: "Live control stopped", severity: .info)
        handler?(id, result, makeLiveDiagnostics(gain: gain))
        return ProcessTapTestResult(outcome: .liveControlNotActive, message: "Live control is not active", severity: .info)
    }

    func stopAll(reason: ProcessTapLiveStopReason) async -> [ProcessTapTestResult] {
        let ids = lock.withLock { Array(sessionOnStopped.keys) }
        var results: [ProcessTapTestResult] = []
        for id in ids {
            results.append(await stopSession(id: id, reason: reason))
        }
        return results
    }

    func updateGain(sessionID: ProcessTapLiveSessionID, gain: ProcessTapReplayGainOption) {
        lock.withLock {
            gainUpdatesStorage.append(gain)
            sessionGainUpdatesStorage.append((sessionID, gain))
        }
    }

    func emitStopped(_ result: ProcessTapTestResult) {
        let (legacyHandler, sessionHandlers, gain) = lock.withLock {
            let legacy = onStopped
            let handlers = sessionOnStopped
            sessionOnStopped.removeAll()
            return (legacy, handlers, startGainsStorage.last ?? .defaultOption)
        }
        legacyHandler?(result, makeLiveDiagnostics(gain: gain))
        for (id, handler) in sessionHandlers {
            handler(id, result, makeLiveDiagnostics(gain: gain))
        }
    }

    private func makeLiveDiagnostics(gain: ProcessTapReplayGainOption) -> ProcessTapLiveDiagnostics {
        ProcessTapLiveDiagnostics(
            selectedGain: gain,
            callbackCount: 10,
            peakLevel: 0.2,
            rmsLevel: 0.05,
            enqueuedBufferCount: 10,
            droppedBufferCount: 0,
            enqueueFailureCount: 0,
            copyFailureCount: 0
        )
    }
}

/// Vends a fresh `FakeLiveControlController` for every session a real `ProcessTapLiveSessionManager`
/// starts (the manager calls its factory once per `startSession`), and keeps them so a test can
/// assert per-session start/stop bookkeeping. Thread-safe: the manager calls `make()` off the main actor.
private final class PerSessionFakeLiveControllerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FakeLiveControlController] = []

    var controllers: [FakeLiveControlController] { lock.withLock { storage } }

    func make() -> ProcessTapLiveControlling {
        let controller = FakeLiveControlController()
        lock.withLock { storage.append(controller) }
        return controller
    }
}

private final class FakeAppAudioTargetResolver: AppAudioTargetResolving, @unchecked Sendable {
    private var results: [AppAudioTargetResolutionResult]
    private let suspendsWhenNoResultIsAvailable: Bool
    private var pendingContinuations: [CheckedContinuation<AppAudioTargetResolutionResult, Never>] = []
    private(set) var resolveRequests: [AppAudioTargetRequest] = []
    private(set) var allowsCachedLookupRequests: [Bool] = []
    private(set) var cancelledReasons: [ProcessTapCandidateProbeStopReason] = []
    private(set) var invalidatedRequests: [AppAudioTargetRequest] = []
    private(set) var invalidateAllCount = 0

    init(
        results: [AppAudioTargetResolutionResult] = [],
        suspendsWhenNoResultIsAvailable: Bool = false
    ) {
        self.results = results
        self.suspendsWhenNoResultIsAvailable = suspendsWhenNoResultIsAvailable
    }

    func resolveTarget(
        for request: AppAudioTargetRequest,
        allowsCachedLookup: Bool,
        onProgress: @escaping @Sendable (AppAudioResolutionProgress) -> Void
    ) async -> AppAudioTargetResolutionResult {
        resolveRequests.append(request)
        allowsCachedLookupRequests.append(allowsCachedLookup)
        guard !results.isEmpty else {
            if suspendsWhenNoResultIsAvailable {
                return await withCheckedContinuation { continuation in
                    pendingContinuations.append(continuation)
                }
            }

            return .unavailable("No active audio helper found")
        }

        return results.removeFirst()
    }

    func completeNext(_ result: AppAudioTargetResolutionResult) {
        guard !pendingContinuations.isEmpty else {
            results.append(result)
            return
        }

        pendingContinuations.removeFirst().resume(returning: result)
    }

    func cancelCurrentResolution(reason: ProcessTapCandidateProbeStopReason) {
        cancelledReasons.append(reason)
    }

    func invalidateCachedTarget(for request: AppAudioTargetRequest) {
        invalidatedRequests.append(request)
    }

    func invalidateAllCachedTargets() {
        invalidateAllCount += 1
    }
}

private final class FakeLiveControlCandidateAudioProbe: ProcessTapCandidateAudioProbing, @unchecked Sendable {
    private let lock = NSLock()
    private let waitForStopBeforeReturning: Bool
    var onProbeStarted: (@Sendable () -> Void)?
    private(set) var stopReasons: [ProcessTapCandidateProbeStopReason] = []
    private var pendingContinuation: CheckedContinuation<ProcessTapTestResult, Never>?

    init(waitForStopBeforeReturning: Bool = false) {
        self.waitForStopBeforeReturning = waitForStopBeforeReturning
    }

    func probeAudio(
        for target: ProcessTapTarget,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult {
        let progress = ProcessTapDiagnosticProgress(
            callbackCount: 4,
            peakLevel: 0.2,
            rmsLevel: 0.05,
            audioDetected: true
        )
        onProgress(progress)
        guard waitForStopBeforeReturning else {
            return ProcessTapTestResult(outcome: .helperProbeRunning, message: "Audio detected", severity: .info)
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            pendingContinuation = continuation
            let onProbeStarted = onProbeStarted
            lock.unlock()
            onProbeStarted?()
        }
    }

    func stopCurrentProbe(reason: ProcessTapCandidateProbeStopReason) {
        lock.lock()
        stopReasons.append(reason)
        let continuation = pendingContinuation
        pendingContinuation = nil
        lock.unlock()
        continuation?.resume(
            returning: ProcessTapTestResult(outcome: .helperProbeStopped, message: "Probe stopped", severity: .warning)
        )
    }
}

private final class FakeLiveControlTwoAppReadinessTester: ProcessTapTwoAppReadinessTesting, @unchecked Sendable {
    private let lock = NSLock()
    private var stopAllNowReasonsStorage: [ProcessTapLiveStopReason] = []
    /// Stop reasons forwarded to the synchronous `stopAllNow` path, so a test can assert system
    /// sleep tears the two-app test down with `.systemSleep`.
    var stopAllNowReasons: [ProcessTapLiveStopReason] { lock.lock(); defer { lock.unlock() }; return stopAllNowReasonsStorage }

    func startTest(
        appA: ProcessTapTarget,
        appB: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        duration: TimeInterval,
        onUpdate: @escaping @Sendable (ProcessTapTwoAppReadinessSnapshot) -> Void,
        onFinished: @escaping @Sendable (ProcessTapTwoAppReadinessResult, ProcessTapTwoAppReadinessSnapshot) -> Void
    ) async -> ProcessTapTwoAppReadinessResult {
        .idle
    }

    func stopAll(reason: ProcessTapLiveStopReason) async -> ProcessTapTwoAppReadinessResult {
        .idle
    }

    @discardableResult
    func stopAllNow(reason: ProcessTapLiveStopReason) -> ProcessTapTwoAppReadinessResult? {
        lock.lock()
        stopAllNowReasonsStorage.append(reason)
        lock.unlock()
        return .idle
    }
}

private final class FakeLiveControlProcessLister: ProcessListing, @unchecked Sendable {
    var processes: [SystemProcessInfo]

    init(processes: [SystemProcessInfo] = []) {
        self.processes = processes
    }

    func listProcesses() -> [SystemProcessInfo] {
        processes
    }
}

/// Pure unit tests for the Product Real rapid-toggle pending-operation state.
final class ProductRealControlStatePendingOperationTests: XCTestCase {
    func testNoPendingOperationsByDefault() {
        let state = ProductRealControlState()
        XCTAssertFalse(state.isOperationPending(for: "spotify"))
    }

    func testBeginAndEndOperationTogglePendingForThatAppOnly() {
        var state = ProductRealControlState()
        state.beginOperation(for: "spotify")

        XCTAssertTrue(state.isOperationPending(for: "spotify"))
        XCTAssertFalse(state.isOperationPending(for: "music"))

        state.endOperation(for: "spotify")
        XCTAssertFalse(state.isOperationPending(for: "spotify"))
    }

    func testEndOperationForOneAppLeavesOthersPending() {
        var state = ProductRealControlState()
        state.beginOperation(for: "spotify")
        state.beginOperation(for: "music")

        state.endOperation(for: "spotify")

        XCTAssertFalse(state.isOperationPending(for: "spotify"))
        XCTAssertTrue(state.isOperationPending(for: "music"))
    }

    func testClearAllOperationsClearsEveryPendingApp() {
        var state = ProductRealControlState()
        state.beginOperation(for: "spotify")
        state.beginOperation(for: "music")

        state.clearAllOperations()

        XCTAssertFalse(state.isOperationPending(for: "spotify"))
        XCTAssertFalse(state.isOperationPending(for: "music"))
    }
}
