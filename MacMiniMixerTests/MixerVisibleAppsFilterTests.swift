import XCTest
@testable import MacMiniMixer

final class MixerVisibleAppsFilterTests: XCTestCase {
    // "Safari"/"Music" are audio-relevant keywords; "Finder"/"Notes" are non-audio; "Widget" matches
    // neither list, so it is hidden unless another criterion (active/resolving/selected) applies.
    private func makeApp(id: String, name: String, pid: Int32? = 100) -> MixerAppItem {
        MixerAppItem(
            id: id,
            name: name,
            icon: .systemSymbol("app"),
            processIdentifier: pid,
            volume: 50
        )
    }

    func testShowAllAppsReturnsEveryAppInOriginalOrder() {
        let apps = [
            makeApp(id: "a", name: "Finder"),
            makeApp(id: "b", name: "Safari"),
            makeApp(id: "c", name: "Widget")
        ]

        let visible = MixerVisibleAppsFilter.visibleApps(
            apps: apps,
            showAllApps: true,
            activeVisibleAppIDs: [],
            resolvingAppIDs: [],
            selectedProcessTapAppID: nil,
            isLiveControlActive: false
        )

        XCTAssertEqual(visible.map(\.id), ["a", "b", "c"])
    }

    func testHidesNonAudioAppsWhenNotShowingAll() {
        let apps = [
            makeApp(id: "a", name: "Finder"),
            makeApp(id: "b", name: "Safari"),
            makeApp(id: "c", name: "Widget"),
            makeApp(id: "d", name: "Music")
        ]

        let visible = MixerVisibleAppsFilter.visibleApps(
            apps: apps,
            showAllApps: false,
            activeVisibleAppIDs: [],
            resolvingAppIDs: [],
            selectedProcessTapAppID: nil,
            isLiveControlActive: false
        )

        XCTAssertEqual(visible.map(\.id), ["b", "d"])
    }

    func testActiveProductRealAppStaysVisibleEvenWhenNotAudioRelevant() {
        let apps = [
            makeApp(id: "widget", name: "Widget"),
            makeApp(id: "safari", name: "Safari")
        ]

        let visible = MixerVisibleAppsFilter.visibleApps(
            apps: apps,
            showAllApps: false,
            activeVisibleAppIDs: ["widget"],
            resolvingAppIDs: [],
            selectedProcessTapAppID: nil,
            isLiveControlActive: false
        )

        XCTAssertEqual(visible.map(\.id), ["widget", "safari"])
    }

    func testResolvingAppStaysVisibleEvenWhenNotAudioRelevant() {
        let apps = [
            makeApp(id: "widget", name: "Widget"),
            makeApp(id: "safari", name: "Safari")
        ]

        let visible = MixerVisibleAppsFilter.visibleApps(
            apps: apps,
            showAllApps: false,
            activeVisibleAppIDs: [],
            resolvingAppIDs: ["widget"],
            selectedProcessTapAppID: nil,
            isLiveControlActive: false
        )

        XCTAssertEqual(visible.map(\.id), ["widget", "safari"])
    }

    func testSelectedProcessTapTargetStaysVisibleOnlyWhenLiveControlActive() {
        let apps = [
            makeApp(id: "widget", name: "Widget"),
            makeApp(id: "safari", name: "Safari")
        ]

        let hiddenWhenInactive = MixerVisibleAppsFilter.visibleApps(
            apps: apps,
            showAllApps: false,
            activeVisibleAppIDs: [],
            resolvingAppIDs: [],
            selectedProcessTapAppID: "widget",
            isLiveControlActive: false
        )
        XCTAssertEqual(hiddenWhenInactive.map(\.id), ["safari"])

        let visibleWhenActive = MixerVisibleAppsFilter.visibleApps(
            apps: apps,
            showAllApps: false,
            activeVisibleAppIDs: [],
            resolvingAppIDs: [],
            selectedProcessTapAppID: "widget",
            isLiveControlActive: true
        )
        XCTAssertEqual(visibleWhenActive.map(\.id), ["widget", "safari"])
    }

    func testOrderIsPreservedAcrossMixedCriteria() {
        let apps = [
            makeApp(id: "1", name: "Widget"),   // hidden
            makeApp(id: "2", name: "Music"),    // audio-relevant
            makeApp(id: "3", name: "Gadget"),   // active
            makeApp(id: "4", name: "Finder"),   // hidden
            makeApp(id: "5", name: "Thing")     // resolving
        ]

        let visible = MixerVisibleAppsFilter.visibleApps(
            apps: apps,
            showAllApps: false,
            activeVisibleAppIDs: ["3"],
            resolvingAppIDs: ["5"],
            selectedProcessTapAppID: nil,
            isLiveControlActive: false
        )

        XCTAssertEqual(visible.map(\.id), ["2", "3", "5"])
    }

    func testAppMatchingMultipleCriteriaAppearsOnce() {
        let apps = [
            // Audio-relevant AND active AND resolving AND selected — must still appear exactly once.
            makeApp(id: "safari", name: "Safari")
        ]

        let visible = MixerVisibleAppsFilter.visibleApps(
            apps: apps,
            showAllApps: false,
            activeVisibleAppIDs: ["safari"],
            resolvingAppIDs: ["safari"],
            selectedProcessTapAppID: "safari",
            isLiveControlActive: true
        )

        XCTAssertEqual(visible.map(\.id), ["safari"])
    }

    func testIsActiveLiveControlTargetMatchesActiveSessionOrSelectionWhenLive() {
        XCTAssertTrue(
            MixerVisibleAppsFilter.isActiveLiveControlTarget(
                "a",
                activeVisibleAppIDs: ["a"],
                selectedProcessTapAppID: nil,
                isLiveControlActive: false
            )
        )
        XCTAssertTrue(
            MixerVisibleAppsFilter.isActiveLiveControlTarget(
                "a",
                activeVisibleAppIDs: [],
                selectedProcessTapAppID: "a",
                isLiveControlActive: true
            )
        )
        XCTAssertFalse(
            MixerVisibleAppsFilter.isActiveLiveControlTarget(
                "a",
                activeVisibleAppIDs: [],
                selectedProcessTapAppID: "a",
                isLiveControlActive: false
            )
        )
    }
}
