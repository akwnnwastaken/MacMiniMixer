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

    func testOneActiveLiveSessionBlocksSecondProductAndManualStart() async {
        let harness = makeHarness()
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(40, for: "spotify")
        await waitFor { harness.liveController.startedTargets.count == 1 }

        harness.viewModel.setAppVolume(60, for: "music")
        harness.viewModel.startProcessTapLiveControl()
        await drainMainActor()

        XCTAssertEqual(harness.liveController.startedTargets.count, 1)
        XCTAssertEqual(harness.liveController.startedTargets.first?.appID, "spotify")
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
        let liveController = FakeLiveControlController(startResults: [
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning),
            ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
        ])
        let harness = makeHarness(liveController: liveController)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }

        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)
        XCTAssertEqual(harness.viewModel.statusMessage?.text, "Could not start live control for this app")

        harness.viewModel.setAppVolume(55, for: "spotify")
        await waitFor { liveController.startedTargets.count == 2 }
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

    func testThirdProductSessionBlockedByCap() async {
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

        harness.viewModel.setAppVolume(50, for: "youtube")
        await drainMainActor()

        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "youtube"))
        XCTAssertEqual(harness.viewModel.statusMessage?.text, "Real app control supports 2 apps at a time")
        XCTAssertEqual(harness.liveController.startedSessionIDs.count, 2)
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
        eligibilityByPID: [Int32: ProcessTapProcessEligibility] = [:]
    ) -> LiveControlHarness {
        let appLister = FakeLiveControlApplicationLister(apps: apps)
        let audioController = FakeLiveControlAudioController()
        let volumeReader = FakeLiveControlSystemVolumeReader(volumeScalar: 0.5)
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
            twoAppReadinessTester: FakeLiveControlTwoAppReadinessTester(),
            helperProcessAudioProbe: helperProcessAudioProbe,
            appAudioTargetResolver: appAudioTargetResolver,
            processLister: processLister,
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
            appAudioTargetResolver: appAudioTargetResolver
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

    // MARK: - Stale-start safety (controlled completion)

    func testStaleProductStartAfterGlobalToggleOffIsRejectedAndStopsOnlyStaleSession() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }

        harness.viewModel.setExperimentalRealAppControlEnabled(false)
        await drainMainActor()

        controller.completeNextStart(success: true)
        await drainMainActor()

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

        outputDeviceLister.devices = [makeLiveControlOutputDevice(id: "airpods", isDefault: true)]
        harness.viewModel.refreshOutputDevices()
        await drainMainActor()

        controller.completeNextStart(success: true)
        await drainMainActor()

        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertEqual(controller.stoppedSessionIDs.count, 1)
    }

    func testStaleStartForOneAppDoesNotDisturbAnotherActiveApp() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        // Music becomes a confirmed active session.
        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { controller.pendingStartCount == 1 }
        controller.completeNextStart(success: true)
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "music") }

        // Spotify starts, is cancelled per-app while pending, then completes late (stale).
        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }
        harness.viewModel.toggleExperimentalControl(for: "spotify")
        await drainMainActor()
        controller.completeNextStart(success: true)
        await drainMainActor()

        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
    }

    // Note: a same-app A1/A2 both-pending race is not reachable through the public API —
    // the isProcessTapTesting guard serialises Product starts, so a second start cannot begin
    // while the first is still in flight. The per-app token's same-app supersession is covered
    // by ProductRealControlStateTests.testNewStartRequestForSameAppSupersedesPrevious.

    func testStaleDiagnosticsAfterCancelledStartDoNotRepopulateState() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
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

    func testPerAppStopInvalidatesOnlyThatAppPendingStart() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { controller.pendingStartCount == 1 }
        controller.completeNextStart(success: true)
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "music") }

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }
        harness.viewModel.toggleExperimentalControl(for: "spotify")
        await drainMainActor()
        controller.completeNextStart(success: true)
        await drainMainActor()

        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "spotify"))
    }

    func testConcurrentStartLimitOfTwoPreservedWithControlledCompletion() async {
        let controller = FakeControlledLiveController()
        let harness = makeControlledHarness(liveController: controller)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { controller.pendingStartCount == 1 }
        controller.completeNextStart(success: true)
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        harness.viewModel.setAppVolume(50, for: "music")
        await waitFor { controller.pendingStartCount == 1 }
        controller.completeNextStart(success: true)
        // Music is the second app, so the global "live control active" flag is already true;
        // wait on the controlled completion draining instead of the (then-imprecise) per-app flag.
        await waitFor { controller.pendingStartCount == 0 }
        await drainMainActor()

        // Both still active and indefinite; a third app is rejected by the cap.
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "spotify"))
        XCTAssertTrue(harness.viewModel.isExperimentalControlActive(for: "music"))
        XCTAssertEqual(controller.startTimeoutPolicies, [.indefinite, .indefinite])

        harness.viewModel.setAppVolume(50, for: "youtube")
        await drainMainActor()
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "youtube"))
        XCTAssertEqual(harness.viewModel.statusMessage?.text, "Real app control supports 2 apps at a time")
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
        // API: the isProcessTapTesting guard serialises Product starts, so a second start cannot
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
        // Pin the Advanced diagnostic selection to a surviving app so removing youtube does not
        // also trip refreshProcessTapSelectionAfterAppRefresh's selection-driven global stop —
        // this test isolates the per-session app-exit teardown, not that orthogonal path.
        harness.viewModel.selectProcessTapApp("spotify")
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

    private func makeControlledHarness(
        liveController: FakeControlledLiveController,
        outputDeviceLister: FakeLiveControlOutputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true)
        ]),
        appAudioTargetResolver: FakeAppAudioTargetResolver = FakeAppAudioTargetResolver(),
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

    var pendingStartCount: Int { lock.lock(); defer { lock.unlock() }; return pendingStarts.count }
    var startedTargets: [ProcessTapTarget] { lock.lock(); defer { lock.unlock() }; return startedTargetsStorage }
    /// Session ids handed back by `startSession`, in start order, so multi-session tests can
    /// address a specific session (e.g. emit an exit callback for app A while B stays active).
    var startedSessionIDs: [ProcessTapLiveSessionID] { lock.lock(); defer { lock.unlock() }; return startedSessionIDsStorage }
    var startTimeoutPolicies: [ProcessTapLiveTimeoutPolicy] { lock.lock(); defer { lock.unlock() }; return startTimeoutPoliciesStorage }
    var stoppedSessionIDs: [ProcessTapLiveSessionID] { lock.lock(); defer { lock.unlock() }; return stoppedSessionIDsStorage }
    var stoppedReasons: [ProcessTapLiveStopReason] { lock.lock(); defer { lock.unlock() }; return stoppedReasonsStorage }

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
        lock.lock()
        startedTargetsStorage.append(target)
        startedSessionIDsStorage.append(sessionID)
        startTimeoutPoliciesStorage.append(timeoutPolicy)
        sessionOnStopped[sessionID] = onStopped
        lock.unlock()

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ProcessTapTestResult, Never>) in
            lock.lock()
            pendingStarts.append(PendingStart(sessionID: sessionID, onDiagnostics: onDiagnostics, continuation: continuation))
            lock.unlock()
        }

        if result.outcome == .liveControlStarted {
            return ProcessTapLiveSessionStartResult(sessionID: sessionID, result: result)
        }

        lock.lock()
        sessionOnStopped.removeValue(forKey: sessionID)
        lock.unlock()
        return ProcessTapLiveSessionStartResult(sessionID: nil, result: result)
    }

    func stopSession(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        lock.lock()
        stoppedSessionIDsStorage.append(id)
        stoppedReasonsStorage.append(reason)
        let handler = sessionOnStopped.removeValue(forKey: id)
        lock.unlock()

        handler?(id, ProcessTapTestResult(outcome: .liveControlStopped, message: "Live control stopped", severity: .info), nil)
        return ProcessTapTestResult(outcome: .liveControlNotActive, message: "Live control is not active", severity: .info)
    }

    func stopAll(reason: ProcessTapLiveStopReason) async -> [ProcessTapTestResult] {
        lock.lock()
        let ids = Array(sessionOnStopped.keys)
        lock.unlock()

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
        ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
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
    private var startResults: [ProcessTapTestResult]
    private(set) var startedTargets: [ProcessTapTarget] = []
    private(set) var startGains: [ProcessTapReplayGainOption] = []
    private(set) var startTimeoutPolicies: [ProcessTapLiveTimeoutPolicy] = []
    private(set) var gainUpdates: [ProcessTapReplayGainOption] = []
    private(set) var stopReasons: [ProcessTapLiveStopReason] = []
    private(set) var startedSessionIDs: [ProcessTapLiveSessionID] = []
    private(set) var sessionGainUpdates: [(id: ProcessTapLiveSessionID, gain: ProcessTapReplayGainOption)] = []
    private var onStopped: (@Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void)?
    private var sessionOnStopped: [ProcessTapLiveSessionID: @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void] = [:]
    private let waitForStartCompletion: Bool
    private var pendingStartContinuations: [CheckedContinuation<ProcessTapTestResult, Never>] = []

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
    /// any lock. When no start is pending yet, the result is queued for the next start.
    func completeNextStart(
        _ result: ProcessTapTestResult = ProcessTapTestResult(
            outcome: .liveControlStarted,
            message: "Live control started",
            severity: .info
        )
    ) {
        guard !pendingStartContinuations.isEmpty else {
            startResults.append(result)
            return
        }
        pendingStartContinuations.removeFirst().resume(returning: result)
    }

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        startedTargets.append(target)
        startGains.append(gain)
        startTimeoutPolicies.append(timeoutPolicy)
        self.onStopped = onStopped
        onDiagnostics(makeLiveDiagnostics(gain: gain))
        guard !startResults.isEmpty else {
            return ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
        }

        return startResults.removeFirst()
    }

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        stopReasons.append(reason)
        let result = ProcessTapTestResult(outcome: .liveControlStopped, message: "Live control stopped", severity: .info)
        onStopped?(result, makeLiveDiagnostics(gain: startGains.last ?? .defaultOption))
        return ProcessTapTestResult(outcome: .liveControlNotActive, message: "Live control is not active", severity: .info)
    }

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption) {
        gainUpdates.append(gain)
    }

    @discardableResult
    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult? {
        stopReasons.append(reason)
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
            sessionOnStopped[sessionID] = onStopped
            let result = await withCheckedContinuation { continuation in
                pendingStartContinuations.append(continuation)
                startedTargets.append(target)
                startGains.append(gain)
                startTimeoutPolicies.append(timeoutPolicy)
                onDiagnostics(sessionID, makeLiveDiagnostics(gain: gain))
            }
            guard result.outcome == .liveControlStarted else {
                sessionOnStopped[sessionID] = nil
                return ProcessTapLiveSessionStartResult(sessionID: nil, result: result)
            }
            startedSessionIDs.append(sessionID)
            return ProcessTapLiveSessionStartResult(sessionID: sessionID, result: result)
        }

        startedTargets.append(target)
        startGains.append(gain)
        startTimeoutPolicies.append(timeoutPolicy)
        let result = startResults.isEmpty
            ? ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
            : startResults.removeFirst()
        guard result.outcome == .liveControlStarted else {
            return ProcessTapLiveSessionStartResult(sessionID: nil, result: result)
        }
        let sessionID = ProcessTapLiveSessionID()
        startedSessionIDs.append(sessionID)
        sessionOnStopped[sessionID] = onStopped
        onDiagnostics(sessionID, makeLiveDiagnostics(gain: gain))
        return ProcessTapLiveSessionStartResult(sessionID: sessionID, result: result)
    }

    func stopSession(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        stopReasons.append(reason)
        let result = ProcessTapTestResult(outcome: .liveControlStopped, message: "Live control stopped", severity: .info)
        sessionOnStopped.removeValue(forKey: id)?(id, result, makeLiveDiagnostics(gain: startGains.last ?? .defaultOption))
        return ProcessTapTestResult(outcome: .liveControlNotActive, message: "Live control is not active", severity: .info)
    }

    func stopAll(reason: ProcessTapLiveStopReason) async -> [ProcessTapTestResult] {
        let ids = Array(sessionOnStopped.keys)
        var results: [ProcessTapTestResult] = []
        for id in ids {
            results.append(await stopSession(id: id, reason: reason))
        }
        return results
    }

    func updateGain(sessionID: ProcessTapLiveSessionID, gain: ProcessTapReplayGainOption) {
        gainUpdates.append(gain)
        sessionGainUpdates.append((sessionID, gain))
    }

    func emitStopped(_ result: ProcessTapTestResult) {
        onStopped?(result, makeLiveDiagnostics(gain: startGains.last ?? .defaultOption))
        for (id, handler) in sessionOnStopped {
            handler(id, result, makeLiveDiagnostics(gain: startGains.last ?? .defaultOption))
        }
        sessionOnStopped.removeAll()
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
        .idle
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
