import XCTest
@testable import MacMiniMixer

@MainActor
final class MixerViewModelTwoAppReadinessTests: XCTestCase {
    func testTargetsIncludeVisibleApps() {
        let harness = makeHarness()

        XCTAssertEqual(harness.viewModel.twoAppReadinessTargets.filter { !$0.isHelper }.map(\.id), [
            "spotify",
            "music",
            "youtube"
        ])
        XCTAssertEqual(harness.viewModel.selectedTwoAppReadinessAppAID, "spotify")
        XCTAssertEqual(harness.viewModel.selectedTwoAppReadinessAppBID, "music")
    }

    func testTargetsIncludeSelectedAdvancedHelperTargetWhenPresent() async {
        let harness = makeHarness(
            processLister: FakeTwoAppProcessLister(processes: makeHelperProcesses()),
            eligibilityByPID: [
                101: .eligible,
                102: .eligible,
                200: .eligible,
                201: .eligible
            ]
        )

        await selectAdvancedHelperTarget(pid: 201, in: harness)

        let helperTarget = harness.viewModel.twoAppReadinessTargets.first { $0.isHelper }
        XCTAssertEqual(helperTarget?.target.processIdentifier, 201)
        XCTAssertEqual(helperTarget?.title, "Helper: YouTube PID 201")
        XCTAssertNotNil(harness.viewModel.advancedProcessTapTarget)
    }

    func testSamePIDDuplicationIsRejectedBeforeServiceStart() {
        let harness = makeHarness(apps: [
            makeTwoApp(id: "spotify", name: "Spotify", pid: 101),
            makeTwoApp(id: "spotify-copy", name: "Spotify Copy", pid: 101)
        ])

        harness.viewModel.startTwoAppReadinessTest()

        XCTAssertTrue(harness.readinessTester.startRequests.isEmpty)
        XCTAssertEqual(harness.viewModel.twoAppReadinessResult?.outcome, .invalidTarget)
        XCTAssertEqual(harness.viewModel.twoAppReadinessResult?.message, "Choose two different process targets")
    }

    func testVisibleAppPlusVisibleAppStartPassesTargetsAndGain() async {
        let readinessTester = FakeTwoAppReadinessTester()
        let harness = makeHarness(readinessTester: readinessTester)
        let gain = ProcessTapReplayGainOption.options[0]

        harness.viewModel.selectTwoAppReadinessGain(gain)
        harness.viewModel.startTwoAppReadinessTest()
        await waitFor { readinessTester.startRequests.count == 1 }
        await waitFor { harness.viewModel.twoAppReadinessResult?.outcome == .running }

        let request = readinessTester.startRequests.first
        XCTAssertEqual(request?.appA.appID, "spotify")
        XCTAssertEqual(request?.appA.processIdentifier, 101)
        XCTAssertEqual(request?.appB.appID, "music")
        XCTAssertEqual(request?.appB.processIdentifier, 102)
        XCTAssertEqual(request?.gain, gain)
        XCTAssertTrue(harness.viewModel.isTwoAppReadinessRunning)
        XCTAssertEqual(harness.viewModel.twoAppReadinessResult?.outcome, .running)
    }

    func testVisibleAppPlusHelperTargetStartPassesHelperPID() async throws {
        let readinessTester = FakeTwoAppReadinessTester()
        let harness = makeHarness(
            readinessTester: readinessTester,
            processLister: FakeTwoAppProcessLister(processes: makeHelperProcesses()),
            eligibilityByPID: [
                101: .eligible,
                102: .eligible,
                200: .eligible,
                201: .eligible
            ]
        )
        await selectAdvancedHelperTarget(pid: 201, in: harness)
        let helperID = try XCTUnwrap(harness.viewModel.twoAppReadinessTargets.first { $0.isHelper }?.id)

        harness.viewModel.selectTwoAppReadinessAppA("spotify")
        harness.viewModel.selectTwoAppReadinessAppB(helperID)
        harness.viewModel.startTwoAppReadinessTest()
        await waitFor { readinessTester.startRequests.count == 1 }

        let request = readinessTester.startRequests.first
        XCTAssertEqual(request?.appA.appID, "spotify")
        XCTAssertEqual(request?.appA.processIdentifier, 101)
        XCTAssertEqual(request?.appB.processIdentifier, 201)
        XCTAssertEqual(request?.appB.appName, "Helper: YouTube PID 201")
    }

