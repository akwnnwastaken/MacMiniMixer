import XCTest
@testable import MacMiniMixer

final class HelperProcessCandidateDiscoveryTests: XCTestCase {
    func testIncludesSelectedVisibleAppAsDirectCandidateWhenMissingFromProcessList() {
        let target = makeTarget(name: "Safari", pid: 100)

        let candidates = discover(target: target, processes: [])

        XCTAssertEqual(candidates.map(\.process.processIdentifier), [100])
        XCTAssertEqual(candidates.first?.process.name, "Safari")
        XCTAssertEqual(candidates.first?.relation, .directApp)
    }

    func testClassifiesDirectChildProcessAsChild() {
        let target = makeTarget(name: "Safari", pid: 100)
        let processes = [
            makeProcess(pid: 100, parentPID: nil, name: "Safari"),
            makeProcess(pid: 101, parentPID: 100, name: "com.apple.WebKit.GPU")
        ]

        let candidates = discover(target: target, processes: processes)

        XCTAssertEqual(relation(for: 101, in: candidates), .child)
    }

    func testClassifiesGrandchildProcessAsDescendant() {
        let target = makeTarget(name: "Safari", pid: 100)
        let processes = [
            makeProcess(pid: 100, parentPID: nil, name: "Safari"),
            makeProcess(pid: 101, parentPID: 100, name: "Safari Helper"),
            makeProcess(pid: 102, parentPID: 101, name: "com.apple.WebKit.WebContent")
        ]

        let candidates = discover(target: target, processes: processes)

        XCTAssertEqual(relation(for: 102, in: candidates), .descendant)
    }

    func testIncludesBrowserHelperNameMatchWithoutParentRelationship() {
        let target = makeTarget(name: "Safari", pid: 100)
        let processes = [
            makeProcess(pid: 100, parentPID: nil, name: "Safari"),
            makeProcess(
                pid: 205,
                parentPID: 999,
                name: "com.apple.WebKit.GPU",
                executablePath: "/System/Library/Frameworks/WebKit.framework/com.apple.WebKit.GPU"
            )
        ]

        let candidates = discover(target: target, processes: processes)

        XCTAssertEqual(relation(for: 205, in: candidates), .nameMatch)
    }

    func testExcludesUnrelatedProcesses() {
        let target = makeTarget(name: "Safari", pid: 100)
        let processes = [
            makeProcess(pid: 100, parentPID: nil, name: "Safari"),
            makeProcess(pid: 300, parentPID: nil, name: "TextEdit"),
            makeProcess(pid: 301, parentPID: 300, name: "TextEdit Helper")
        ]

        let candidates = discover(target: target, processes: processes)

        XCTAssertEqual(candidates.map(\.process.processIdentifier), [100])
    }

    func testAvoidsDuplicatesWhenProcessMatchesMultipleRules() {
        let target = makeTarget(name: "Safari", pid: 100)
        let processes = [
            makeProcess(pid: 100, parentPID: nil, name: "Safari"),
            makeProcess(pid: 101, parentPID: 100, name: "com.apple.WebKit.GPU")
        ]

        let candidates = discover(target: target, processes: processes)
        let matchingCandidates = candidates.filter { $0.process.processIdentifier == 101 }

        XCTAssertEqual(matchingCandidates.count, 1)
        XCTAssertEqual(matchingCandidates.first?.relation, .child)
    }

    func testCandidateListIsCappedAtDisplayLimit() {
        let target = makeTarget(name: "Safari", pid: 100)
        let helpers = (1...35).map { index in
            makeProcess(
                pid: Int32(200 + index),
                parentPID: 999,
                name: String(format: "com.apple.WebKit.GPU.%02d", index)
            )
        }

        let candidates = discover(
            target: target,
            processes: [makeProcess(pid: 100, parentPID: nil, name: "Safari")] + helpers
        )

        XCTAssertEqual(candidates.count, 30)
        XCTAssertTrue(candidates.contains { $0.process.processIdentifier == 100 })
    }

    func testSafariWebKitKeywordMatchingUsesNameAndExecutablePath() {
        let target = makeTarget(name: "Safari", pid: 100)
        let processes = [
            makeProcess(pid: 100, parentPID: nil, name: "Safari"),
            makeProcess(
                pid: 401,
                parentPID: nil,
                name: "Helper",
                executablePath: "/System/Library/Frameworks/WebKit.framework/com.apple.WebKit.WebContent"
            )
        ]

        let candidates = discover(target: target, processes: processes)

        XCTAssertEqual(relation(for: 401, in: candidates), .nameMatch)
    }

