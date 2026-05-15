import XCTest
@testable import MacMiniMixer

final class HelperAudioTargetResolverTests: XCTestCase {
    func testDirectVisiblePIDEligibleReturnsVisibleTargetWithoutHelperProbe() async {
        let lister = FakeProcessLister(processes: [])
        let probe = FakeCandidateAudioProbe()
        let eligibility = EligibilityStub(defaultEligibility: .unavailable("Core Audio process unavailable"))
        eligibility.set(.eligible, for: 100)
        let resolver = makeResolver(
            lister: lister,
            probe: probe,
            eligibility: eligibility,
            marksVisiblePIDUnavailable: false
        )

        let result = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }

        guard case let .resolved(target) = result else {
            return XCTFail("Expected direct visible target, got \(result)")
        }
        XCTAssertEqual(target.kind, .visibleApp)
        XCTAssertEqual(target.source, .directVisibleApp)
        XCTAssertEqual(target.visibleAppName, "YouTube")
        XCTAssertEqual(target.target.appName, "YouTube")
        XCTAssertEqual(target.target.processIdentifier, 100)
        XCTAssertTrue(probe.probedPIDs.isEmpty)
        XCTAssertEqual(lister.listCallCount, 0)
    }

    func testHelperCandidateWithStrongAudioReturnsHelperTargetAndPreservesVisibleName() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "YouTube"),
                makeProcess(pid: 201, parentPID: 100, name: "com.apple.WebKit.GPU")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        probe.setProgress(.strongAudio, for: 201)
        let resolver = makeResolver(lister: lister, probe: probe)

        let result = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }

        guard case let .resolved(target) = result else {
            return XCTFail("Expected helper target, got \(result)")
        }
        XCTAssertEqual(target.kind, .helper)
        XCTAssertEqual(target.source, .discoveredHelper)
        XCTAssertEqual(target.visibleAppName, "YouTube")
        XCTAssertEqual(target.target.appName, "YouTube")
        XCTAssertEqual(target.target.processIdentifier, 201)
        XCTAssertEqual(probe.probedPIDs, [201])
    }

    func testEarlyAcceptStopsAfterFirstStrongCandidate() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "YouTube"),
                makeProcess(pid: 201, parentPID: nil, name: "A com.apple.WebKit.GPU"),
                makeProcess(pid: 202, parentPID: nil, name: "B com.apple.WebKit.GPU")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        probe.setProgress(.strongAudio, for: 201)
        probe.setProgress(.strongerAudio, for: 202)
        let resolver = makeResolver(lister: lister, probe: probe)

        let result = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }

        guard case let .resolved(target) = result else {
            return XCTFail("Expected helper target, got \(result)")
        }
        XCTAssertEqual(target.target.processIdentifier, 201)
        XCTAssertEqual(probe.probedPIDs, [201])
    }

    func testWeakFirstCandidateContinuesAndReturnsStrongLaterCandidate() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "YouTube"),
                makeProcess(pid: 201, parentPID: nil, name: "A com.apple.WebKit.GPU"),
                makeProcess(pid: 202, parentPID: nil, name: "B com.apple.WebKit.GPU")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        probe.setProgress(.weakAudio, for: 201)
        probe.setProgress(.strongAudio, for: 202)
        let resolver = makeResolver(lister: lister, probe: probe)

        let result = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }

        guard case let .resolved(target) = result else {
            return XCTFail("Expected helper target, got \(result)")
        }
        XCTAssertEqual(target.target.processIdentifier, 202)
        XCTAssertEqual(probe.probedPIDs, [201, 202])
    }

    func testNoAudioHelperFoundReturnsUnavailableAndDoesNotCreateCacheEntry() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "YouTube"),
                makeProcess(pid: 201, parentPID: nil, name: "A com.apple.WebKit.GPU"),
                makeProcess(pid: 202, parentPID: nil, name: "B com.apple.WebKit.GPU")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        probe.setProgress(.silent, for: 201)
        probe.setProgress(.silent, for: 202)
        let resolver = makeResolver(lister: lister, probe: probe)

        let firstResult = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }
        let secondResult = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }

        guard case let .unavailable(firstReason) = firstResult,
              case let .unavailable(secondReason) = secondResult else {
            return XCTFail("Expected unavailable results, got \(firstResult) and \(secondResult)")
        }
        XCTAssertEqual(firstReason, "No active audio helper found")
        XCTAssertEqual(secondReason, "No active audio helper found")
        XCTAssertEqual(probe.probedPIDs, [201, 202, 201, 202])
    }

    func testCacheHitValidatesAndReusesHelperWithoutFreshProbe() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "YouTube"),
                makeProcess(pid: 201, parentPID: nil, name: "A com.apple.WebKit.GPU")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        probe.setProgress(.strongAudio, for: 201)
        let resolver = makeResolver(lister: lister, probe: probe)

        let firstResult = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }
        let secondResult = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }

        guard case let .resolved(firstTarget) = firstResult,
              case let .resolved(secondTarget) = secondResult else {
            return XCTFail("Expected resolved results, got \(firstResult) and \(secondResult)")
        }
        XCTAssertEqual(firstTarget.source, .discoveredHelper)
        XCTAssertEqual(secondTarget.source, .cachedHelper)
        XCTAssertEqual(secondTarget.target.processIdentifier, 201)
        XCTAssertEqual(probe.probedPIDs, [201])
    }

    func testInvalidCacheWhenHelperPIDNoLongerExistsFallsBackToFreshResolve() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "YouTube"),
                makeProcess(pid: 201, parentPID: nil, name: "A com.apple.WebKit.GPU")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        probe.setProgress(.strongAudio, for: 201)
        probe.setProgress(.strongAudio, for: 202)
        let resolver = makeResolver(lister: lister, probe: probe)

        _ = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }
        lister.processes = [
            makeProcess(pid: 100, parentPID: nil, name: "YouTube"),
            makeProcess(pid: 202, parentPID: nil, name: "A com.apple.WebKit.GPU")
        ]
        let secondResult = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }

        guard case let .resolved(target) = secondResult else {
            return XCTFail("Expected fallback helper target, got \(secondResult)")
        }
        XCTAssertEqual(target.source, .discoveredHelper)
        XCTAssertEqual(target.target.processIdentifier, 202)
        XCTAssertEqual(probe.probedPIDs, [201, 202])
    }

    func testInvalidCacheWhenHelperIsNoLongerEligibleFallsBackToFreshResolve() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "YouTube"),
                makeProcess(pid: 201, parentPID: nil, name: "A com.apple.WebKit.GPU")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        probe.setProgress(.strongAudio, for: 201)
        probe.setProgress(.strongAudio, for: 202)
        let eligibility = EligibilityStub(defaultEligibility: .eligible)
        eligibility.set(.unavailable("Core Audio process unavailable"), for: 100)
        let resolver = makeResolver(lister: lister, probe: probe, eligibility: eligibility)

        _ = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }
        eligibility.set(.unavailable("Core Audio process unavailable"), for: 201)
        lister.processes = [
            makeProcess(pid: 100, parentPID: nil, name: "YouTube"),
            makeProcess(pid: 201, parentPID: nil, name: "A com.apple.WebKit.GPU"),
            makeProcess(pid: 202, parentPID: nil, name: "B com.apple.WebKit.GPU")
        ]
        let secondResult = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }

        guard case let .resolved(target) = secondResult else {
            return XCTFail("Expected fallback helper target, got \(secondResult)")
        }
        XCTAssertEqual(target.source, .discoveredHelper)
        XCTAssertEqual(target.target.processIdentifier, 202)
        XCTAssertEqual(probe.probedPIDs, [201, 202])
    }

    func testInvalidateCachedTargetForcesFreshResolveForSameVisibleApp() async {
        let request = makeRequest(pid: 100)
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "YouTube"),
                makeProcess(pid: 201, parentPID: nil, name: "A com.apple.WebKit.GPU")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        probe.setProgress(.strongAudio, for: 201)
        let resolver = makeResolver(lister: lister, probe: probe)

        _ = await resolver.resolveTarget(for: request, allowsCachedLookup: true) { _ in }
        resolver.invalidateCachedTarget(for: request)
        let secondResult = await resolver.resolveTarget(for: request, allowsCachedLookup: true) { _ in }

        guard case let .resolved(target) = secondResult else {
            return XCTFail("Expected helper target after invalidation, got \(secondResult)")
        }
        XCTAssertEqual(target.source, .discoveredHelper)
        XCTAssertEqual(probe.probedPIDs, [201, 201])
    }

    func testInvalidateAllCachedTargetsForcesFreshResolve() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "YouTube"),
                makeProcess(pid: 201, parentPID: nil, name: "A com.apple.WebKit.GPU")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        probe.setProgress(.strongAudio, for: 201)
        let resolver = makeResolver(lister: lister, probe: probe)

        _ = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }
        resolver.invalidateAllCachedTargets()
        let secondResult = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }

        guard case let .resolved(target) = secondResult else {
            return XCTFail("Expected helper target after clearing cache, got \(secondResult)")
        }
        XCTAssertEqual(target.source, .discoveredHelper)
        XCTAssertEqual(probe.probedPIDs, [201, 201])
    }

    private func makeResolver(
        lister: FakeProcessLister,
        probe: FakeCandidateAudioProbe,
        eligibility: EligibilityStub = EligibilityStub(defaultEligibility: .eligible),
        marksVisiblePIDUnavailable: Bool = true
    ) -> HelperAudioTargetResolver {
        if marksVisiblePIDUnavailable {
            eligibility.set(.unavailable("Core Audio process unavailable"), for: 100)
        }
        return HelperAudioTargetResolver(
            processLister: lister,
            helperProcessAudioProbe: probe,
            processTapEligibility: { eligibility.eligibility(for: $0) }
        )
    }

    private func makeRequest(pid: Int32?) -> AppAudioTargetRequest {
        AppAudioTargetRequest(
            appID: "com.apple.Safari.WebApp.YouTube",
            appName: "YouTube",
            processIdentifier: pid
        )
    }

    private func makeProcess(
        pid: Int32,
        parentPID: Int32?,
        name: String
    ) -> SystemProcessInfo {
        SystemProcessInfo(
            processIdentifier: pid,
            parentProcessIdentifier: parentPID,
            name: name,
            executablePath: nil
        )
    }
}