    func testStartIsBlockedWhenNoValidSecondSelectionExists() {
        let harness = makeHarness(apps: [
            makeTwoApp(id: "spotify", name: "Spotify", pid: 101)
        ])

        harness.viewModel.startTwoAppReadinessTest()

        XCTAssertTrue(harness.readinessTester.startRequests.isEmpty)
        XCTAssertEqual(harness.viewModel.twoAppReadinessResult?.outcome, .invalidTarget)
        XCTAssertEqual(harness.viewModel.twoAppReadinessResult?.message, "Select two targets")
    }

    func testStartIsBlockedWhileLiveControlIsActive() async {
        let liveController = FakeTwoAppLiveController()
        let readinessTester = FakeTwoAppReadinessTester()
        let harness = makeHarness(liveController: liveController, readinessTester: readinessTester)

        harness.viewModel.startProcessTapLiveControl()
        await waitFor { harness.viewModel.isProcessTapLiveControlActive }

        harness.viewModel.startTwoAppReadinessTest()

        XCTAssertTrue(readinessTester.startRequests.isEmpty)
        XCTAssertEqual(harness.viewModel.twoAppReadinessResult?.outcome, .setupFailed)
        XCTAssertEqual(harness.viewModel.twoAppReadinessResult?.message, "Stop active Process Tap work first")
    }

    func testStopAllForwardsUserStoppedReasonAndClearsRunningState() async {
        let readinessTester = FakeTwoAppReadinessTester()
        let harness = makeHarness(readinessTester: readinessTester)

        harness.viewModel.startTwoAppReadinessTest()
        await waitFor { harness.viewModel.isTwoAppReadinessRunning }
        await waitFor { harness.viewModel.twoAppReadinessResult?.outcome == .running }

        harness.viewModel.stopTwoAppReadinessTest()
        await waitFor { !readinessTester.stopReasons.isEmpty }
        await waitFor { !harness.viewModel.isTwoAppReadinessRunning }

        XCTAssertEqual(readinessTester.stopReasons, [.userStopped])
        XCTAssertEqual(harness.viewModel.twoAppReadinessResult?.outcome, .stopped)
    }

    func testFinishedCallbackClearsRunningStateAndUpdatesResultAndSnapshot() async {
        let readinessTester = FakeTwoAppReadinessTester()
        let harness = makeHarness(readinessTester: readinessTester)

        harness.viewModel.startTwoAppReadinessTest()
        await waitFor { harness.viewModel.isTwoAppReadinessRunning }
        await waitFor { readinessTester.startRequests.count == 1 }
        await waitFor { harness.viewModel.twoAppReadinessResult?.outcome == .running }

        readinessTester.emitFinished(
            result: ProcessTapTwoAppReadinessResult(
                outcome: .timedOut,
                message: "Two-app test timed out",
                severity: .warning
            )
        )
        await waitFor { !harness.viewModel.isTwoAppReadinessRunning }

        XCTAssertEqual(harness.viewModel.twoAppReadinessResult?.outcome, .timedOut)
        XCTAssertEqual(harness.viewModel.twoAppReadinessSnapshot.sessions.map(\.phase), [.stopped, .stopped])
    }

    func testOutputDeviceChangeStopsReadiness() async {
        let outputDeviceLister = FakeTwoAppOutputDeviceLister(devices: [
            makeTwoAppOutputDevice(id: "built-in", isDefault: true),
            makeTwoAppOutputDevice(id: "airpods")
        ])
        let readinessTester = FakeTwoAppReadinessTester()
        let harness = makeHarness(
            outputDeviceLister: outputDeviceLister,
            readinessTester: readinessTester
        )

        harness.viewModel.startTwoAppReadinessTest()
        await waitFor { harness.viewModel.isTwoAppReadinessRunning }

        outputDeviceLister.devices = [
            makeTwoAppOutputDevice(id: "built-in"),
            makeTwoAppOutputDevice(id: "airpods", isDefault: true)
        ]
        harness.viewModel.refreshOutputDevices()
        await waitFor { !readinessTester.stopReasons.isEmpty }

        XCTAssertEqual(readinessTester.stopReasons, [.outputDeviceChanged])
    }

