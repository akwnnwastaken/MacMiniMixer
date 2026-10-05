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

    // MARK: - HAL process-object matching (runs before the visible-PID / probe paths)

    // Chrome: the visible main process is itself a Core Audio client (eligible), but its helper child
    // renders the audio. The match wins over the direct visible PID and covers both, with no probe.
    func testProcessObjectMatchWinsOverEligibleVisiblePIDAndIncludesHelper() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: 1, name: "Google Chrome"),
                makeProcess(pid: 300, parentPID: 100, name: "Google Chrome Helper")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        let objects = FakeAudioProcessObjectLister(objects: [
            makeObject(pid: 100, bundleID: "com.google.Chrome"),
            makeObject(pid: 300, bundleID: "com.google.Chrome.helper", running: true)
        ])
        let resolver = makeResolver(
            lister: lister,
            probe: probe,
            marksVisiblePIDUnavailable: false,
            processObjects: objects
        )

        let result = await resolver.resolveTarget(
            for: makeRequest(appID: "bundle:com.google.Chrome", name: "Google Chrome", pid: 100),
            allowsCachedLookup: true
        ) { _ in }

        guard case let .resolved(target) = result else {
            return XCTFail("Expected matched multi-process target, got \(result)")
        }
        XCTAssertEqual(target.kind, .audioProcessGroup)
        XCTAssertEqual(target.source, .matchedAudioProcesses)
        XCTAssertEqual(target.visibleAppID, "bundle:com.google.Chrome")
        XCTAssertEqual(
            target.target,
            ProcessTapTarget(
                appID: "bundle:com.google.Chrome",
                appName: "Google Chrome",
                processIdentifier: 100,
                additionalProcessIdentifiers: [300]
            )
        )
        XCTAssertTrue(probe.probedPIDs.isEmpty)
    }

    // Safari: the WebKit GPU process (parented to launchd) renders the audio; the visible Safari PID
    // is not a Core Audio client. Matched by the WebKit bundle prefix, resolved without probing.
    func testSafariResolvesToWebKitProcessesWithoutProbing() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: 1, name: "Safari"),
                makeProcess(pid: 500, parentPID: 1, name: "com.apple.WebKit.GPU")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        probe.setProgress(.strongAudio, for: 500)
        let objects = FakeAudioProcessObjectLister(objects: [
            makeObject(pid: 500, bundleID: "com.apple.WebKit.GPU", running: true),
            makeObject(pid: 700, bundleID: "com.spotify.client", running: true)
        ])
        let resolver = makeResolver(lister: lister, probe: probe, processObjects: objects)

        let result = await resolver.resolveTarget(
            for: makeRequest(appID: "bundle:com.apple.Safari", name: "Safari", pid: 100),
            allowsCachedLookup: true
        ) { _ in }

        guard case let .resolved(target) = result else {
            return XCTFail("Expected matched WebKit target, got \(result)")
        }
        XCTAssertEqual(target.source, .matchedAudioProcesses)
        XCTAssertEqual(target.target.processIdentifier, 100)
        XCTAssertEqual(target.target.additionalProcessIdentifiers, [500])
        XCTAssertTrue(probe.probedPIDs.isEmpty)
    }

    // A plain app whose only Core Audio process is its own visible process keeps the classic
    // direct-visible result (same single-process target as before).
    func testMatchOfVisibleProcessOnlyKeepsDirectVisibleSource() async {
        let lister = FakeProcessLister(processes: [])
        let probe = FakeCandidateAudioProbe()
        let objects = FakeAudioProcessObjectLister(objects: [
            makeObject(pid: 100, bundleID: "com.apple.Music", running: true)
        ])
        let resolver = makeResolver(
            lister: lister,
            probe: probe,
            marksVisiblePIDUnavailable: false,
            processObjects: objects
        )

        let result = await resolver.resolveTarget(
            for: makeRequest(appID: "bundle:com.apple.Music", name: "Music", pid: 100),
            allowsCachedLookup: true
        ) { _ in }

        guard case let .resolved(target) = result else {
            return XCTFail("Expected direct visible target, got \(result)")
        }
        XCTAssertEqual(target.kind, .visibleApp)
        XCTAssertEqual(target.source, .directVisibleApp)
        XCTAssertEqual(
            target.target,
            ProcessTapTarget(appID: "bundle:com.apple.Music", appName: "Music", processIdentifier: 100)
        )
        XCTAssertTrue(probe.probedPIDs.isEmpty)
    }

    // Discord-style Electron app: no browser keyword and the visible PID is not a Core Audio client,
    // but its `<bundle id>.helper…` process is. Previously rejected by the browser-keyword gate.
    func testNonBrowserMultiProcessAppResolvesThroughMatchedHelper() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: 1, name: "Discord"),
                makeProcess(pid: 301, parentPID: 100, name: "Discord Helper (Renderer)")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        let objects = FakeAudioProcessObjectLister(objects: [
            makeObject(pid: 301, bundleID: "com.hnc.Discord.helper.Renderer", running: true)
        ])
        let resolver = makeResolver(lister: lister, probe: probe, processObjects: objects)

        let result = await resolver.resolveTarget(
            for: makeRequest(appID: "bundle:com.hnc.Discord", name: "Discord", pid: 100),
            allowsCachedLookup: true
        ) { _ in }

        guard case let .resolved(target) = result else {
            return XCTFail("Expected matched Discord helper target, got \(result)")
        }
        XCTAssertEqual(target.source, .matchedAudioProcesses)
        XCTAssertEqual(target.target.processIdentifier, 100)
        XCTAssertEqual(target.target.additionalProcessIdentifiers, [301])
        XCTAssertTrue(probe.probedPIDs.isEmpty)
    }

    // No HAL object belongs to a non-browser app (it has not used audio yet): no probing, and the
    // user is told to start playing audio first.
    func testNonBrowserAppWithoutMatchedProcessAsksToPlayAudioFirst() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: 1, name: "Discord"),
                makeProcess(pid: 301, parentPID: 100, name: "Discord Helper")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        let objects = FakeAudioProcessObjectLister(objects: [
            makeObject(pid: 700, bundleID: "com.spotify.client", running: true)
        ])
        let resolver = makeResolver(lister: lister, probe: probe, processObjects: objects)

        let result = await resolver.resolveTarget(
            for: makeRequest(appID: "bundle:com.hnc.Discord", name: "Discord", pid: 100),
            allowsCachedLookup: true
        ) { _ in }

        XCTAssertEqual(result, .unavailable(AppAudioProcessMatcher.playAudioFirstMessage(appName: "Discord")))
        XCTAssertEqual(result, .unavailable("No audio from Discord yet. Start playing audio in it, then try again."))
        XCTAssertTrue(probe.probedPIDs.isEmpty)
    }

    // Nothing matched for a known browser row: the existing probe-based helper search still runs.
    func testBrowserWithoutMatchedProcessFallsBackToHelperProbe() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: nil, name: "YouTube"),
                makeProcess(pid: 201, parentPID: 100, name: "com.apple.WebKit.GPU")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        probe.setProgress(.strongAudio, for: 201)
        let objects = FakeAudioProcessObjectLister(objects: [
            makeObject(pid: 700, bundleID: "com.spotify.client", running: true)
        ])
        let resolver = makeResolver(lister: lister, probe: probe, processObjects: objects)

        let result = await resolver.resolveTarget(for: makeRequest(pid: 100), allowsCachedLookup: true) { _ in }

        guard case let .resolved(target) = result else {
            return XCTFail("Expected probed helper target, got \(result)")
        }
        XCTAssertEqual(target.source, .discoveredHelper)
        XCTAssertEqual(target.target.processIdentifier, 201)
        XCTAssertEqual(target.target.additionalProcessIdentifiers, [])
        XCTAssertEqual(probe.probedPIDs, [201])
    }

    // Multi-process matches are re-derived on every resolution (never served from the helper cache),
    // so a helper that went away is simply not included next time.
    func testMatchedTargetsAreRecomputedNotCached() async {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: 1, name: "Google Chrome"),
                makeProcess(pid: 300, parentPID: 100, name: "Google Chrome Helper"),
                makeProcess(pid: 301, parentPID: 100, name: "Google Chrome Helper")
            ]
        )
        let probe = FakeCandidateAudioProbe()
        let objects = FakeAudioProcessObjectLister(objects: [
            makeObject(pid: 300, bundleID: "com.google.Chrome.helper", running: true)
        ])
        let resolver = makeResolver(lister: lister, probe: probe, processObjects: objects)
        let request = makeRequest(appID: "bundle:com.google.Chrome", name: "Google Chrome", pid: 100)

        let first = await resolver.resolveTarget(for: request, allowsCachedLookup: true) { _ in }
        objects.objects = [makeObject(pid: 301, bundleID: "com.google.Chrome.helper", running: true)]
        let second = await resolver.resolveTarget(for: request, allowsCachedLookup: true) { _ in }

        guard case let .resolved(firstTarget) = first, case let .resolved(secondTarget) = second else {
            return XCTFail("Expected two matched targets, got \(first) and \(second)")
        }
        XCTAssertEqual(firstTarget.target.additionalProcessIdentifiers, [300])
        XCTAssertEqual(secondTarget.target.additionalProcessIdentifiers, [301])
        XCTAssertEqual(secondTarget.source, .matchedAudioProcesses)
        XCTAssertTrue(probe.probedPIDs.isEmpty)
    }

    func testMatchedAudioProcessIdentifiersUsesHALListAndExcludesOwnProcess() {
        let lister = FakeProcessLister(
            processes: [
                makeProcess(pid: 100, parentPID: 1, name: "Google Chrome"),
                makeProcess(pid: 300, parentPID: 100, name: "Google Chrome Helper"),
                makeProcess(pid: 400, parentPID: 100, name: "MacMiniMixer")
            ]
        )
        let objects = FakeAudioProcessObjectLister(objects: [
            makeObject(pid: 100, bundleID: "com.google.Chrome"),
            makeObject(pid: 300, bundleID: nil, running: true),
            makeObject(pid: 400, bundleID: "com.google.Chrome.helper", running: true),
            makeObject(pid: 700, bundleID: "com.spotify.client", running: true)
        ])
        let resolver = makeResolver(
            lister: lister,
            probe: FakeCandidateAudioProbe(),
            processObjects: objects,
            ownProcessIdentifier: 400
        )

        let matched = resolver.matchedAudioProcessIdentifiers(
            for: makeRequest(appID: "bundle:com.google.Chrome", name: "Google Chrome", pid: 100)
        )

        // Running output first (300), then the idle main process (100); own pid 400 and the unrelated
        // Spotify object are excluded.
        XCTAssertEqual(matched, [300, 100])
    }

    func testMatchedAudioProcessIdentifiersSkipsProcessListingWhenHALListIsEmpty() {
        let lister = FakeProcessLister(processes: [makeProcess(pid: 100, parentPID: 1, name: "Music")])
        let resolver = makeResolver(lister: lister, probe: FakeCandidateAudioProbe())

        let matched = resolver.matchedAudioProcessIdentifiers(
            for: makeRequest(appID: "bundle:com.apple.Music", name: "Music", pid: 100)
        )

        XCTAssertEqual(matched, [])
        XCTAssertEqual(lister.listCallCount, 0)
    }

    /// `processObjects` is the fake HAL process-object list. It defaults to empty so the existing
    /// probe/cache tests keep exercising the helper-probe path exactly as before (no real Core Audio).
    private func makeResolver(
        lister: FakeProcessLister,
        probe: FakeCandidateAudioProbe,
        eligibility: EligibilityStub = EligibilityStub(defaultEligibility: .eligible),
        marksVisiblePIDUnavailable: Bool = true,
        processObjects: FakeAudioProcessObjectLister = FakeAudioProcessObjectLister(objects: []),
        ownProcessIdentifier: Int32 = 99_999
    ) -> HelperAudioTargetResolver {
        if marksVisiblePIDUnavailable {
            eligibility.set(.unavailable("Core Audio process unavailable"), for: 100)
        }
        return HelperAudioTargetResolver(
            processLister: lister,
            helperProcessAudioProbe: probe,
            processTapEligibility: { eligibility.eligibility(for: $0) },
            audioProcessObjectLister: processObjects,
            ownProcessIdentifier: ownProcessIdentifier
        )
    }

    private func makeRequest(pid: Int32?) -> AppAudioTargetRequest {
        AppAudioTargetRequest(
            appID: "com.apple.Safari.WebApp.YouTube",
            appName: "YouTube",
            processIdentifier: pid
        )
    }

    private func makeRequest(appID: String, name: String, pid: Int32?) -> AppAudioTargetRequest {
        AppAudioTargetRequest(appID: appID, appName: name, processIdentifier: pid)
    }

    private func makeObject(pid: Int32, bundleID: String?, running: Bool = false) -> AudioProcessObjectInfo {
        AudioProcessObjectInfo(
            objectID: UInt32(1_000 + pid),
            processIdentifier: pid,
            bundleIdentifier: bundleID,
            isRunningOutput: running
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

/// Fake HAL process-object list (`kAudioHardwarePropertyProcessObjectList`) for the resolver.
private final class FakeAudioProcessObjectLister: AudioProcessObjectListing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedObjects: [AudioProcessObjectInfo]

    init(objects: [AudioProcessObjectInfo]) {
        storedObjects = objects
    }

    var objects: [AudioProcessObjectInfo] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedObjects
        }
        set {
            lock.lock()
            storedObjects = newValue
            lock.unlock()
        }
    }

    func listAudioProcessObjects() -> [AudioProcessObjectInfo] {
        objects
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

/// Pure tests for `AppAudioProcessMatcher` (no Core Audio, no process listing).
final class AppAudioProcessMatcherTests: XCTestCase {
    private let ownPID: Int32 = 9_999

    func testBundleIdentifierIsReadFromBundleRowIDsOnly() {
        XCTAssertEqual(AppAudioProcessMatcher.bundleIdentifier(forAppID: "bundle:com.google.Chrome"), "com.google.Chrome")
        XCTAssertNil(AppAudioProcessMatcher.bundleIdentifier(forAppID: "executable:/Applications/Foo.app/Contents/MacOS/Foo"))
        XCTAssertNil(AppAudioProcessMatcher.bundleIdentifier(forAppID: "pid:42"))
        XCTAssertNil(AppAudioProcessMatcher.bundleIdentifier(forAppID: "bundle:"))
        XCTAssertNil(AppAudioProcessMatcher.bundleIdentifier(forAppID: "spotify"))
    }

    func testMatchesExactVisiblePIDWithoutBundleID() {
        let matches = match(
            appID: "pid:100",
            pid: 100,
            objects: [object(100, nil), object(200, nil)]
        )

        XCTAssertEqual(matches, [100])
    }

    func testMatchesDescendantsThroughParentChain() {
        let matches = match(
            appID: "executable:/Applications/Firefox.app/Contents/MacOS/firefox",
            pid: 100,
            objects: [object(300, "org.mozilla.plugincontainer"), object(400, nil)],
            processes: [
                process(100, parent: 1),
                process(200, parent: 100),
                process(300, parent: 200),
                process(400, parent: 1)
            ]
        )

        XCTAssertEqual(matches, [300])
    }

    func testDescendantCheckIsCycleSafe() {
        let matches = match(
            appID: "pid:100",
            pid: 100,
            objects: [object(300, nil)],
            processes: [process(300, parent: 301), process(301, parent: 300)]
        )

        XCTAssertEqual(matches, [])
    }

    func testMatchesChromiumFamilyHelpersByBundlePrefix() {
        XCTAssertEqual(
            match(appID: "bundle:com.google.Chrome", pid: 100, objects: [object(300, "com.google.Chrome.helper")]),
            [300]
        )
        XCTAssertEqual(
            match(appID: "bundle:com.microsoft.edgemac", pid: 100, objects: [object(301, "com.microsoft.edgemac.helper")]),
            [301]
        )
        XCTAssertEqual(
            match(appID: "bundle:com.brave.Browser", pid: 100, objects: [object(302, "com.brave.Browser.helper")]),
            [302]
        )
        XCTAssertEqual(
            match(appID: "bundle:company.thebrowser.Browser", pid: 100, objects: [object(303, "company.thebrowser.Browser.helper")]),
            [303]
        )
        XCTAssertEqual(
            match(appID: "bundle:com.hnc.Discord", pid: 100, objects: [object(304, "com.hnc.Discord.helper")]),
            [304]
        )
    }

    func testBundleMatchIsCaseInsensitiveAndIncludesExactBundleID() {
        let matches = match(
            appID: "bundle:com.google.Chrome",
            pid: 100,
            objects: [object(300, "COM.GOOGLE.CHROME.HELPER"), object(301, "com.google.chrome")]
        )

        XCTAssertEqual(matches, [300, 301])
    }

    func testSharedBundlePrefixWithoutDotDoesNotMatch() {
        let matches = match(
            appID: "bundle:com.google.Chrome",
            pid: 100,
            objects: [object(300, "com.google.ChromeRemoteDesktop"), object(301, "com.google.Chromecast.helper")]
        )

        XCTAssertEqual(matches, [])
    }

    func testUnrelatedAppsAndProcessesAreExcluded() {
        let matches = match(
            appID: "bundle:com.google.Chrome",
            pid: 100,
            objects: [object(700, "com.spotify.client"), object(701, "com.apple.WebKit.GPU"), object(702, nil)],
            processes: [process(700, parent: 1), process(701, parent: 1), process(702, parent: 1)]
        )

        XCTAssertEqual(matches, [])
    }

    func testSafariIncludesWebKitProcessesButOtherAppsDoNot() {
        let objects = [
            object(500, "com.apple.WebKit.GPU"),
            object(501, "com.apple.WebKit.WebContent"),
            object(502, "com.apple.WebKitHelper")
        ]

        XCTAssertEqual(match(appID: "bundle:com.apple.Safari", pid: 100, objects: objects), [500, 501])
        XCTAssertEqual(match(appID: "bundle:com.apple.SafariTechnologyPreview", pid: 100, objects: objects), [500, 501])
        XCTAssertEqual(match(appID: "bundle:com.apple.mail", pid: 100, objects: objects), [])
    }

    func testOwnProcessIsNeverIncluded() {
        let matches = match(
            appID: "bundle:com.google.Chrome",
            pid: 100,
            objects: [object(ownPID, "com.google.Chrome.helper"), object(300, "com.google.Chrome.helper")],
            processes: [process(ownPID, parent: 100)]
        )

        XCTAssertEqual(matches, [300])
    }

    func testOwnVisiblePIDIsExcludedToo() {
        let matches = match(appID: "pid:\(ownPID)", pid: ownPID, objects: [object(ownPID, nil)])

        XCTAssertEqual(matches, [])
    }

    func testRunningOutputFirstThenByPIDAndDeduplicated() {
        let matches = match(
            appID: "bundle:com.google.Chrome",
            pid: 100,
            objects: [
                object(100, "com.google.Chrome"),
                object(305, "com.google.Chrome.helper", running: true),
                object(301, "com.google.Chrome.helper"),
                object(303, "com.google.Chrome.helper", running: true),
                object(301, "com.google.Chrome.helper", running: true)
            ]
        )

        XCTAssertEqual(matches, [301, 303, 305, 100])
    }

    func testNoVisiblePIDAndNoBundleIDMatchesNothing() {
        XCTAssertEqual(match(appID: "executable:/x", pid: nil, objects: [object(100, nil)]), [])
    }

    func testTargetKeepsVisiblePIDPrimaryAndAddsTheRest() {
        let request = AppAudioTargetRequest(appID: "bundle:com.google.Chrome", appName: "Google Chrome", processIdentifier: 100)

        XCTAssertEqual(
            AppAudioProcessMatcher.target(for: request, matchedProcessIdentifiers: [300, 100, 301, 300]),
            ProcessTapTarget(
                appID: "bundle:com.google.Chrome",
                appName: "Google Chrome",
                processIdentifier: 100,
                additionalProcessIdentifiers: [300, 301]
            )
        )
        XCTAssertNil(AppAudioProcessMatcher.target(for: request, matchedProcessIdentifiers: []))
    }

    func testTargetUsesFirstMatchWithoutValidVisiblePID() {
        let request = AppAudioTargetRequest(appID: "bundle:com.apple.Safari", appName: "Safari", processIdentifier: nil)

        let target = AppAudioProcessMatcher.target(for: request, matchedProcessIdentifiers: [500, 501])

        XCTAssertEqual(target?.processIdentifier, 500)
        XCTAssertEqual(target?.additionalProcessIdentifiers, [501])
        XCTAssertEqual(target?.allProcessIdentifiers, [500, 501])
    }

    func testAllProcessIdentifiersListsPrimaryFirstWithoutDuplicatesOrInvalidIDs() {
        let target = ProcessTapTarget(
            appID: "a",
            appName: "A",
            processIdentifier: 100,
            additionalProcessIdentifiers: [300, 100, -1, 0, 300, 301]
        )

        XCTAssertEqual(target.allProcessIdentifiers, [100, 300, 301])
        XCTAssertEqual(ProcessTapTarget(appID: "a", appName: "A", processIdentifier: nil).allProcessIdentifiers, [])
    }

    // MARK: - Helpers

    private func match(
        appID: String,
        pid: Int32?,
        objects: [AudioProcessObjectInfo],
        processes: [SystemProcessInfo] = []
    ) -> [Int32] {
        AppAudioProcessMatcher.matchingProcessObjects(
            for: AppAudioTargetRequest(appID: appID, appName: "App", processIdentifier: pid),
            processObjects: objects,
            processes: processes,
            ownProcessIdentifier: ownPID
        ).map(\.processIdentifier)
    }

    private func object(_ pid: Int32, _ bundleID: String?, running: Bool = false) -> AudioProcessObjectInfo {
        AudioProcessObjectInfo(
            objectID: UInt32(10_000 + pid),
            processIdentifier: pid,
            bundleIdentifier: bundleID,
            isRunningOutput: running
        )
    }

    private func process(_ pid: Int32, parent: Int32?) -> SystemProcessInfo {
        SystemProcessInfo(processIdentifier: pid, parentProcessIdentifier: parent, name: "p\(pid)", executablePath: nil)
    }
}
