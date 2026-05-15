import XCTest
@testable import MacMiniMixer

@MainActor
final class AdvancedHelperDiscoveryCoordinatorTests: XCTestCase {
    func testSelectAppClearsCandidateAndProbeState() async {
        let coordinator = makeCoordinator(
            apps: [makeApp(id: "safari", name: "Safari", pid: 100), makeApp(id: "chrome", name: "Chrome", pid: 200)],
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "Safari"),
                makeProcess(pid: 101, parentPID: 100, name: "com.apple.WebKit.GPU")
            ]
        )
        await coordinator.scanHelperProcessesNow(
            apps: [makeApp(id: "safari", name: "Safari", pid: 100), makeApp(id: "chrome", name: "Chrome", pid: 200)],
            isAutoDetectRunning: false,
            isAppAudioTargetResolving: false
        )
        await coordinator.probeHelperProcessCandidateNow(
            101,
            isAutoDetectRunning: false,
            isAppAudioTargetResolving: false
        )

        coordinator.selectApp(
            "chrome",
            apps: [makeApp(id: "safari", name: "Safari", pid: 100), makeApp(id: "chrome", name: "Chrome", pid: 200)],
            isAutoDetectRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertEqual(coordinator.selectedAppID, "chrome")
        XCTAssertTrue(coordinator.candidates.isEmpty)
        XCTAssertNil(coordinator.message)
        XCTAssertTrue(coordinator.probeResultsByPID.isEmpty)
        XCTAssertTrue(coordinator.probeProgressByPID.isEmpty)
    }

    func testScanWithFakeProcessListPopulatesCandidatesAndMessage() async {
        let apps = [makeApp(id: "safari", name: "Safari", pid: 100)]
        let coordinator = makeCoordinator(
            apps: apps,
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "Safari"),
                makeProcess(pid: 101, parentPID: 100, name: "com.apple.WebKit.GPU"),
                makeProcess(pid: 300, parentPID: nil, name: "TextEdit")
            ]
        )

        await coordinator.scanHelperProcessesNow(
            apps: apps,
            isAutoDetectRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertEqual(coordinator.candidates.map(\.process.processIdentifier), [100, 101])
        XCTAssertEqual(coordinator.candidates.map(\.relation), [.directApp, .child])
        XCTAssertEqual(coordinator.message, "2 tap-eligible candidates")
        XCTAssertFalse(coordinator.isScanning)
    }

    func testManualProbeSuccessUpdatesProgressAndResult() async {
        let apps = [makeApp(id: "safari", name: "Safari", pid: 100)]
        let probe = FakeHelperAudioProbe()
        probe.result = ProcessTapTestResult(
            outcome: .streamDiagnosticsDetectedAudio,
            message: "Audio detected",
            severity: .info
        )
        probe.progress = ProcessTapDiagnosticProgress(
            callbackCount: 12,
            peakLevel: 0.4,
            rmsLevel: 0.2,
            audioDetected: true
        )
        let coordinator = makeCoordinator(
            apps: apps,
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "Safari"),
                makeProcess(pid: 101, parentPID: 100, name: "com.apple.WebKit.GPU")
            ],
            probe: probe
        )
        await coordinator.scanHelperProcessesNow(
            apps: apps,
            isAutoDetectRunning: false,
            isAppAudioTargetResolving: false
        )

        await coordinator.probeHelperProcessCandidateNow(
            101,
            isAutoDetectRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertEqual(probe.probedTargets.map { $0.processIdentifier }, [101])
        XCTAssertEqual(coordinator.probeProgressByPID[101], probe.progress)
        XCTAssertEqual(coordinator.probeResultsByPID[101]?.outcome, .streamDiagnosticsDetectedAudio)
        XCTAssertNil(coordinator.runningProbePID)
    }

    func testManualProbeUnavailableCandidateSetsWarningWithoutCallingProbe() async {
        let apps = [makeApp(id: "safari", name: "Safari", pid: 100)]
        let probe = FakeHelperAudioProbe()
        let coordinator = makeCoordinator(
            apps: apps,
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "Safari"),
                makeProcess(pid: 101, parentPID: 100, name: "com.apple.WebKit.GPU")
            ],
            probe: probe,
            eligibility: { pid in
                pid == 101 ? .unavailable("Core Audio process unavailable") : .eligible
            }
        )
        await coordinator.scanHelperProcessesNow(
            apps: apps,
            isAutoDetectRunning: false,
            isAppAudioTargetResolving: false
        )

        await coordinator.probeHelperProcessCandidateNow(
            101,
            isAutoDetectRunning: false,
            isAppAudioTargetResolving: false
        )

        XCTAssertTrue(probe.probedTargets.isEmpty)
        XCTAssertEqual(coordinator.probeResultsByPID[101]?.outcome, .processNotFound)
        XCTAssertEqual(coordinator.probeResultsByPID[101]?.message, "Core Audio process unavailable")
    }

    func testStopProbeForwardsStopReasonWhenProbeIsMarkedRunning() {
        let probe = FakeHelperAudioProbe()
        let coordinator = makeCoordinator(
            apps: [makeApp(id: "safari", name: "Safari", pid: 100)],
            processes: [],
            probe: probe
        )

        coordinator.beginProbe(
            101,
            progress: ProcessTapDiagnosticProgress(callbackCount: 0, peakLevel: 0, rmsLevel: 0, audioDetected: false),
            result: ProcessTapTestResult(outcome: .helperProbeRunning, message: "Probing...", severity: .info)
        )
        coordinator.stopProbe(reason: .outputDeviceChanged)

        XCTAssertEqual(probe.stopReasons, [.outputDeviceChanged])
    }

    func testRefreshSelectionAfterSelectedAppDisappearsPicksFallbackAndClearsState() async {
        let originalApps = [
            makeApp(id: "safari", name: "Safari", pid: 100),
            makeApp(id: "chrome", name: "Chrome", pid: 200)
        ]
        let refreshedApps = [makeApp(id: "chrome", name: "Chrome", pid: 200)]
        let coordinator = makeCoordinator(
            apps: originalApps,
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "Safari"),
                makeProcess(pid: 101, parentPID: 100, name: "com.apple.WebKit.GPU")
            ]
        )
        await coordinator.scanHelperProcessesNow(
            apps: originalApps,
            isAutoDetectRunning: false,
            isAppAudioTargetResolving: false
        )

        coordinator.refreshSelectionAfterAppRefresh(apps: refreshedApps)

        XCTAssertEqual(coordinator.selectedAppID, "chrome")
        XCTAssertTrue(coordinator.candidates.isEmpty)
        XCTAssertNil(coordinator.message)
        XCTAssertTrue(coordinator.probeResultsByPID.isEmpty)
        XCTAssertTrue(coordinator.probeProgressByPID.isEmpty)
        XCTAssertNil(coordinator.runningProbePID)
    }

    private func makeCoordinator(
        apps: [MixerAppItem],
        processes: [SystemProcessInfo],
        probe: FakeHelperAudioProbe = FakeHelperAudioProbe(),
        eligibility: @escaping @Sendable (Int32) -> ProcessTapProcessEligibility = { _ in .eligible }
    ) -> AdvancedHelperDiscoveryCoordinator {
        AdvancedHelperDiscoveryCoordinator(
            processLister: FakeProcessLister(processes: processes),
            helperProcessAudioProbe: probe,
            initialApps: apps,
            processTapEligibility: eligibility
        )
    }

    private func makeApp(id: String, name: String, pid: Int32?) -> MixerAppItem {
        MixerAppItem(
            id: id,
            name: name,
            icon: .systemSymbol("app"),
            processIdentifier: pid,
            volume: 50
        )
    }

    private func makeProcess(
        pid: Int32,
        parentPID: Int32?,
        name: String,
        executablePath: String? = nil
    ) -> SystemProcessInfo {
        SystemProcessInfo(
            processIdentifier: pid,
            parentProcessIdentifier: parentPID,
            name: name,
            executablePath: executablePath
        )
    }
}