    func testClearingSelectedAdvancedHelperTargetWhileRunningStopsSafely() async throws {
        let readinessTester = FakeTwoAppReadinessTester()
        let harness = makeHarness(
            readinessTester: readinessTester,
            processLister: FakeTwoAppProcessLister(processes: makeHelperProcesses()),
            eligibilityByPID: [
                101: .eligible,
                102: .eligible,
                200: .eligible,
                201: .eligible
            ]
        )
        await selectAdvancedHelperTarget(pid: 201, in: harness)
        let helperID = try XCTUnwrap(harness.viewModel.twoAppReadinessTargets.first { $0.isHelper }?.id)

        harness.viewModel.selectTwoAppReadinessAppA("spotify")
        harness.viewModel.selectTwoAppReadinessAppB(helperID)
        harness.viewModel.startTwoAppReadinessTest()
        await waitFor { harness.viewModel.isTwoAppReadinessRunning }

        harness.viewModel.clearAdvancedProcessTapTarget()
        await waitFor { !readinessTester.stopReasons.isEmpty }

        XCTAssertEqual(readinessTester.stopReasons, [.userStopped])
        XCTAssertNil(harness.viewModel.advancedProcessTapTarget)
    }

    func testSnapshotUpdateCallbackUpdatesVisibleState() async {
        let readinessTester = FakeTwoAppReadinessTester()
        let harness = makeHarness(readinessTester: readinessTester)

        harness.viewModel.startTwoAppReadinessTest()
        await waitFor { readinessTester.startRequests.count == 1 }
        await waitFor { harness.viewModel.twoAppReadinessSnapshot.sessions.map(\.phase) == [.active, .active] }

        XCTAssertEqual(harness.viewModel.twoAppReadinessSnapshot.sessions.map(\.appName), ["Spotify", "Music"])
        XCTAssertEqual(harness.viewModel.twoAppReadinessSnapshot.sessions.map(\.phase), [.active, .active])
    }

    private func makeHarness(
        apps: [MixerAppItem] = makeTwoAppReadinessApps(),
        outputDeviceLister: FakeTwoAppOutputDeviceLister = FakeTwoAppOutputDeviceLister(devices: [
            makeTwoAppOutputDevice(id: "built-in", isDefault: true)
        ]),
        liveController: FakeTwoAppLiveController = FakeTwoAppLiveController(),
        readinessTester: FakeTwoAppReadinessTester = FakeTwoAppReadinessTester(),
        processLister: FakeTwoAppProcessLister = FakeTwoAppProcessLister(),
        eligibilityByPID: [Int32: ProcessTapProcessEligibility] = [:]
    ) -> TwoAppHarness {
        let viewModel = MixerViewModel(
            applicationLister: FakeTwoAppApplicationLister(apps: apps),
            audioController: FakeTwoAppAudioController(),
            outputDeviceLister: outputDeviceLister,
            outputDeviceController: FakeTwoAppOutputDeviceController(),
            systemVolumeReader: FakeTwoAppSystemVolumeReader(),
            systemVolumeController: FakeTwoAppSystemVolumeController(),
            processTapTester: FakeTwoAppProcessTapTester(),
            processTapReplayProbe: FakeTwoAppReplayProbe(),
            processTapLiveController: liveController,
            twoAppReadinessTester: readinessTester,
            helperProcessAudioProbe: FakeTwoAppCandidateAudioProbe(),
            appAudioTargetResolver: FakeTwoAppAudioTargetResolver(),
            processLister: processLister,
            productRealStartSettleGate: ProductRealStartSettleGate(sleeper: { _ in }),
            processTapEligibility: { processIdentifier in
                guard let processIdentifier else {
                    return .unavailable("Core Audio process unavailable")
                }

                return eligibilityByPID[processIdentifier] ?? .eligible
            }
        )

        return TwoAppHarness(
            viewModel: viewModel,
            outputDeviceLister: outputDeviceLister,
            liveController: liveController,
            readinessTester: readinessTester
        )
    }

