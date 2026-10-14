import XCTest
@testable import MacMiniMixer

final class VolumeSliderScaleTests: XCTestCase {
    private let appScale = VolumeSliderScale(range: AppConstants.appVolumeRange, unity: AppConstants.unityAppVolume)
    private let systemScale = VolumeSliderScale(range: AppConstants.volumeRange, unity: nil)

    func testAppScalePutsUnityAtTwoThirdsOfTheTrack() {
        XCTAssertEqual(appScale.fraction(for: 0), 0)
        XCTAssertEqual(appScale.fraction(for: 50), 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(appScale.fraction(for: 100), 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(appScale.fraction(for: 150), 5.0 / 6.0, accuracy: 0.000_001)
        XCTAssertEqual(appScale.fraction(for: 200), 1)
    }

    func testAppScaleRoundTripsValuesThroughTheTrack() {
        for value in stride(from: 0.0, through: 200.0, by: 10) {
            XCTAssertEqual(appScale.value(for: appScale.fraction(for: value)), value, accuracy: 0.000_001)
        }
    }

    func testSystemScaleIsLinear() {
        XCTAssertEqual(systemScale.fraction(for: 63), 0.63, accuracy: 0.000_001)
        XCTAssertEqual(systemScale.value(for: 0.25), 25, accuracy: 0.000_001)
    }

    func testOutOfRangeInputsClamp() {
        XCTAssertEqual(appScale.fraction(for: 260), 1)
        XCTAssertEqual(appScale.fraction(for: -5), 0)
        XCTAssertEqual(appScale.value(for: 1.4), 200)
        XCTAssertEqual(appScale.value(for: -0.2), 0)
    }

    func testSettledValueRoundsAndSnapsToUnity() {
        XCTAssertEqual(appScale.settledValue(for: 42.4), 42)
        XCTAssertEqual(appScale.settledValue(for: 96.6), 100)
        XCTAssertEqual(appScale.settledValue(for: 103.9), 100)
        XCTAssertEqual(appScale.settledValue(for: 105), 105)
        XCTAssertEqual(appScale.settledValue(for: 250), 200)
        // No unity, no snap.
        XCTAssertEqual(systemScale.settledValue(for: 97), 97)
    }
}
