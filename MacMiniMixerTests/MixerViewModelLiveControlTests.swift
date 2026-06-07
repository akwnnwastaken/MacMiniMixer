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
        XCTAssertEqual(liveController.startedTargets.first?.appID, "music")
        XCTAssertEqual(liveController.startedTargets.first?.appName, "Music")
        XCTAssertEqual(liveController.startedTargets.first?.processIdentifier, 102)
        XCTAssertEqual(liveController.startTimeoutPolicies, [.indefinite])

        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        )
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }
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

    func testPendingHelperResolvedProductStartPreservesVisibleIdentityAndHidesHelperName() async {
        let resolver = FakeAppAudioTargetResolver(results: [
            .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: "youtube",
                    visibleAppName: "YouTube",
                    target: ProcessTapTarget(
                        appID: "helper:youtube:201",
                        appName: "com.apple.WebKit.GPU",
                        processIdentifier: 201
                    ),
                    kind: .helper,
                    source: .discoveredHelper
                )
            )
        ])
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(
            liveController: liveController,
            appAudioTargetResolver: resolver,
            eligibilityByPID: [
                200: .unavailable("Core Audio process unavailable"),
                201: .eligible
            ]
        )
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(35, for: "youtube")
        await waitFor { liveController.startedTargets.count == 1 }

        XCTAssertEqual(resolver.resolveRequests.map(\.appID), ["youtube"])
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "youtube")
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "YouTube")
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertFalse(harness.viewModel.isExperimentalControlActive(for: "youtube"))
        XCTAssertEqual(liveController.startedTargets.first?.processIdentifier, 201)
        XCTAssertEqual(liveController.startedTargets.first?.appName, "com.apple.WebKit.GPU")
        XCTAssertNotEqual(harness.viewModel.activeLiveControlAppName, "com.apple.WebKit.GPU")
        XCTAssertEqual(liveController.startTimeoutPolicies, [.indefinite])

        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        )
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }
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

    func testOutputDeviceChangeCancelsInFlightHelperResolutionAndIgnoresLateCompletion() async {
        let outputDeviceLister = FakeLiveControlOutputDeviceLister(devices: [
            makeLiveControlOutputDevice(id: "built-in", isDefault: true),
            makeLiveControlOutputDevice(id: "airpods")
        ])
        let resolver = FakeAppAudioTargetResolver(suspendsWhenNoResultIsAvailable: true)
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
        let harness = makeHarness(
            outputDeviceLister: outputDeviceLister,
            appAudioTargetResolver: resolver
        )

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
        helperProbe.onProbeStarted = {
            probeStarted.fulfill()
        }
        let processLister = FakeLiveControlProcessLister(processes: [
            SystemProcessInfo(processIdentifier: 200, parentProcessIdentifier: nil, name: "YouTube", executablePath: nil),
            SystemProcessInfo(processIdentifier: 201, parentProcessIdentifier: 200, name: "com.apple.WebKit.GPU", executablePath: nil)
        ])
        let harness = makeHarness(
            outputDeviceLister: outputDeviceLister,
            processLister: processLister,
            helperProcessAudioProbe: helperProbe,
            eligibilityByPID: [
                200: .eligible,
                201: .eligible
            ]
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
        replayProbe.onReplayStarted = {
            replayStarted.fulfill()
        }
        let harness = makeHarness(
            outputDeviceLister: outputDeviceLister,
            processTapReplayProbe: replayProbe
        )
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

    func testDirectVisiblePIDSetupFailureAfterOptimisticStateClearsStateAndAllowsRetry() async {
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(liveController: liveController)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "spotify")
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "Spotify")
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)

        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        )
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }

        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)

        harness.viewModel.setAppVolume(55, for: "spotify")
        await waitFor { liveController.startedTargets.count == 2 }
        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
        )
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }
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

    func testHelperResolvedSetupFailureAfterOptimisticStateInvalidatesMappingAndAllowsRetry() async {
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
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
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
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "youtube")
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "YouTube")
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)

        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        )
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }

        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["youtube"])
        XCTAssertFalse(harness.viewModel.isResolvingExperimentalControl(for: "youtube"))
        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)

        harness.viewModel.setAppVolume(60, for: "youtube")
        await waitFor { liveController.startedTargets.count == 2 }
        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
        )
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "youtube") }
        XCTAssertEqual(liveController.startedTargets.map(\.processIdentifier), [201, 202])
    }

    func testStopCallbackWhileProductStartIsPendingUsesOptimisticVisibleIdentity() async {
        let resolver = FakeAppAudioTargetResolver()
        let liveController = FakeLiveControlController(waitForStartCompletion: true)
        let harness = makeHarness(liveController: liveController, appAudioTargetResolver: resolver)
        harness.viewModel.setExperimentalRealAppControlEnabled(true)

        harness.viewModel.setAppVolume(50, for: "spotify")
        await waitFor { liveController.startedTargets.count == 1 }
        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "spotify")

        liveController.emitStopped(
            ProcessTapTestResult(outcome: .liveControlAppExited, message: "Live control stopped: process exited", severity: .warning)
        )
        await waitFor { harness.viewModel.activeExperimentalAppID == nil }

        XCTAssertFalse(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertNil(harness.viewModel.activeLiveControlAppName)
        XCTAssertEqual(resolver.invalidatedRequests.map(\.appID), ["spotify"])

        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlSetupFailed, message: "Could not start live control", severity: .warning)
        )
        await drainMainActor()
        XCTAssertNil(harness.viewModel.activeExperimentalAppID)
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

        liveController.completeNextStart(
            ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
        )
        await waitFor { harness.viewModel.isExperimentalControlActive(for: "spotify") }

        XCTAssertEqual(harness.viewModel.activeExperimentalAppID, "spotify")
        XCTAssertEqual(harness.viewModel.activeLiveControlAppName, "Spotify")
        XCTAssertTrue(harness.viewModel.isProcessTapLiveControlActive)
        XCTAssertEqual(liveController.startedTargets.map(\.processIdentifier), [101])
        XCTAssertEqual(liveController.startTimeoutPolicies, [.indefinite])
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
}