    private func selectAdvancedHelperTarget(pid: Int32, in harness: TwoAppHarness) async {
        harness.viewModel.selectHelperDiscoveryApp("youtube")
        harness.viewModel.scanHelperProcesses()
        await waitFor { !harness.viewModel.helperProcessCandidates.isEmpty }
        harness.viewModel.useHelperCandidateAsAdvancedTarget(pid)
        await waitFor { harness.viewModel.advancedProcessTapTarget != nil }
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

private struct TwoAppHarness {
    let viewModel: MixerViewModel
    let outputDeviceLister: FakeTwoAppOutputDeviceLister
    let liveController: FakeTwoAppLiveController
    let readinessTester: FakeTwoAppReadinessTester
}

private func makeTwoAppReadinessApps() -> [MixerAppItem] {
    [
        makeTwoApp(id: "spotify", name: "Spotify", pid: 101),
        makeTwoApp(id: "music", name: "Music", pid: 102),
        makeTwoApp(id: "youtube", name: "YouTube", pid: 200)
    ]
}

private func makeTwoApp(id: String, name: String, pid: Int32?) -> MixerAppItem {
    MixerAppItem(
        id: id,
        name: name,
        icon: .systemSymbol("music.note"),
        processIdentifier: pid,
        volume: 50
    )
}

private func makeHelperProcesses() -> [SystemProcessInfo] {
    [
        SystemProcessInfo(processIdentifier: 200, parentProcessIdentifier: nil, name: "YouTube", executablePath: nil),
        SystemProcessInfo(processIdentifier: 201, parentProcessIdentifier: 200, name: "com.apple.WebKit.GPU", executablePath: nil)
    ]
}

private func makeTwoAppOutputDevice(id: String, isDefault: Bool = false) -> OutputDeviceItem {
    OutputDeviceItem(
        id: id,
        name: id,
        iconSystemName: "speaker.wave.2.fill",
        isSystemDefault: isDefault
    )
}

private final class FakeTwoAppApplicationLister: ApplicationListing {
    var apps: [MixerAppItem]

    init(apps: [MixerAppItem]) {
        self.apps = apps
    }

    func listApplications() -> [MixerAppItem] {
        apps
    }
}

private final class FakeTwoAppAudioController: AudioControlling {
    var systemVolume: Double = 50

    func setSystemVolume(_ volume: Double) {}
    func setVolume(_ volume: Double, for appID: MixerAppItem.ID) {}
    func setMuted(_ isMuted: Bool, for appID: MixerAppItem.ID) {}
}

private final class FakeTwoAppOutputDeviceLister: OutputDeviceListing {
    var devices: [OutputDeviceItem]

    init(devices: [OutputDeviceItem]) {
        self.devices = devices
    }

    func listOutputDevices() -> [OutputDeviceItem] {
        devices
    }
}

private final class FakeTwoAppOutputDeviceController: OutputDeviceControlling {
    func setDefaultOutputDevice(_ device: OutputDeviceItem) -> Bool {
        true
    }
}

private final class FakeTwoAppSystemVolumeReader: SystemVolumeReading {
    func readCurrentOutputVolumeScalar() -> Double? {
        0.5
    }
}

private final class FakeTwoAppSystemVolumeController: SystemVolumeControlling {
    func setCurrentOutputVolumeScalar(_ volumeScalar: Double) -> Bool {
        true
    }
}

private final class FakeTwoAppProcessTapTester: ProcessTapTesting, @unchecked Sendable {
    func testProcessTap(
        for target: ProcessTapTarget,
        mode: ProcessTapTestMode,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult {
        ProcessTapTestResult(outcome: .streamDiagnosticsNoAudio, message: "No audio detected", severity: .info)
    }
}

private final class FakeTwoAppReplayProbe: ProcessTapReplayProbing, @unchecked Sendable {
    func runReplayProbe(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapReplayResult {
        ProcessTapReplayResult(outcome: .replayCompleted, message: "Replay probe completed", severity: .info)
    }

    func stopCurrentReplayProbe(reason: ProcessTapReplayProbeStopReason) {}
}

private final class FakeTwoAppLiveController: ProcessTapLiveControlling, ProcessTapLiveSessionManaging, @unchecked Sendable {
    private(set) var startedTargets: [ProcessTapTarget] = []
    private var onStopped: (@Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void)?
    private var sessionOnStopped: [ProcessTapLiveSessionID: @Sendable (ProcessTapLiveSessionID, ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void] = [:]

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        startedTargets.append(target)
        self.onStopped = onStopped
        onDiagnostics(makeTwoAppLiveDiagnostics(gain: gain))
        return ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
    }

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        onStopped?(
            ProcessTapTestResult(outcome: .liveControlStopped, message: "Live control stopped", severity: .info),
            nil
        )
        return ProcessTapTestResult(outcome: .liveControlNotActive, message: "Live control is not active", severity: .info)
    }

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption) {}

    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult? {
        ProcessTapTestResult(outcome: .liveControlStopped, message: "Live control stopped", severity: .info)
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
        startedTargets.append(target)
        let sessionID = ProcessTapLiveSessionID()
        sessionOnStopped[sessionID] = onStopped
        onDiagnostics(sessionID, makeTwoAppLiveDiagnostics(gain: gain))
        return ProcessTapLiveSessionStartResult(
            sessionID: sessionID,
            result: ProcessTapTestResult(outcome: .liveControlStarted, message: "Live control started", severity: .info)
        )
    }

    func stopSession(id: ProcessTapLiveSessionID, reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        sessionOnStopped.removeValue(forKey: id)?(
            id,
            ProcessTapTestResult(outcome: .liveControlStopped, message: "Live control stopped", severity: .info),
            nil
        )
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

    func updateGain(sessionID: ProcessTapLiveSessionID, gain: ProcessTapReplayGainOption) {}
}

private final class FakeTwoAppReadinessTester: ProcessTapTwoAppReadinessTesting, @unchecked Sendable {
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
            diagnostics: makeTwoAppLiveDiagnostics(gain: gain),
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

private final class FakeTwoAppCandidateAudioProbe: ProcessTapCandidateAudioProbing, @unchecked Sendable {
    func probeAudio(
        for target: ProcessTapTarget,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult {
        ProcessTapTestResult(outcome: .helperProbeRunning, message: "Audio detected", severity: .info)
    }

    func stopCurrentProbe(reason: ProcessTapCandidateProbeStopReason) {}
}

private final class FakeTwoAppAudioTargetResolver: AppAudioTargetResolving, @unchecked Sendable {
    func resolveTarget(
        for request: AppAudioTargetRequest,
        allowsCachedLookup: Bool,
        onProgress: @escaping @Sendable (AppAudioResolutionProgress) -> Void
    ) async -> AppAudioTargetResolutionResult {
        .unavailable("No active audio helper found")
    }

    func cancelCurrentResolution(reason: ProcessTapCandidateProbeStopReason) {}
    func invalidateCachedTarget(for request: AppAudioTargetRequest) {}
    func invalidateAllCachedTargets() {}
}

private final class FakeTwoAppProcessLister: ProcessListing, @unchecked Sendable {
    var processes: [SystemProcessInfo]

    init(processes: [SystemProcessInfo] = []) {
        self.processes = processes
    }

    func listProcesses() -> [SystemProcessInfo] {
        processes
    }
}

private func makeTwoAppLiveDiagnostics(gain: ProcessTapReplayGainOption) -> ProcessTapLiveDiagnostics {
    ProcessTapLiveDiagnostics(
        selectedGain: gain,
        callbackCount: 8,
        peakLevel: 0.2,
        rmsLevel: 0.05,
        enqueuedBufferCount: 8,
        droppedBufferCount: 0,
        enqueueFailureCount: 0,
        copyFailureCount: 0
    )
}
