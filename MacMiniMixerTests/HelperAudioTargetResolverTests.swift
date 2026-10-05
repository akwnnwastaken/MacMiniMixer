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
    // is not a Core Audio client. With no coalition info (bundle-id fallback) and no other WebKit-owning
    // row running, it is matched by the WebKit bundle prefix and resolved without probing.
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

    // MARK: - Resource coalition attribution

    // Safari's own process is not a HAL client, so the resolver must still list it (with the HAL
    // clients) to learn Safari's resource coalition.
    func testMatchedAudioProcessIdentifiersAlsoListsTheAppProcessForItsCoalition() {
        let lister = FakeProcessLister(processes: [])
        let objects = FakeAudioProcessObjectLister(objects: [
            makeObject(pid: 500, bundleID: "com.apple.WebKit.GPU", running: true),
            makeObject(pid: 700, bundleID: "com.spotify.client", running: true)
        ])
        let resolver = makeResolver(lister: lister, probe: FakeCandidateAudioProbe(), processObjects: objects)

        _ = resolver.matchedAudioProcessIdentifiers(
            for: makeRequest(appID: "bundle:com.apple.Safari", name: "Safari", pid: 100)
        )

        XCTAssertEqual(lister.ancestryRequests, [[500, 700, 100]])
    }

    // The reported bug: Safari and a Safari web app ("YouTube", `com.apple.Safari.WebApp.<UUID>`)
    // each have their own WebKit GPU process. Resource coalitions attribute each GPU process to its
    // owner, so each row resolves to its own processes only (no overlap for the double-tap guard to
    // reject), without probing.
    func testSafariAndSafariWebAppResolveToTheirOwnWebKitProcessesByCoalition() async {
        let webAppBundleID = "com.apple.Safari.WebApp.7F3A2B10"
        let lister = FakeProcessLister(processes: [
            makeProcess(pid: 100, parentPID: 1, name: "Safari", coalition: 1_000),
            makeProcess(pid: 200, parentPID: 1, name: "YouTube", coalition: 2_000),
            makeProcess(pid: 500, parentPID: 1, name: "com.apple.WebKit.GPU", coalition: 1_000),
            makeProcess(pid: 510, parentPID: 1, name: "com.apple.WebKit.GPU", coalition: 2_000),
            makeProcess(pid: 511, parentPID: 1, name: "com.apple.WebKit.WebContent", coalition: 2_000)
        ])
        let probe = FakeCandidateAudioProbe()
        let objects = FakeAudioProcessObjectLister(objects: [
            makeObject(pid: 200, bundleID: webAppBundleID),
            makeObject(pid: 500, bundleID: "com.apple.WebKit.GPU", running: true),
            makeObject(pid: 510, bundleID: "com.apple.WebKit.GPU", running: true),
            makeObject(pid: 511, bundleID: "com.apple.WebKit.WebContent")
        ])
        let resolver = makeResolver(lister: lister, probe: probe, processObjects: objects)
        var safariRequest = makeRequest(appID: "bundle:com.apple.Safari", name: "Safari", pid: 100)
        safariRequest.otherRunningApps = [.init(processIdentifier: 200, bundleIdentifier: webAppBundleID)]
        var webAppRequest = makeRequest(appID: "bundle:\(webAppBundleID)", name: "YouTube", pid: 200)
        webAppRequest.otherRunningApps = [.init(processIdentifier: 100, bundleIdentifier: "com.apple.Safari")]

        let safariResult = await resolver.resolveTarget(for: safariRequest, allowsCachedLookup: true) { _ in }
        let webAppResult = await resolver.resolveTarget(for: webAppRequest, allowsCachedLookup: true) { _ in }

        guard case let .resolved(safariTarget) = safariResult, case let .resolved(webAppTarget) = webAppResult else {
            return XCTFail("Expected two matched targets, got \(safariResult) and \(webAppResult)")
        }
        XCTAssertEqual(
            safariTarget.target,
            ProcessTapTarget(appID: "bundle:com.apple.Safari", appName: "Safari", processIdentifier: 100, additionalProcessIdentifiers: [500])
        )
        XCTAssertEqual(safariTarget.source, .matchedAudioProcesses)
        XCTAssertEqual(
            webAppTarget.target,
            ProcessTapTarget(appID: "bundle:\(webAppBundleID)", appName: "YouTube", processIdentifier: 200, additionalProcessIdentifiers: [510, 511])
        )
        XCTAssertEqual(webAppTarget.source, .matchedAudioProcesses)
        XCTAssertTrue(probe.probedPIDs.isEmpty)
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
        name: String,
        coalition: UInt64? = nil
    ) -> SystemProcessInfo {
        SystemProcessInfo(
            processIdentifier: pid,
            parentProcessIdentifier: parentPID,
            name: name,
            executablePath: nil,
            resourceCoalitionID: coalition
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

    private var storedAncestryRequests: [[Int32]] = []

    /// The pid lists `listProcessAncestry(of:)` was asked for, in call order.
    var ancestryRequests: [[Int32]] {
        lock.lock()
        defer { lock.unlock() }
        return storedAncestryRequests
    }

    /// Records the requested pids and, like the protocol default, returns every fixture process
    /// (counted as a list call).
    func listProcessAncestry(of processIdentifiers: [Int32]) -> [SystemProcessInfo] {
        lock.lock()
        defer { lock.unlock() }
        storedListCallCount += 1
        storedAncestryRequests.append(processIdentifiers)
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

    // MARK: - Resource coalition mode

    // The reported bug, Safari + a "YouTube" Safari web app: each WebKit process sits in its owner's
    // resource coalition, so each row gets only its own processes. Coalitions alone are enough (the
    // other-row list only adds the web app's own pid exclusion), and the old `com.apple.Safari.`
    // prefix no longer pulls the web app's process into the Safari row.
    func testCoalitionSeparatesSafariFromASafariWebApp() {
        let objects = [
            object(200, safariWebAppBundleID),
            object(500, "com.apple.WebKit.GPU", running: true),
            object(501, "com.apple.WebKit.WebContent"),
            object(510, "com.apple.WebKit.GPU", running: true),
            object(511, "com.apple.WebKit.WebContent")
        ]
        let processes = [
            process(100, parent: 1, coalition: 1_000),
            process(200, parent: 1, coalition: 2_000),
            process(500, parent: 1, coalition: 1_000),
            process(501, parent: 1, coalition: 1_000),
            process(510, parent: 1, coalition: 2_000),
            process(511, parent: 1, coalition: 2_000)
        ]
        let safariRow = AppAudioTargetRequest.OtherRunningApp(processIdentifier: 100, bundleIdentifier: "com.apple.Safari")
        let webAppRow = AppAudioTargetRequest.OtherRunningApp(processIdentifier: 200, bundleIdentifier: safariWebAppBundleID)

        XCTAssertEqual(
            match(appID: "bundle:com.apple.Safari", pid: 100, objects: objects, processes: processes, otherApps: [webAppRow]),
            [500, 501]
        )
        XCTAssertEqual(
            match(appID: "bundle:\(safariWebAppBundleID)", pid: 200, objects: objects, processes: processes, otherApps: [safariRow]),
            [510, 200, 511]
        )
        // Coalitions alone keep them apart.
        XCTAssertEqual(match(appID: "bundle:com.apple.Safari", pid: 100, objects: objects, processes: processes), [500, 501])
        XCTAssertEqual(
            match(appID: "bundle:\(safariWebAppBundleID)", pid: 200, objects: objects, processes: processes),
            [510, 200, 511]
        )
    }

    // Coalition mode is authoritative: a helper-named process in another coalition is not matched,
    // while processes with an unrelated or missing bundle id in the app's coalition are.
    func testCoalitionModeIgnoresBundleIDsAndMatchesTheAppsCoalition() {
        let matches = match(
            appID: "bundle:com.google.Chrome",
            pid: 100,
            objects: [
                object(300, "com.google.Chrome.helper"),
                object(301, "com.example.unrelated"),
                object(302, nil),
                object(303, "com.google.Chrome"),
                object(304, "com.apple.WebKit.GPU")
            ],
            processes: [
                process(100, parent: 1, coalition: 10),
                process(300, parent: 1, coalition: 99),
                process(301, parent: 1, coalition: 10),
                process(302, parent: 1, coalition: 10),
                process(303, parent: 1, coalition: 98),
                process(304, parent: 1, coalition: 97)
            ]
        )

        XCTAssertEqual(matches, [301, 302])
    }

    // Descendants still match in coalition mode, even with a different coalition id.
    func testDescendantsMatchRegardlessOfCoalition() {
        let matches = match(
            appID: "bundle:com.google.Chrome",
            pid: 100,
            objects: [object(300, "com.google.Chrome.helper")],
            processes: [process(100, parent: 1, coalition: 10), process(300, parent: 100, coalition: 99)]
        )

        XCTAssertEqual(matches, [300])
    }

    // Chrome, a Chrome PWA shim (`com.google.Chrome.app.<id>`, launched as its own app) and Chrome
    // Canary each live in their own coalition: each row gets only its own processes.
    func testCoalitionSeparatesChromeChromePWAShimAndChromeCanary() {
        let fixture = chromeFamilyFixture()
        let processes = [
            process(100, parent: 1, coalition: 10),
            process(300, parent: 100, coalition: 10),
            process(400, parent: 1, coalition: 40),
            process(200, parent: 1, coalition: 20),
            process(310, parent: 200, coalition: 20)
        ]

        XCTAssertEqual(
            match(appID: "bundle:com.google.Chrome", pid: 100, objects: fixture.objects, processes: processes, otherApps: [fixture.pwaRow, fixture.canaryRow]),
            [300, 100]
        )
        XCTAssertEqual(
            match(appID: "bundle:\(chromePWABundleID)", pid: 400, objects: fixture.objects, processes: processes, otherApps: [fixture.chromeRow, fixture.canaryRow]),
            [400]
        )
        XCTAssertEqual(
            match(appID: "bundle:com.google.Chrome.canary", pid: 200, objects: fixture.objects, processes: processes, otherApps: [fixture.chromeRow, fixture.pwaRow]),
            [310, 200]
        )
        // Coalitions alone keep them apart.
        XCTAssertEqual(match(appID: "bundle:com.google.Chrome", pid: 100, objects: fixture.objects, processes: processes), [300, 100])
    }

    // A process that is another row's own app never belongs to this row, even when it is a child of
    // this app or shares its coalition (e.g. an app launched by another app).
    func testAnotherRowsAppProcessIsNeverMatchedEvenAsChildOrCoalitionMember() {
        let matches = match(
            appID: "bundle:com.example.Launcher",
            pid: 100,
            objects: [object(200, "com.example.Game"), object(300, "com.example.Launcher.helper")],
            processes: [
                process(100, parent: 1, coalition: 10),
                process(200, parent: 100, coalition: 10),
                process(300, parent: 100, coalition: 10)
            ],
            otherApps: [.init(processIdentifier: 200, bundleIdentifier: "com.example.Game")]
        )

        XCTAssertEqual(matches, [300])
    }

    // MARK: - Bundle-id fallback (a coalition id is unknown)

    // Without coalition info the tightened bundle rules still separate the Chrome family: `.app.*`
    // (PWA shim) and `.canary` are not helper suffixes, and another row's pid is never matched.
    func testFallbackSeparatesChromeChromePWAShimAndChromeCanary() {
        let fixture = chromeFamilyFixture()

        XCTAssertEqual(
            match(appID: "bundle:com.google.Chrome", pid: 100, objects: fixture.objects, otherApps: [fixture.pwaRow, fixture.canaryRow]),
            [300, 100]
        )
        XCTAssertEqual(
            match(appID: "bundle:\(chromePWABundleID)", pid: 400, objects: fixture.objects, otherApps: [fixture.chromeRow, fixture.canaryRow]),
            [400]
        )
        XCTAssertEqual(
            match(appID: "bundle:com.google.Chrome.canary", pid: 200, objects: fixture.objects, otherApps: [fixture.chromeRow, fixture.pwaRow]),
            [310, 200]
        )
        // Even without the other-row list the Chrome row takes none of the shim's or Canary's processes.
        XCTAssertEqual(match(appID: "bundle:com.google.Chrome", pid: 100, objects: fixture.objects), [300, 100])
    }

    // Deliberate change from the old `<bundle id>.` prefix rule: sub-apps and sibling channels are not
    // helpers of the app.
    func testFallbackDoesNotMatchSubAppsOrSiblingChannels() {
        let chromeMatches = match(
            appID: "bundle:com.google.Chrome",
            pid: 100,
            objects: [
                object(301, "com.google.Chrome.canary"),
                object(302, "com.google.Chrome.beta"),
                object(303, "com.google.Chrome.dev"),
                object(304, "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"),
                object(305, "com.google.Chrome.canary.helper"),
                object(306, "com.google.Chrome.framework")
            ]
        )
        let safariMatches = match(
            appID: "bundle:com.apple.Safari",
            pid: 100,
            objects: [object(401, safariWebAppBundleID)]
        )

        XCTAssertEqual(chromeMatches, [])
        XCTAssertEqual(safariMatches, [])
    }

    func testFallbackNeverMatchesAnotherRowsExactBundleID() {
        let matches = match(
            appID: "bundle:com.example.Player",
            pid: 100,
            objects: [object(601, "com.example.Player.helper"), object(602, "com.example.Player.helper.Renderer")],
            otherApps: [.init(processIdentifier: 600, bundleIdentifier: "com.example.Player.helper")]
        )

        XCTAssertEqual(matches, [602])
    }

    // Fallback Safari WebKit rule: withheld while another WebKit-owning row runs (a Safari web app or
    // the other Safari flavor), since those WebKit processes may be that row's; an unrelated row does
    // not block it. A Safari web app row never takes WebKit processes in the fallback.
    func testFallbackSafariWebKitRuleIsWithheldWhileAnotherWebKitOwnerRuns() {
        let objects = [object(500, "com.apple.WebKit.GPU", running: true), object(501, "com.apple.WebKit.WebContent")]
        let webAppRow = AppAudioTargetRequest.OtherRunningApp(processIdentifier: 200, bundleIdentifier: safariWebAppBundleID)
        let previewRow = AppAudioTargetRequest.OtherRunningApp(processIdentifier: 300, bundleIdentifier: "com.apple.SafariTechnologyPreview")
        let spotifyRow = AppAudioTargetRequest.OtherRunningApp(processIdentifier: 700, bundleIdentifier: "com.spotify.client")
        let safariRow = AppAudioTargetRequest.OtherRunningApp(processIdentifier: 100, bundleIdentifier: "com.apple.Safari")

        XCTAssertEqual(match(appID: "bundle:com.apple.Safari", pid: 100, objects: objects, otherApps: [spotifyRow]), [500, 501])
        XCTAssertEqual(match(appID: "bundle:com.apple.Safari", pid: 100, objects: objects, otherApps: [spotifyRow, webAppRow]), [])
        XCTAssertEqual(match(appID: "bundle:com.apple.Safari", pid: 100, objects: objects, otherApps: [previewRow]), [])
        XCTAssertEqual(
            match(appID: "bundle:\(safariWebAppBundleID)", pid: 200, objects: objects + [object(200, safariWebAppBundleID)], otherApps: [safariRow]),
            [200]
        )
    }

    // The fallback is decided per process: with Safari's coalition known, a WebKit process whose
    // coalition is unknown goes through the (guarded) bundle rules, while one in another known
    // coalition is simply not Safari's.
    func testFallbackAppliesPerProcessWhenOnlyTheObjectCoalitionIsUnknown() {
        let objects = [object(500, "com.apple.WebKit.GPU", running: true), object(510, "com.apple.WebKit.GPU", running: true)]
        let processes = [
            process(100, parent: 1, coalition: 1_000),
            process(500, parent: 1, coalition: nil),
            process(510, parent: 1, coalition: 2_000)
        ]
        let webAppRow = AppAudioTargetRequest.OtherRunningApp(processIdentifier: 200, bundleIdentifier: safariWebAppBundleID)

        XCTAssertEqual(match(appID: "bundle:com.apple.Safari", pid: 100, objects: objects, processes: processes), [500])
        XCTAssertEqual(match(appID: "bundle:com.apple.Safari", pid: 100, objects: objects, processes: processes, otherApps: [webAppRow]), [])
    }

    // A zero coalition id is "unknown", never a shared coalition.
    func testZeroCoalitionIDIsTreatedAsUnknown() {
        let matches = match(
            appID: "bundle:com.google.Chrome",
            pid: 100,
            objects: [object(300, "com.example.unrelated"), object(301, "com.google.Chrome.helper")],
            processes: [process(100, parent: 1, coalition: 0), process(300, parent: 1, coalition: 0), process(301, parent: 1, coalition: 0)]
        )

        XCTAssertEqual(matches, [301])
    }

    // An entry for this very app in the other-row list (same pid / bundle id) never excludes it.
    func testOtherRowEntryForTheSameAppDoesNotExcludeItsOwnProcesses() {
        let matches = match(
            appID: "bundle:com.google.Chrome",
            pid: 100,
            objects: [object(100, "com.google.Chrome"), object(300, "com.google.Chrome.helper")],
            otherApps: [.init(processIdentifier: 100, bundleIdentifier: "com.google.Chrome")]
        )

        XCTAssertEqual(matches, [100, 300])
    }

    func testHelperBundleIdentifierAllowList() {
        let helpers: [(String, String)] = [
            ("com.google.Chrome.helper", "com.google.Chrome"),
            ("com.google.Chrome.helper.Renderer", "com.google.Chrome"),
            ("COM.GOOGLE.CHROME.HELPER.GPU", "com.google.Chrome"),
            ("com.google.Chrome.framework.AlertNotificationService", "com.google.Chrome"),
            ("com.google.Chrome.canary.helper", "com.google.Chrome.canary"),
            ("com.microsoft.edgemac.helper.plugin", "com.microsoft.edgemac"),
            ("com.brave.Browser.helper", "com.brave.Browser"),
            ("com.hnc.Discord.helper.Renderer", "com.hnc.Discord"),
            ("com.tinyspeck.slackmacgap.helper", "com.tinyspeck.slackmacgap"),
            ("com.microsoft.VSCode.helper.Plugin", "com.microsoft.VSCode")
        ]
        let nonHelpers: [(String, String)] = [
            ("com.google.Chrome", "com.google.Chrome"),
            ("com.google.Chrome.canary", "com.google.Chrome"),
            ("com.google.Chrome.beta", "com.google.Chrome"),
            ("com.google.Chrome.dev", "com.google.Chrome"),
            ("com.google.Chrome.canary.helper", "com.google.Chrome"),
            ("com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", "com.google.Chrome"),
            ("com.google.Chrome.framework", "com.google.Chrome"),
            ("com.google.Chrome.helperx", "com.google.Chrome"),
            ("com.google.ChromeRemoteDesktop.helper", "com.google.Chrome"),
            ("com.apple.Safari.WebApp.7F3A2B10", "com.apple.Safari"),
            ("com.brave.Browser.nightly", "com.brave.Browser")
        ]

        for (candidate, app) in helpers {
            XCTAssertTrue(AppAudioProcessMatcher.isHelperBundleIdentifier(candidate, ofApp: app), "\(candidate) should be a helper of \(app)")
        }
        for (candidate, app) in nonHelpers {
            XCTAssertFalse(AppAudioProcessMatcher.isHelperBundleIdentifier(candidate, ofApp: app), "\(candidate) should not be a helper of \(app)")
        }
    }

    func testKnownWebKitProcessOwners() {
        XCTAssertTrue(AppAudioProcessMatcher.isKnownWebKitProcessOwner(safariWebAppBundleID))
        XCTAssertTrue(AppAudioProcessMatcher.isKnownWebKitProcessOwner("com.apple.SafariTechnologyPreview"))
        XCTAssertTrue(AppAudioProcessMatcher.isKnownWebKitProcessOwner("com.apple.Safari"))
        XCTAssertFalse(AppAudioProcessMatcher.isKnownWebKitProcessOwner("com.apple.mail"))
        XCTAssertFalse(AppAudioProcessMatcher.isKnownWebKitProcessOwner("com.google.Chrome"))
    }

    // MARK: - Helpers

    private let safariWebAppBundleID = "com.apple.Safari.WebApp.7F3A2B10-1C2D-4E5F-8A9B-0C1D2E3F4A5B"
    private let chromePWABundleID = "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"

    /// Chrome (pid 100) with its helper (300), a Chrome PWA shim (400) and Chrome Canary (200) with
    /// its helper (310), as HAL objects, plus each one's row entry for `otherApps`.
    private func chromeFamilyFixture() -> (
        objects: [AudioProcessObjectInfo],
        chromeRow: AppAudioTargetRequest.OtherRunningApp,
        pwaRow: AppAudioTargetRequest.OtherRunningApp,
        canaryRow: AppAudioTargetRequest.OtherRunningApp
    ) {
        (
            objects: [
                object(100, "com.google.Chrome"),
                object(300, "com.google.Chrome.helper", running: true),
                object(400, chromePWABundleID),
                object(200, "com.google.Chrome.canary"),
                object(310, "com.google.Chrome.canary.helper", running: true)
            ],
            chromeRow: AppAudioTargetRequest.OtherRunningApp(processIdentifier: 100, bundleIdentifier: "com.google.Chrome"),
            pwaRow: AppAudioTargetRequest.OtherRunningApp(processIdentifier: 400, bundleIdentifier: chromePWABundleID),
            canaryRow: AppAudioTargetRequest.OtherRunningApp(processIdentifier: 200, bundleIdentifier: "com.google.Chrome.canary")
        )
    }

    private func match(
        appID: String,
        pid: Int32?,
        objects: [AudioProcessObjectInfo],
        processes: [SystemProcessInfo] = [],
        otherApps: [AppAudioTargetRequest.OtherRunningApp] = []
    ) -> [Int32] {
        AppAudioProcessMatcher.matchingProcessObjects(
            for: AppAudioTargetRequest(appID: appID, appName: "App", processIdentifier: pid, otherRunningApps: otherApps),
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

    private func process(_ pid: Int32, parent: Int32?, coalition: UInt64? = nil) -> SystemProcessInfo {
        SystemProcessInfo(
            processIdentifier: pid,
            parentProcessIdentifier: parent,
            name: "p\(pid)",
            executablePath: nil,
            resourceCoalitionID: coalition
        )
    }
}

/// `SystemProcessLister`'s `proc_pidinfo(PROC_PIDCOALITIONINFO)` parsing. Real coalition ids cannot
/// be asserted in a unit test; only the parsing of a read is checked.
final class SystemProcessListerCoalitionTests: XCTestCase {
    func testCoalitionInfoBufferIsFiveWordsOfFortyBytes() {
        XCTAssertEqual(SystemProcessLister.coalitionInfoWordCount, 5)
        XCTAssertEqual(SystemProcessLister.coalitionInfoWordCount * MemoryLayout<UInt64>.size, 40)
    }

    func testFullReadReturnsTheResourceCoalitionSlot() {
        XCTAssertEqual(
            SystemProcessLister.resourceCoalitionID(fromCoalitionInfoWords: [1_234, 5_678, 0, 0, 0], returnedByteCount: 40),
            1_234
        )
    }

    func testZeroResourceCoalitionIDIsUnknown() {
        XCTAssertNil(SystemProcessLister.resourceCoalitionID(fromCoalitionInfoWords: [0, 5_678, 0, 0, 0], returnedByteCount: 40))
    }

    func testFailedOrShortReadIsUnknown() {
        let words: [UInt64] = [1_234, 5_678, 0, 0, 0]
        XCTAssertNil(SystemProcessLister.resourceCoalitionID(fromCoalitionInfoWords: words, returnedByteCount: 0))
        XCTAssertNil(SystemProcessLister.resourceCoalitionID(fromCoalitionInfoWords: words, returnedByteCount: -1))
        XCTAssertNil(SystemProcessLister.resourceCoalitionID(fromCoalitionInfoWords: words, returnedByteCount: 8))
        XCTAssertNil(SystemProcessLister.resourceCoalitionID(fromCoalitionInfoWords: [], returnedByteCount: 40))
    }
}
