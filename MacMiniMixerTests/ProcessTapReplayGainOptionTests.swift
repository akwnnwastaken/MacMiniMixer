import XCTest
@testable import MacMiniMixer

final class ProcessTapReplayGainOptionTests: XCTestCase {
    func testOptionsExposeStableLabelsIDsAndScalars() {
        let options = ProcessTapReplayGainOption.options

        XCTAssertEqual(options.map(\.label), ["25%", "50%", "75%", "100%"])
        XCTAssertEqual(options.map(\.id), ["25%", "50%", "75%", "100%"])
        XCTAssertEqual(options.map(\.percentLabel), ["25%", "50%", "75%", "100%"])
        XCTAssertEqual(options.map(\.scalar), [0.25, 0.5, 0.75, 1.0])
    }

    func testDefaultOptionIsFiftyPercent() {
        XCTAssertEqual(ProcessTapReplayGainOption.defaultOption.label, "50%")
        XCTAssertEqual(ProcessTapReplayGainOption.defaultOption.id, "50%")
        XCTAssertEqual(ProcessTapReplayGainOption.defaultOption.scalar, 0.5)
    }
}
