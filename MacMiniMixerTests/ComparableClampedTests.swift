import XCTest
@testable import MacMiniMixer

final class ComparableClampedTests: XCTestCase {
    func testClampedReturnsValueInsideRange() {
        XCTAssertEqual(5.clamped(to: 0...10), 5)
    }

    func testClampedReturnsLowerBoundForLowValue() {
        XCTAssertEqual((-2).clamped(to: 0...10), 0)
    }

    func testClampedReturnsUpperBoundForHighValue() {
        XCTAssertEqual(12.clamped(to: 0...10), 10)
    }

    func testClampedWorksForFloatingPointValues() {
        XCTAssertEqual(1.25.clamped(to: 0.0...1.0), 1.0, accuracy: 0.000001)
        XCTAssertEqual(0.75.clamped(to: 0.0...1.0), 0.75, accuracy: 0.000001)
    }
}