private struct LiveControlHarness {
    let viewModel: MixerViewModel
    let appLister: FakeLiveControlApplicationLister
    let audioController: FakeLiveControlAudioController
    let outputDeviceLister: FakeLiveControlOutputDeviceLister
    let liveController: FakeLiveControlController
    let appAudioTargetResolver: FakeAppAudioTargetResolver
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
            returning: ProcessTapReplayResult(
                outcome: .stopped,
                message: "Replay probe stopped",
                severity: .warning
            )
        )
    }
}

private final class FakeLiveControlController: ProcessTapLiveControlling, @unchecked Sendable {
    private var startResults: [ProcessTapTestResult]
    private let waitForStartCompletion: Bool
    private(set) var startedTargets: [ProcessTapTarget] = []
    private(set) var startGains: [ProcessTapReplayGainOption] = []
    private(set) var startTimeoutPolicies: [ProcessTapLiveTimeoutPolicy] = []
    private(set) var gainUpdates: [ProcessTapReplayGainOption] = []
    private(set) var stopReasons: [ProcessTapLiveStopReason] = []
    private var pendingStartContinuations: [CheckedContinuation<ProcessTapTestResult, Never>] = []
    private var onStopped: (@Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void)?

    init(startResults: [ProcessTapTestResult] = [
        ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
    ], waitForStartCompletion: Bool = false) {
        self.startResults = startResults
        self.waitForStartCompletion = waitForStartCompletion
    }

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
        if waitForStartCompletion {
            return await withCheckedContinuation { continuation in
                pendingStartContinuations.append(continuation)
            }
        }

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

    func emitStopped(_ result: ProcessTapTestResult) {
        onStopped?(result, makeLiveDiagnostics(gain: startGains.last ?? .defaultOption))
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
            returning: ProcessTapTestResult(
                outcome: .helperProbeStopped,
                message: "Probe stopped",
                severity: .warning
            )
        )
    }
}

private final class FakeLiveControlTwoAppReadinessTester: ProcessTapTwoAppReadinessTesting, @unchecked Sendable {
    func startTest(
        appA: ProcessTapTarget,
        appB: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
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
