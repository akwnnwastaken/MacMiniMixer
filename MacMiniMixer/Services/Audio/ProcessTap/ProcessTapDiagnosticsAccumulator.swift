import CoreAudio
import Foundation

struct ProcessTapDiagnosticsSnapshot {
    let callbackCount: Int
    let measuredSampleCount: UInt64
    let peakLevel: Double
    let rmsLevel: Double

    var detectedNonSilentAudio: Bool {
        peakLevel > 0.001
    }

    var progress: ProcessTapDiagnosticProgress {
        ProcessTapDiagnosticProgress(
            callbackCount: callbackCount,
            peakLevel: peakLevel,
            rmsLevel: rmsLevel,
            audioDetected: detectedNonSilentAudio
        )
    }
}

final class ProcessTapDiagnosticsAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var callbackCount = 0
    private var measuredSampleCount: UInt64 = 0
    private var peakLevel: Double = 0
    private var sumOfSquares: Double = 0

    func observe(_ inputData: UnsafePointer<AudioBufferList>) {
        var localSampleCount: UInt64 = 0
        var localPeak: Double = 0
        var localSumOfSquares: Double = 0

        let mutableInputData = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
        for buffer in UnsafeMutableAudioBufferListPointer(mutableInputData) {
            guard let data = buffer.mData else {
                continue
            }

            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride
            guard sampleCount > 0 else {
                continue
            }

            let samples = data.assumingMemoryBound(to: Float32.self)
            for index in 0..<sampleCount {
                let sampleValue = Double(samples[index])
                guard sampleValue.isFinite else {
                    continue
                }

                let absoluteSample = abs(sampleValue)
                localPeak = max(localPeak, absoluteSample)
                localSumOfSquares += sampleValue * sampleValue
                localSampleCount += 1
            }
        }

        lock.lock()
        callbackCount += 1
        peakLevel = max(peakLevel, localPeak)
        sumOfSquares += localSumOfSquares
        measuredSampleCount += localSampleCount
        lock.unlock()
    }

    func snapshot() -> ProcessTapDiagnosticsSnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }

        let rmsLevel = measuredSampleCount > 0
            ? sqrt(sumOfSquares / Double(measuredSampleCount))
            : 0

        return ProcessTapDiagnosticsSnapshot(
            callbackCount: callbackCount,
            measuredSampleCount: measuredSampleCount,
            peakLevel: peakLevel,
            rmsLevel: rmsLevel
        )
    }
}

struct ProcessTapCallbackTimingSnapshot: Equatable {
    /// Largest observed wall-clock gap between two consecutive IOProc callbacks, in milliseconds.
    let maxCallbackGapMilliseconds: Double
    /// Number of inter-callback gaps that exceeded the conservative "late" threshold.
    let lateCallbackCount: Int
}

/// Diagnostic-only measurement of IOProc callback timing for the live replay path. The drop /
/// failure counters only catch an empty output buffer pool; they do not see callback scheduling
/// jitter (a stall between callbacks can cause an audible glitch with drops == 0). This tracks the
/// gap between consecutive callbacks using the host time the Core Audio IOProc already provides.
///
/// Realtime-safe: `record` does only integer arithmetic under a short lock — no allocation, no
/// logging. Separate from `ProcessTapDiagnosticsAccumulator` so the shared `observe` path (used by
/// probes and the tap test) is unchanged.
final class ProcessTapCallbackTimingAccumulator: @unchecked Sendable {
    /// Conservative absolute threshold for a "late" callback. Normal audio IOProc callbacks arrive
    /// every few milliseconds (well under this), so a gap beyond this strongly indicates a stall.
    /// It is deliberately *not* derived from the exact per-callback buffer interval (which varies
    /// with the tap's frame count), so it is a coarse stall signal rather than a precise jitter
    /// bound — interpret `lateCallbackCount > 0` as "investigate", not "definite glitch".
    static let lateThresholdNanoseconds: UInt64 = 50_000_000 // 50 ms

    private let lock = NSLock()
    private var hasPreviousHostTime = false
    private var previousHostTime: UInt64 = 0
    private var maxGapNanoseconds: UInt64 = 0
    private var lateCallbackCount = 0
    private let timebaseNumerator: UInt64
    private let timebaseDenominator: UInt64

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        timebaseNumerator = UInt64(timebase.numer == 0 ? 1 : timebase.numer)
        timebaseDenominator = UInt64(timebase.denom == 0 ? 1 : timebase.denom)
    }

    /// Records one IOProc callback at the given Core Audio host time (mach absolute time units).
    /// The first callback only seeds the baseline; the gap is measured from the second onward.
    func record(hostTime: UInt64) {
        lock.lock()
        if hasPreviousHostTime, hostTime > previousHostTime {
            let deltaHostTime = hostTime - previousHostTime
            let deltaNanoseconds = deltaHostTime * timebaseNumerator / timebaseDenominator
            if deltaNanoseconds > maxGapNanoseconds {
                maxGapNanoseconds = deltaNanoseconds
            }
            if deltaNanoseconds > Self.lateThresholdNanoseconds {
                lateCallbackCount += 1
            }
        }
        previousHostTime = hostTime
        hasPreviousHostTime = true
        lock.unlock()
    }

    func snapshot() -> ProcessTapCallbackTimingSnapshot {
        lock.lock()
        defer {
            lock.unlock()
        }

        return ProcessTapCallbackTimingSnapshot(
            maxCallbackGapMilliseconds: Double(maxGapNanoseconds) / 1_000_000,
            lateCallbackCount: lateCallbackCount
        )
    }
}

/// Rate-limits how often live diagnostics are published to the UI. The audio path keeps measuring
/// on every callback and the diagnostics timer keeps ticking; this only throttles the SwiftUI-facing
/// refresh so a 10 Hz tick (× N sessions) does not redraw the panel that often. A sample is published
/// when it is the first one, when `force` is set (start/stop/final), or when failures/output
/// starvation escalated since the last publish — otherwise it is limited to the minimum interval, so
/// no failure/drop/starvation event is ever dropped, only routine level/timing redraws are coalesced.
/// The clock is injectable so this is unit-testable without sleeping.
final class ProcessTapDiagnosticsPublishGate: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumIntervalNanoseconds: UInt64
    private let now: @Sendable () -> UInt64
    private var hasPublished = false
    private var lastPublishTime: UInt64 = 0
    private var lastFailureCount = 0
    private var lastStarvationCount = 0

    init(
        minimumIntervalMilliseconds: Double = AppConstants.processTapLiveDiagnosticsPublishMinimumIntervalMilliseconds,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.minimumIntervalNanoseconds = UInt64(max(0, minimumIntervalMilliseconds) * 1_000_000)
        self.now = now
    }

    func shouldPublish(_ diagnostics: ProcessTapLiveDiagnostics, force: Bool) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        let escalated = diagnostics.totalFailureCount > lastFailureCount
            || diagnostics.outputStarvationCount > lastStarvationCount
        let current = now()
        let elapsed = (hasPublished && current >= lastPublishTime) ? current - lastPublishTime : UInt64.max
        let allow = force || !hasPublished || escalated || elapsed >= minimumIntervalNanoseconds

        if allow {
            hasPublished = true
            lastPublishTime = current
            lastFailureCount = diagnostics.totalFailureCount
            lastStarvationCount = diagnostics.outputStarvationCount
        }
        return allow
    }
}