private final class FakeProcessLister: ProcessListing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedProcesses: [SystemProcessInfo]
    private var storedListCallCount = 0

    init(processes: [SystemProcessInfo]) {
        storedProcesses = processes
    }

    var processes: [SystemProcessInfo] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedProcesses
        }
        set {
            lock.lock()
            storedProcesses = newValue
            lock.unlock()
        }
    }

    var listCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedListCallCount
    }

    func listProcesses() -> [SystemProcessInfo] {
        lock.lock()
        defer { lock.unlock() }
        storedListCallCount += 1
        return storedProcesses
    }
}

private final class FakeCandidateAudioProbe: ProcessTapCandidateAudioProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var progressByPID: [Int32: ProcessTapDiagnosticProgress] = [:]
    private var storedProbedPIDs: [Int32] = []
    private var stopReasons: [ProcessTapCandidateProbeStopReason] = []

    var probedPIDs: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return storedProbedPIDs
    }

    func setProgress(_ progress: ProcessTapDiagnosticProgress, for pid: Int32) {
        lock.lock()
        progressByPID[pid] = progress
        lock.unlock()
    }

    func probeAudio(
        for target: ProcessTapTarget,
        duration: TimeInterval,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult {
        let pid = target.processIdentifier ?? -1
        let progress = recordProbeAndReturnProgress(for: pid)

        onProgress(progress)
        return ProcessTapTestResult(
            outcome: progress.audioDetected ? .streamDiagnosticsDetectedAudio : .streamDiagnosticsNoAudio,
            message: progress.audioDetected ? "Audio detected" : "No audio detected",
            severity: .info
        )
    }

    func stopCurrentProbe(reason: ProcessTapCandidateProbeStopReason) {
        lock.lock()
        stopReasons.append(reason)
        lock.unlock()
    }

    private func recordProbeAndReturnProgress(for pid: Int32) -> ProcessTapDiagnosticProgress {
        lock.lock()
        defer { lock.unlock() }
        storedProbedPIDs.append(pid)
        return progressByPID[pid] ?? .silent
    }
}

