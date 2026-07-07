import XCTest
@testable import MacMiniMixer

final class RealControlBannerPresenterTests: XCTestCase {
    func testHiddenWhenNoLiveControlActive() {
        let presentation = RealControlBannerPresenter.make(
            confirmedProductRealControlAppNames: [],
            isAdvancedManualLiveControlActive: false,
            activeLiveControlAppName: nil,
            isLiveControlActive: false
        )

        XCTAssertNil(presentation)
    }

    func testSingleProductAppUsesSingularWording() {
        let presentation = RealControlBannerPresenter.make(
            confirmedProductRealControlAppNames: ["Safari"],
            isAdvancedManualLiveControlActive: false,
            activeLiveControlAppName: nil,
            isLiveControlActive: true
        )

        XCTAssertEqual(
            presentation,
            RealControlBannerPresentation(
                mode: .product,
                appNames: ["Safari"],
                confirmedCount: 1,
                summaryText: "Real control: Safari",
                stopButtonTitle: "Stop",
                accessibilityLabel: "Real control active for Safari",
                stopAccessibilityLabel: "Stop real control for Safari"
            )
        )
    }

    func testTwoProductAppsUseStopAllAndPluralWording() {
        let presentation = RealControlBannerPresenter.make(
            confirmedProductRealControlAppNames: ["Safari", "Music"],
            isAdvancedManualLiveControlActive: false,
            activeLiveControlAppName: nil,
            isLiveControlActive: true
        )

        XCTAssertEqual(
            presentation,
            RealControlBannerPresentation(
                mode: .product,
                appNames: ["Safari", "Music"],
                confirmedCount: 2,
                summaryText: "Real control: Safari, Music",
                stopButtonTitle: "Stop All",
                accessibilityLabel: "Real control active for 2 apps: Safari, Music",
                stopAccessibilityLabel: "Stop real control for all apps"
            )
        )
    }

    func testThreeProductAppsSummarizeFirstTwoPlusMore() {
        let presentation = RealControlBannerPresenter.make(
            confirmedProductRealControlAppNames: ["Safari", "Music", "Podcasts"],
            isAdvancedManualLiveControlActive: false,
            activeLiveControlAppName: nil,
            isLiveControlActive: true
        )

        XCTAssertEqual(
            presentation,
            RealControlBannerPresentation(
                mode: .product,
                appNames: ["Safari", "Music", "Podcasts"],
                confirmedCount: 3,
                summaryText: "Real control: Safari, Music +1 more",
                stopButtonTitle: "Stop All",
                accessibilityLabel: "Real control active for 3 apps: Safari, Music, Podcasts",
                stopAccessibilityLabel: "Stop real control for all apps"
            )
        )
    }

    func testAdvancedManualLiveControlUsesSingleAppWording() {
        let presentation = RealControlBannerPresenter.make(
            confirmedProductRealControlAppNames: [],
            isAdvancedManualLiveControlActive: true,
            activeLiveControlAppName: "Zoom",
            isLiveControlActive: true
        )

        XCTAssertEqual(
            presentation,
            RealControlBannerPresentation(
                mode: .advancedManual,
                appNames: ["Zoom"],
                confirmedCount: 0,
                summaryText: "Real control: Zoom",
                stopButtonTitle: "Stop",
                accessibilityLabel: "Real control active for Zoom",
                stopAccessibilityLabel: "Stop real control for Zoom"
            )
        )
    }

    func testAdvancedManualLiveControlFallsBackToActiveWhenNameMissing() {
        let presentation = RealControlBannerPresenter.make(
            confirmedProductRealControlAppNames: [],
            isAdvancedManualLiveControlActive: true,
            activeLiveControlAppName: nil,
            isLiveControlActive: true
        )

        XCTAssertEqual(
            presentation,
            RealControlBannerPresentation(
                mode: .advancedManual,
                appNames: [],
                confirmedCount: 0,
                summaryText: "Real control: Active",
                stopButtonTitle: "Stop",
                accessibilityLabel: "Real control active for Active",
                stopAccessibilityLabel: "Stop real control for Active"
            )
        )
    }

    func testProductNamesTakePrecedenceOverAdvancedManual() {
        let presentation = RealControlBannerPresenter.make(
            confirmedProductRealControlAppNames: ["Safari"],
            isAdvancedManualLiveControlActive: true,
            activeLiveControlAppName: "Zoom",
            isLiveControlActive: true
        )

        XCTAssertEqual(presentation?.mode, .product)
        XCTAssertEqual(presentation?.appNames, ["Safari"])
        XCTAssertEqual(presentation?.summaryText, "Real control: Safari")
    }

    func testTransientGenericBannerWhenActiveButNoNames() {
        let presentation = RealControlBannerPresenter.make(
            confirmedProductRealControlAppNames: [],
            isAdvancedManualLiveControlActive: false,
            activeLiveControlAppName: nil,
            isLiveControlActive: true
        )

        XCTAssertEqual(
            presentation,
            RealControlBannerPresentation(
                mode: .product,
                appNames: [],
                confirmedCount: 0,
                summaryText: "Real control: Active",
                stopButtonTitle: "Stop",
                accessibilityLabel: "Real control active",
                stopAccessibilityLabel: "Stop real control"
            )
        )
    }
}
