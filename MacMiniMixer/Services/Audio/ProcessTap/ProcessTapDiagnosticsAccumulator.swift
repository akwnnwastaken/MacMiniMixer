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