private final class FakeProcessLister: ProcessListing, @unchecked Sendable {
    let processes: [SystemProcessInfo]

    init(processes: [SystemProcessInfo]) {
        self.processes = processes
    }

    func listProcesses() -> [SystemProcessInfo] {
        processes
    }
}

private final class FakeHelperAudioProbe: ProcessTapCandidateAudioProbing, @unchecked Sendable {
    private let lock = NSLock()
    var progress = ProcessTapDiagnosticProgress(
        callbackCount: 1,
        peakLevel: 0.1,
        rmsLevel: 0.05,
        audioDetected: true
    )
    var result = ProcessTapTestResult(
        outcome: .streamDiagnosticsDetectedAudio,
        message: "Audio detected",
        severity: .info
    )
    private(set) var probedTargets: [ProcessTapTarget] = []
    private(set) var stopReasons: [ProcessTapCandidateProbeStopReason] = []

    func probeAudio(
        for target: ProcessTapTarget,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult {
        lock.lock()
        probedTargets.append(target)
        let progress = progress
        let result = result
        lock.unlock()

        onProgress(progress)
        return result
    }

    func stopCurrentProbe(reason: ProcessTapCandidateProbeStopReason) {
        lock.lock()
        stopReasons.append(reason)
        lock.unlock()
    }
}
