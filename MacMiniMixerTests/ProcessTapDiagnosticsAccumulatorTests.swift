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

    // MARK: - Callback jitter accumulator (Phase 6c)

    func testTimingAccumulatorNormalCadenceHasNoLateCallbacks() {
        let accumulator = ProcessTapCallbackTimingAccumulator()
        var hostTime: UInt64 = 1_000_000
        accumulator.record(hostTime: hostTime) // first callback only seeds the baseline
        for _ in 0..<5 {
            hostTime += hostTicks(forMilliseconds: 10)
            accumulator.record(hostTime: hostTime)
        }

        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot.lateCallbackCount, 0)
        XCTAssertEqual(snapshot.maxCallbackGapMilliseconds, 10, accuracy: 1.0)
    }

    func testTimingAccumulatorOneLargeGapCountsOneLateAndUpdatesMax() {
        let accumulator = ProcessTapCallbackTimingAccumulator()
        var hostTime: UInt64 = 1_000_000
        accumulator.record(hostTime: hostTime)
        hostTime += hostTicks(forMilliseconds: 10)
        accumulator.record(hostTime: hostTime)  // normal (< 50 ms)
        hostTime += hostTicks(forMilliseconds: 100)
        accumulator.record(hostTime: hostTime)  // late (> 50 ms)

        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot.lateCallbackCount, 1)
        XCTAssertEqual(snapshot.maxCallbackGapMilliseconds, 100, accuracy: 2.0)
    }

    func testTimingAccumulatorMultipleLargeGapsAccumulateLateAndKeepMax() {
        let accumulator = ProcessTapCallbackTimingAccumulator()
        var hostTime: UInt64 = 1_000_000
        accumulator.record(hostTime: hostTime)
        hostTime += hostTicks(forMilliseconds: 120)
        accumulator.record(hostTime: hostTime)  // late, max 120
        hostTime += hostTicks(forMilliseconds: 10)
        accumulator.record(hostTime: hostTime)  // normal
        hostTime += hostTicks(forMilliseconds: 80)
        accumulator.record(hostTime: hostTime)  // late, max stays 120

        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot.lateCallbackCount, 2)
        XCTAssertEqual(snapshot.maxCallbackGapMilliseconds, 120, accuracy: 2.0)
    }

    func testTimingAccumulatorFirstCallbackProducesNoGap() {
        let accumulator = ProcessTapCallbackTimingAccumulator()
        accumulator.record(hostTime: 5_000_000)

        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot.lateCallbackCount, 0)
        XCTAssertEqual(snapshot.maxCallbackGapMilliseconds, 0, accuracy: 0.0001)
    }

    // MARK: - Diagnostics forwarding of timing/starvation fields (Phase 6c)

    func testLiveDiagnosticsDefaultsTimingAndStarvationToZero() {
        let diagnostics = ProcessTapLiveDiagnostics(
            selectedGain: ProcessTapReplayGainOption.options[0],
            callbackCount: 1,
            peakLevel: 0,
            rmsLevel: 0,
            enqueuedBufferCount: 0,
            droppedBufferCount: 0,
            enqueueFailureCount: 0,
            copyFailureCount: 0
        )

        XCTAssertEqual(diagnostics.maxCallbackGapMilliseconds, 0)
        XCTAssertEqual(diagnostics.lateCallbackCount, 0)
        XCTAssertEqual(diagnostics.outputStarvationCount, 0)
    }

    func testLiveDiagnosticsCarriesTimingAndStarvationFields() {
        let diagnostics = ProcessTapLiveDiagnostics(
            selectedGain: ProcessTapReplayGainOption.options[0],
            callbackCount: 1,
            peakLevel: 0,
            rmsLevel: 0,
            enqueuedBufferCount: 0,
            droppedBufferCount: 0,
            enqueueFailureCount: 0,
            copyFailureCount: 0,
            maxCallbackGapMilliseconds: 12.5,
            lateCallbackCount: 3,
            outputStarvationCount: 2
        )

        XCTAssertEqual(diagnostics.maxCallbackGapMilliseconds, 12.5, accuracy: 0.0001)
        XCTAssertEqual(diagnostics.lateCallbackCount, 3)
        XCTAssertEqual(diagnostics.outputStarvationCount, 2)
    }

    func testLiveDiagnosticsTimingSummaryTextFormat() {
        let diagnostics = ProcessTapLiveDiagnostics(
            selectedGain: ProcessTapReplayGainOption.options[0],
            callbackCount: 1,
            peakLevel: 0,
            rmsLevel: 0,
            enqueuedBufferCount: 0,
            droppedBufferCount: 0,
            enqueueFailureCount: 0,
            copyFailureCount: 0,
            maxCallbackGapMilliseconds: 12.34,
            lateCallbackCount: 0,
            outputStarvationCount: 0
        )

        XCTAssertEqual(diagnostics.timingSummaryText, "Gap 12.3ms · Late 0 · Starv 0")
    }

    private func hostTicks(forMilliseconds milliseconds: Double) -> UInt64 {
        // Convert a wall-clock millisecond span into mach host-time ticks using the same timebase
        // the accumulator uses, so these tests are deterministic regardless of CPU architecture.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let numerator = UInt64(timebase.numer == 0 ? 1 : timebase.numer)
        let denominator = UInt64(timebase.denom == 0 ? 1 : timebase.denom)
        let nanoseconds = UInt64(milliseconds * 1_000_000)
        return nanoseconds * denominator / numerator
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