    func testChromeChromiumKeywordMatching() {
        let target = makeTarget(name: "Google Chrome", id: "com.google.Chrome", pid: 100)
        let processes = [
            makeProcess(pid: 100, parentPID: nil, name: "Google Chrome"),
            makeProcess(pid: 501, parentPID: nil, name: "Google Chrome Helper (Renderer)"),
            makeProcess(pid: 502, parentPID: nil, name: "Chromium Helper (GPU)")
        ]

        let candidates = discover(target: target, processes: processes)

        XCTAssertEqual(relation(for: 501, in: candidates), .nameMatch)
        XCTAssertEqual(relation(for: 502, in: candidates), .nameMatch)
    }

    func testRelationLabelsRemainStable() {
        XCTAssertEqual(HelperProcessRelation.directApp.label, "Direct app")
        XCTAssertEqual(HelperProcessRelation.child.label, "Child")
        XCTAssertEqual(HelperProcessRelation.descendant.label, "Descendant")
        XCTAssertEqual(HelperProcessRelation.nameMatch.label, "Name match")
        XCTAssertEqual(HelperProcessRelation.unknown.label, "Unknown")
    }

    func testSortOrderIsDeterministicByRelationEligibilityNameThenPID() {
        let target = makeTarget(name: "Safari", pid: 100)
        let processes = [
            makeProcess(pid: 100, parentPID: nil, name: "Safari"),
            makeProcess(pid: 103, parentPID: 100, name: "Beta Child"),
            makeProcess(pid: 102, parentPID: 100, name: "Alpha Child"),
            makeProcess(pid: 201, parentPID: 103, name: "Alpha Descendant"),
            makeProcess(pid: 301, parentPID: nil, name: "com.apple.WebKit.A Helper"),
            makeProcess(pid: 302, parentPID: nil, name: "com.apple.WebKit.Z Helper")
        ]
        let ineligiblePID: Int32 = 102

        let candidates = discover(target: target, processes: processes) { pid in
            pid == ineligiblePID ? .unavailable("unavailable") : .eligible
        }

        XCTAssertEqual(
            candidates.map(\.process.processIdentifier),
            [100, 103, 102, 201, 301, 302]
        )
    }

    func testLikelyHelperResolvableRecognizesCurrentBrowserFamilies() {
        XCTAssertTrue(
            HelperProcessCandidateDiscovery.isLikelyHelperResolvable(
                makeTarget(name: "Safari", id: "com.apple.Safari", pid: 100)
            )
        )
        XCTAssertTrue(
            HelperProcessCandidateDiscovery.isLikelyHelperResolvable(
                makeTarget(name: "YouTube", id: "com.apple.Safari.WebApp.YouTube", pid: 101)
            )
        )
        XCTAssertTrue(
            HelperProcessCandidateDiscovery.isLikelyHelperResolvable(
                makeTarget(name: "Google Chrome", id: "com.google.Chrome", pid: 102)
            )
        )
        XCTAssertTrue(
            HelperProcessCandidateDiscovery.isLikelyHelperResolvable(
                makeTarget(name: "Brave Browser", id: "com.brave.Browser", pid: 103)
            )
        )
    }

    func testLikelyHelperResolvableDoesNotTreatUnlistedAppsAsBrowserHelpers() {
        XCTAssertFalse(
            HelperProcessCandidateDiscovery.isLikelyHelperResolvable(
                makeTarget(name: "Notes", id: "com.apple.Notes", pid: 100)
            )
        )
    }

    private func discover(
        target: HelperProcessDiscoveryTarget,
        processes: [SystemProcessInfo],
        eligibilityChecker: (Int32) -> ProcessTapProcessEligibility = { _ in .eligible }
    ) -> [HelperProcessCandidate] {
        HelperProcessCandidateDiscovery.candidates(
            for: target,
            processes: processes,
            eligibilityChecker: eligibilityChecker
        )
    }

    private func relation(
        for processIdentifier: Int32,
        in candidates: [HelperProcessCandidate]
    ) -> HelperProcessRelation? {
        candidates.first { $0.process.processIdentifier == processIdentifier }?.relation
    }

    private func makeTarget(
        name: String,
        id: String = "com.example.Target",
        pid: Int32?
    ) -> HelperProcessDiscoveryTarget {
        HelperProcessDiscoveryTarget(id: id, name: name, processIdentifier: pid)
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