private final class EligibilityStub: @unchecked Sendable {
    private let lock = NSLock()
    private let defaultEligibility: ProcessTapProcessEligibility
    private var eligibilityByPID: [Int32: ProcessTapProcessEligibility] = [:]

    init(defaultEligibility: ProcessTapProcessEligibility) {
        self.defaultEligibility = defaultEligibility
    }

    func set(_ eligibility: ProcessTapProcessEligibility, for pid: Int32) {
        lock.lock()
        eligibilityByPID[pid] = eligibility
        lock.unlock()
    }

    func eligibility(for processIdentifier: Int32?) -> ProcessTapProcessEligibility {
        guard let processIdentifier else {
            return .unavailable("Invalid process")
        }

        lock.lock()
        defer { lock.unlock() }
        return eligibilityByPID[processIdentifier] ?? defaultEligibility
    }
}

private extension ProcessTapDiagnosticProgress {
    static let silent = ProcessTapDiagnosticProgress(
        callbackCount: 10,
        peakLevel: 0,
        rmsLevel: 0,
        audioDetected: false
    )

    static let weakAudio = ProcessTapDiagnosticProgress(
        callbackCount: 12,
        peakLevel: 0.01,
        rmsLevel: 0.004,
        audioDetected: true
    )

    static let strongAudio = ProcessTapDiagnosticProgress(
        callbackCount: 20,
        peakLevel: 0.08,
        rmsLevel: 0.02,
        audioDetected: true
    )

    static let strongerAudio = ProcessTapDiagnosticProgress(
        callbackCount: 25,
        peakLevel: 0.2,
        rmsLevel: 0.05,
        audioDetected: true
    )
}
