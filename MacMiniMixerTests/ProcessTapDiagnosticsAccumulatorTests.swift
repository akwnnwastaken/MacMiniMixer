import CoreAudio
import XCTest
@testable import MacMiniMixer

final class ProcessTapDiagnosticsAccumulatorTests: XCTestCase {
    func testObserveCountsCallbackAndComputesPeakAndRMS() {
        let accumulator = ProcessTapDiagnosticsAccumulator()
        observe([0.25, -0.5, 0.0, 1.0], with: accumulator)

        let snapshot = accumulator.snapshot()

        XCTAssertEqual(snapshot.callbackCount, 1)
        XCTAssertEqual(snapshot.measuredSampleCount, 4)
        XCTAssertEqual(snapshot.peakLevel, 1.0, accuracy: 0.000001)

        let expectedRMS = sqrt((0.25 * 0.25 + 0.5 * 0.5 + 1.0 * 1.0) / 4.0)
        XCTAssertEqual(snapshot.rmsLevel, expectedRMS, accuracy: 0.000001)
        XCTAssertTrue(snapshot.detectedNonSilentAudio)
    }

    func testObserveIgnoresNonFiniteSamples() {
        let accumulator = ProcessTapDiagnosticsAccumulator()
        observe([.nan, .infinity, -.infinity, -0.25], with: accumulator)

        let snapshot = accumulator.snapshot()

        XCTAssertEqual(snapshot.callbackCount, 1)
        XCTAssertEqual(snapshot.measuredSampleCount, 1)
        XCTAssertEqual(snapshot.peakLevel, 0.25, accuracy: 0.000001)
        XCTAssertEqual(snapshot.rmsLevel, 0.25, accuracy: 0.000001)
    }

    func testProgressUsesSnapshotMetrics() {
        let accumulator = ProcessTapDiagnosticsAccumulator()
        observe([0.002], with: accumulator)

        let progress = accumulator.snapshot().progress

        XCTAssertEqual(progress.callbackCount, 1)
        XCTAssertEqual(progress.peakLevel, 0.002, accuracy: 0.000001)
        XCTAssertEqual(progress.rmsLevel, 0.002, accuracy: 0.000001)
        XCTAssertTrue(progress.audioDetected)
    }

    private func observe(_ samples: [Float32], with accumulator: ProcessTapDiagnosticsAccumulator) {
        // Synthetic buffers keep these tests deterministic and avoid Process Tap permissions/devices.
        var mutableSamples = samples
        mutableSamples.withUnsafeMutableBufferPointer { sampleBuffer in
            var audioBuffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(sampleBuffer.count * MemoryLayout<Float32>.stride),
                mData: sampleBuffer.baseAddress
            )
            var audioBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
            withUnsafePointer(to: &audioBufferList) { inputData in
                accumulator.observe(inputData)
            }
        }
    }
}
