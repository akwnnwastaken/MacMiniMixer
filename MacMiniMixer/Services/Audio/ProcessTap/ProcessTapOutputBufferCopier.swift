import AudioToolbox
import CoreAudio
import Foundation

struct ProcessTapOutputBufferCopyResult: Equatable {
    let frameCount: Int
    let outputByteSize: UInt32
}

protocol ProcessTapOutputFrameGainProviding {
    mutating func gain(forFrame frame: Int) -> Float
}

struct ProcessTapConstantFrameGainProvider: ProcessTapOutputFrameGainProviding {
    let gain: Float

    mutating func gain(forFrame frame: Int) -> Float {
        gain
    }
}

enum ProcessTapOutputBufferCopier {
    static func copy(
        _ inputData: UnsafePointer<AudioBufferList>,
        into outputSamples: UnsafeMutablePointer<Float32>,
        outputByteCapacity: UInt32,
        outputChannelCount: Int,
        gain: Float
    ) -> ProcessTapOutputBufferCopyResult? {
        var gainProvider = ProcessTapConstantFrameGainProvider(gain: gain)
        return copy(
            inputData,
            into: outputSamples,
            outputByteCapacity: outputByteCapacity,
            outputChannelCount: outputChannelCount,
            gainProvider: &gainProvider
        )
    }

    static func copy<GainProvider: ProcessTapOutputFrameGainProviding>(
        _ inputData: UnsafePointer<AudioBufferList>,
        into outputSamples: UnsafeMutablePointer<Float32>,
        outputByteCapacity: UInt32,
        outputChannelCount: Int,
        gainProvider: inout GainProvider
    ) -> ProcessTapOutputBufferCopyResult? {
        guard outputChannelCount > 0 else {
            return nil
        }

        let mutableInputData = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
        let inputBuffers = UnsafeMutableAudioBufferListPointer(mutableInputData)
        guard !inputBuffers.isEmpty else {
            return nil
        }

        let maxFrames = Int(outputByteCapacity) / (MemoryLayout<Float32>.stride * outputChannelCount)
        guard maxFrames > 0 else {
            return nil
        }

        let frameCount = min(maxFrames, frameCount(in: inputBuffers))
        guard frameCount > 0 else {
            return nil
        }

        if inputBuffers.count == 1 {
            copyInterleavedInput(
                inputBuffers[0],
                into: outputSamples,
                frameCount: frameCount,
                outputChannelCount: outputChannelCount,
                gainProvider: &gainProvider
            )
        } else {
            copyPlanarInput(
                inputBuffers,
                into: outputSamples,
                frameCount: frameCount,
                outputChannelCount: outputChannelCount,
                gainProvider: &gainProvider
            )
        }

        return ProcessTapOutputBufferCopyResult(
            frameCount: frameCount,
            outputByteSize: UInt32(frameCount * outputChannelCount * MemoryLayout<Float32>.stride)
        )
    }

    private static func frameCount(in inputBuffers: UnsafeMutableAudioBufferListPointer) -> Int {
        if inputBuffers.count == 1 {
            let channelCount = max(1, Int(inputBuffers[0].mNumberChannels))
            return Int(inputBuffers[0].mDataByteSize) / (MemoryLayout<Float32>.stride * channelCount)
        }

        return inputBuffers.reduce(Int.max) { partialResult, buffer in
            min(partialResult, Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride)
        }
    }

    private static func copyInterleavedInput<GainProvider: ProcessTapOutputFrameGainProviding>(
        _ inputBuffer: AudioBuffer,
        into outputSamples: UnsafeMutablePointer<Float32>,
        frameCount: Int,
        outputChannelCount: Int,
        gainProvider: inout GainProvider
    ) {
        guard let inputData = inputBuffer.mData else {
            return
        }

        let inputChannelCount = max(1, Int(inputBuffer.mNumberChannels))
        let inputSamples = inputData.assumingMemoryBound(to: Float32.self)

        for frame in 0..<frameCount {
            let frameGain = gainProvider.gain(forFrame: frame)
            for outputChannel in 0..<outputChannelCount {
                let inputChannel = min(outputChannel, inputChannelCount - 1)
                outputSamples[(frame * outputChannelCount) + outputChannel] =
                    inputSamples[(frame * inputChannelCount) + inputChannel] * frameGain
            }
        }
    }

    private static func copyPlanarInput<GainProvider: ProcessTapOutputFrameGainProviding>(
        _ inputBuffers: UnsafeMutableAudioBufferListPointer,
        into outputSamples: UnsafeMutablePointer<Float32>,
        frameCount: Int,
        outputChannelCount: Int,
        gainProvider: inout GainProvider
    ) {
        for frame in 0..<frameCount {
            let frameGain = gainProvider.gain(forFrame: frame)
            for outputChannel in 0..<outputChannelCount {
                let inputBuffer = inputBuffers[min(outputChannel, inputBuffers.count - 1)]
                guard let inputData = inputBuffer.mData else {
                    outputSamples[(frame * outputChannelCount) + outputChannel] = 0
                    continue
                }

                let inputSamples = inputData.assumingMemoryBound(to: Float32.self)
                outputSamples[(frame * outputChannelCount) + outputChannel] = inputSamples[frame] * frameGain
            }
        }
    }
}

struct ProcessTapDirectOutputRenderResult: Equatable {
    /// Frames rendered per output channel this cycle (the IOProc's output buffer length). The gain
    /// provider is advanced exactly once per output frame, so ramps follow device time.
    let outputFrameCount: Int
    /// Leading frames that carried tap input; the rest of the cycle was written as silence.
    let inputFrameCount: Int
}

/// Pure render step of the direct aggregate output path (live mode `.directAggregateOutput`):
/// copies one IOProc's tap input into the same IOProc's output buffers.
///
/// - Every output buffer is zeroed first, so no channel or frame is ever left with stale data:
///   missing/short input, extra output channels (3+), disabled streams and tails are silence.
/// - Input and output may each be interleaved (one buffer, N channels) or non-interleaved / multi
///   stream (several buffers); channels are addressed by their global index across buffers.
/// - Mapping: stereo→stereo, mono→both of the first two output channels, stereo→mono averages
///   L and R. Non-finite input samples are written as silence.
///
/// Real-time safe: no allocation, locks, logging or array growth — pointer arithmetic only.
enum ProcessTapDirectOutputCopier {
    static func render<GainProvider: ProcessTapOutputFrameGainProviding>(
        _ inputData: UnsafePointer<AudioBufferList>,
        into outputData: UnsafeMutablePointer<AudioBufferList>,
        gainProvider: inout GainProvider
    ) -> ProcessTapDirectOutputRenderResult {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        var outputFrameCount = 0
        for buffer in outputBuffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
                continue
            }

            memset(data, 0, Int(buffer.mDataByteSize))
            let bufferChannelCount = max(1, Int(buffer.mNumberChannels))
            outputFrameCount = max(
                outputFrameCount,
                Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.stride * bufferChannelCount)
            )
        }

        let outputChannelCount = channelCount(in: outputBuffers)
        guard outputChannelCount > 0, outputFrameCount > 0 else {
            return ProcessTapDirectOutputRenderResult(outputFrameCount: 0, inputFrameCount: 0)
        }

        let inputBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
        )
        let inputChannelCount = channelCount(in: inputBuffers)
        let hasStereoInput = inputChannelCount > 1
        let inputLeft = channel(0, in: inputBuffers)
        let inputRight = hasStereoInput ? channel(1, in: inputBuffers) : inputLeft
        let inputFrameCount = min(
            outputFrameCount,
            max(inputLeft.frameCount, inputRight.frameCount)
        )

        let outputLeft = channel(0, in: outputBuffers)
        let outputRight = channel(1, in: outputBuffers)
        let isMonoOutput = outputChannelCount == 1

        for frame in 0..<outputFrameCount {
            // Advance the gain for every output frame (even silent ones) so fades track device time.
            let frameGain = gainProvider.gain(forFrame: frame)
            guard frame < inputFrameCount else {
                continue
            }

            let leftSample = inputLeft.sample(at: frame)
            let rightSample = hasStereoInput ? inputRight.sample(at: frame) : leftSample
            if isMonoOutput {
                let monoSample = hasStereoInput ? (leftSample + rightSample) * 0.5 : leftSample
                outputLeft.write(monoSample * frameGain, at: frame)
            } else {
                outputLeft.write(leftSample * frameGain, at: frame)
                outputRight.write(rightSample * frameGain, at: frame)
            }
        }

        return ProcessTapDirectOutputRenderResult(
            outputFrameCount: outputFrameCount,
            inputFrameCount: inputFrameCount
        )
    }

    /// Rates closer than this (Hz) count as equal: copied frame-for-frame, no conversion.
    static let sampleRateMatchTolerance: Double = 0.5
    /// Largest tap/output (or output/tap) rate ratio the direct path converts.
    static let maximumSampleRateRatio: Double = 8

    /// Why the aggregate's tap input / device output formats cannot be rendered directly (the
    /// caller then falls back to the AudioQueue path), or nil when they can. Equal rates are copied
    /// frame-for-frame; differing rates are accepted only when `allowsSampleRateConversion` (the
    /// renderer then converts through `ProcessTapDirectOutputResampler`).
    static func formatIncompatibility(
        input: AudioStreamBasicDescription,
        output: AudioStreamBasicDescription,
        allowsSampleRateConversion: Bool = true
    ) -> String? {
        guard ProcessTapCoreAudio.isSupportedFloatPCMMonoOrStereo(input) else {
            return "unsupported tap format (channels \(input.mChannelsPerFrame), bits \(input.mBitsPerChannel))"
        }

        let isFloatOutput = output.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard output.mFormatID == kAudioFormatLinearPCM,
              isFloatOutput,
              output.mBitsPerChannel == 32,
              output.mChannelsPerFrame >= 1 else {
            return "unsupported output format (channels \(output.mChannelsPerFrame), bits \(output.mBitsPerChannel))"
        }

        guard input.mSampleRate > 0, output.mSampleRate > 0 else {
            return "invalid sample rate (tap \(input.mSampleRate) Hz, output \(output.mSampleRate) Hz)"
        }

        guard requiresSampleRateConversion(input: input, output: output) else {
            return nil
        }

        guard allowsSampleRateConversion else {
            return "sample rate mismatch (tap \(input.mSampleRate) Hz, output \(output.mSampleRate) Hz)"
        }

        let ratio = input.mSampleRate / output.mSampleRate
        guard ratio <= maximumSampleRateRatio, ratio >= 1 / maximumSampleRateRatio else {
            return "unsupported sample rate ratio (tap \(input.mSampleRate) Hz, output \(output.mSampleRate) Hz)"
        }

        return nil
    }

    /// Whether the tap and output rates differ enough that the direct path must convert.
    static func requiresSampleRateConversion(
        input: AudioStreamBasicDescription,
        output: AudioStreamBasicDescription
    ) -> Bool {
        abs(input.mSampleRate - output.mSampleRate) >= sampleRateMatchTolerance
    }

    /// Frames per channel the IOProc expects in `outputData` this cycle — the count `render` uses.
    static func outputFrameCount(in outputData: UnsafeMutablePointer<AudioBufferList>) -> Int {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard channelCount(in: outputBuffers) > 0 else {
            return 0
        }

        var outputFrameCount = 0
        for buffer in outputBuffers {
            guard buffer.mData != nil, buffer.mDataByteSize > 0 else {
                continue
            }

            let bufferChannelCount = max(1, Int(buffer.mNumberChannels))
            outputFrameCount = max(
                outputFrameCount,
                Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.stride * bufferChannelCount)
            )
        }
        return outputFrameCount
    }

    /// Zeroes every output buffer without touching any gain provider (so a fade-in has not started
    /// yet). Used while the resampler is still filling up at session start. Real-time safe.
    static func renderSilence(
        into outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> ProcessTapDirectOutputRenderResult {
        for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
                continue
            }

            memset(data, 0, Int(buffer.mDataByteSize))
        }

        return ProcessTapDirectOutputRenderResult(
            outputFrameCount: outputFrameCount(in: outputData),
            inputFrameCount: 0
        )
    }

    fileprivate static func channelCount(in buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        var count = 0
        for buffer in buffers {
            count += Int(buffer.mNumberChannels)
        }
        return count
    }

    /// Locates global channel `index` across `buffers` (each interleaving `mNumberChannels`).
    fileprivate static func channel(
        _ index: Int,
        in buffers: UnsafeMutableAudioBufferListPointer
    ) -> ProcessTapDirectOutputChannel {
        var firstChannelOfBuffer = 0
        for buffer in buffers {
            let bufferChannelCount = Int(buffer.mNumberChannels)
            guard bufferChannelCount > 0 else {
                continue
            }

            if index < firstChannelOfBuffer + bufferChannelCount {
                guard let data = buffer.mData else {
                    return ProcessTapDirectOutputChannel(samples: nil, stride: 1, frameCount: 0)
                }

                return ProcessTapDirectOutputChannel(
                    samples: data.assumingMemoryBound(to: Float32.self) + (index - firstChannelOfBuffer),
                    stride: bufferChannelCount,
                    frameCount: Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.stride * bufferChannelCount)
                )
            }

            firstChannelOfBuffer += bufferChannelCount
        }

        return ProcessTapDirectOutputChannel(samples: nil, stride: 1, frameCount: 0)
    }
}

/// One channel inside an AudioBufferList: its first sample, interleave stride and frame count.
/// A missing channel (`samples == nil`) reads as silence and ignores writes.
private struct ProcessTapDirectOutputChannel {
    let samples: UnsafeMutablePointer<Float32>?
    let stride: Int
    let frameCount: Int

    func sample(at frame: Int) -> Float32 {
        guard let samples, frame < frameCount else {
            return 0
        }

        let value = samples[frame * stride]
        return value.isFinite ? value : 0
    }

    func write(_ value: Float32, at frame: Int) {
        guard let samples, frame < frameCount else {
            return
        }

        samples[frame * stride] = value
    }
}

/// Preallocated FIFO of interleaved Float32 frames (1 or 2 channels) between the tap input and the
/// sample-rate converter of the direct output path. Producer (`push`) and consumer (`pull`) both run
/// on the IOProc thread, one after the other, so it needs no synchronisation.
///
/// Real-time safe: storage is allocated once in `init`; push/pull/discard are index arithmetic and
/// memcpy only. On overflow the oldest frames are dropped (and counted) so the newest audio is kept;
/// a pull asking for more frames than are queued returns only the queued ones.
final class ProcessTapDirectOutputFrameFIFO {
    let channelCount: Int
    let capacityFrames: Int
    /// Pushes that had to drop frames (the oldest queued ones, or the start of an oversized push).
    private(set) var overflowCount = 0
    private(set) var droppedFrameCount = 0
    private(set) var availableFrames = 0

    private let storage: UnsafeMutablePointer<Float32>
    private var readFrame = 0

    init(channelCount: Int, capacityFrames: Int) {
        self.channelCount = min(2, max(1, channelCount))
        self.capacityFrames = max(1, capacityFrames)
        let sampleCapacity = self.capacityFrames * self.channelCount
        storage = UnsafeMutablePointer<Float32>.allocate(capacity: sampleCapacity)
        storage.initialize(repeating: 0, count: sampleCapacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Tap frames actually delivered in `inputData`: each buffer's `mDataByteSize` / bytes per frame
    /// (the largest buffer for non-interleaved input) — independent of the IOProc's output length.
    static func deliveredFrameCount(in inputData: UnsafePointer<AudioBufferList>) -> Int {
        var frameCount = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData)) {
            let bufferChannelCount = max(1, Int(buffer.mNumberChannels))
            frameCount = max(
                frameCount,
                Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.stride * bufferChannelCount)
            )
        }
        return frameCount
    }

    /// Appends `frameCount` frames of `inputData` (interleaved or non-interleaved; mono input fills
    /// both channels of a stereo FIFO). Missing, short or non-finite input is queued as silence.
    func push(_ inputData: UnsafePointer<AudioBufferList>, frameCount: Int) {
        guard frameCount > 0 else {
            return
        }

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let first = ProcessTapDirectOutputCopier.channel(0, in: inputBuffers)
        let second = ProcessTapDirectOutputCopier.channelCount(in: inputBuffers) > 1
            ? ProcessTapDirectOutputCopier.channel(1, in: inputBuffers)
            : first

        let skippedFrames = makeRoom(forFrameCount: frameCount)
        var writeFrame = (readFrame + availableFrames) % capacityFrames
        for frame in skippedFrames..<frameCount {
            let sampleIndex = writeFrame * channelCount
            storage[sampleIndex] = first.sample(at: frame)
            if channelCount > 1 {
                storage[sampleIndex + 1] = second.sample(at: frame)
            }

            writeFrame += 1
            if writeFrame == capacityFrames {
                writeFrame = 0
            }
        }
        availableFrames += frameCount - skippedFrames
    }

    /// Appends `frameCount` silent frames.
    func pushSilence(frameCount: Int) {
        guard frameCount > 0 else {
            return
        }

        let skippedFrames = makeRoom(forFrameCount: frameCount)
        var writeFrame = (readFrame + availableFrames) % capacityFrames
        for _ in skippedFrames..<frameCount {
            let sampleIndex = writeFrame * channelCount
            for channel in 0..<channelCount {
                storage[sampleIndex + channel] = 0
            }

            writeFrame += 1
            if writeFrame == capacityFrames {
                writeFrame = 0
            }
        }
        availableFrames += frameCount - skippedFrames
    }

    /// Moves up to `maxFrames` of the oldest frames (interleaved) into `destination`, which must
    /// hold that many frames, and returns how many were moved.
    @discardableResult
    func pull(into destination: UnsafeMutablePointer<Float32>, maxFrames: Int) -> Int {
        let frameCount = min(max(0, maxFrames), availableFrames)
        guard frameCount > 0 else {
            return 0
        }

        let bytesPerFrame = channelCount * MemoryLayout<Float32>.stride
        let firstSegmentFrames = min(frameCount, capacityFrames - readFrame)
        memcpy(destination, storage + readFrame * channelCount, firstSegmentFrames * bytesPerFrame)
        if frameCount > firstSegmentFrames {
            memcpy(
                destination + firstSegmentFrames * channelCount,
                storage,
                (frameCount - firstSegmentFrames) * bytesPerFrame
            )
        }

        discardOldest(frameCount)
        return frameCount
    }

    /// Drops up to `frameCount` of the oldest queued frames (not counted as an overflow).
    func discardOldest(_ frameCount: Int) {
        let discardedFrames = min(max(0, frameCount), availableFrames)
        readFrame = (readFrame + discardedFrames) % capacityFrames
        availableFrames -= discardedFrames
    }

    func removeAll() {
        readFrame = 0
        availableFrames = 0
    }

    /// Drops the oldest queued frames so `frameCount` more fit (one overflow), and returns how many
    /// leading frames of a push larger than the whole FIFO must be skipped (newest audio wins).
    private func makeRoom(forFrameCount frameCount: Int) -> Int {
        let skippedFrames = max(0, frameCount - capacityFrames)
        let excessFrames = max(0, availableFrames + (frameCount - skippedFrames) - capacityFrames)
        if skippedFrames > 0 || excessFrames > 0 {
            overflowCount += 1
            droppedFrameCount += skippedFrames + excessFrames
            discardOldest(excessFrames)
        }
        return skippedFrames
    }
}

/// How the direct path's resampler renders, decided from the first tap cycles that carry frames.
enum ProcessTapDirectResamplePath: String, Equatable, Sendable {
    /// First cycles: tap frames are queued while measuring how many arrive per output cycle.
    case detecting
    /// The tap arrives at its own rate: frames are converted through the AudioConverter.
    case converting
    /// The HAL already delivers one tap frame per output frame (it resampled the tap itself), so
    /// frames are copied one-for-one like the equal-rate path.
    case passthrough
}

/// Diagnostics of `ProcessTapDirectOutputResampler`, published from the IOProc via a try-lock.
struct ProcessTapDirectResampleSnapshot: Equatable, Sendable {
    let inputSampleRate: Double
    let outputSampleRate: Double
    var path: ProcessTapDirectResamplePath = .detecting
    /// IOProc cycles seen, and the tap / output frames they carried.
    var cycleCount = 0
    var totalInputFrames = 0
    var totalOutputFrames = 0
    /// Cycles that could not convert their full output length (the rest was rendered silent).
    var underrunCount = 0
    /// FIFO pushes that dropped the oldest queued frames.
    var overflowCount = 0

    var averageInputFramesPerCycle: Double {
        cycleCount > 0 ? Double(totalInputFrames) / Double(cycleCount) : 0
    }

    var averageOutputFramesPerCycle: Double {
        cycleCount > 0 ? Double(totalOutputFrames) / Double(cycleCount) : 0
    }

    /// Measured tap frames per output frame: ≈ `expectedRatio` when the HAL hands the tap over at
    /// its own rate, ≈ 1 when it already resampled it to the output rate.
    var measuredRatio: Double {
        totalOutputFrames > 0 ? Double(totalInputFrames) / Double(totalOutputFrames) : 0
    }

    var expectedRatio: Double {
        outputSampleRate > 0 ? inputSampleRate / outputSampleRate : 0
    }
}

/// Sample-rate conversion stage of the direct aggregate output path, for a tap whose reported rate
/// differs from the output device's (e.g. tap 48 kHz, built-in speakers at 44.1 kHz). Both run on
/// the aggregate's clock, so this is a fixed ratio; a small FIFO absorbs per-cycle jitter.
///
/// Per IOProc cycle (`process`): the tap frames actually delivered (from `mDataByteSize`) go into the
/// FIFO, then exactly the output frame count is pulled through an `AudioConverter` (Float32, tap
/// channel layout; the existing copier maps it to the device channels and applies gain/fade).
/// Conversion starts once this cycle's input plus ≈ one IO cycle is queued. A FIFO underrun renders
/// the missing frames silent, is counted, and refills to that target; an overflow drops the oldest
/// frames and is counted. If the first cycles show one tap frame per output frame (the HAL already
/// resampled the tap), frames are passed through unconverted instead.
///
/// The converter, FIFO and buffers are created — and the converter warmed up — in `init`, off the
/// audio thread. `process` runs only in the IOProc (called serially): no allocation, blocking lock,
/// logging or array growth; diagnostics are published with a non-blocking try-lock.
final class ProcessTapDirectOutputResampler: @unchecked Sendable {
    /// Converted-output capacity per cycle when the device's IO buffer size is small or unknown.
    static let minimumOutputFrameCapacity = 4096
    /// Tap cycles (that carry frames) observed before choosing between converting and passthrough.
    static let detectionCycleCount = 3
    /// FIFO capacity, in IO cycles of the largest supported cycle.
    static let fifoCapacityCycles = 4
    /// Returned by the converter input proc when the FIFO is empty: the converter stops, returns
    /// what it has produced, and keeps its state for the next cycle.
    private static var fifoEmptyStatus: OSStatus {
        0x4D4D_4645 // 'MMFE'
    }

    let inputSampleRate: Double
    let outputSampleRate: Double
    let channelCount: Int
    let maxOutputFramesPerCycle: Int
    /// Tap frames waiting for conversion (IOProc only; internal for tests).
    let fifo: ProcessTapDirectOutputFrameFIFO

    private let ratio: Double
    private let converter: AudioConverterRef
    private let inputStaging: UnsafeMutablePointer<Float32>
    private let convertedSamples: UnsafeMutablePointer<Float32>
    private let convertedList: UnsafeMutablePointer<AudioBufferList>

    // IOProc only.
    private var stats: ProcessTapDirectResampleSnapshot
    private var detectionCycles = 0
    private var matchingDetectionCycles = 0
    private var isPrimed = false
    private var hasStartedOutput = false

    private let statsLock = NSLock()
    // Guarded by `statsLock`.
    private var publishedStats: ProcessTapDirectResampleSnapshot

    /// Nil when the rates are equal (no conversion needed), invalid, the channel count is not 1–2,
    /// or the converter cannot be created.
    init?(
        inputSampleRate: Double,
        outputSampleRate: Double,
        channelCount: Int,
        maxOutputFramesPerCycle: Int
    ) {
        guard inputSampleRate > 0,
              outputSampleRate > 0,
              abs(inputSampleRate - outputSampleRate) >= ProcessTapDirectOutputCopier.sampleRateMatchTolerance,
              channelCount >= 1,
              channelCount <= 2,
              maxOutputFramesPerCycle > 0 else {
            return nil
        }

        var sourceFormat = ProcessTapDirectOutputResampler.interleavedFloatFormat(
            sampleRate: inputSampleRate,
            channelCount: channelCount
        )
        var destinationFormat = ProcessTapDirectOutputResampler.interleavedFloatFormat(
            sampleRate: outputSampleRate,
            channelCount: channelCount
        )
        var newConverter: AudioConverterRef?
        guard AudioConverterNew(&sourceFormat, &destinationFormat, &newConverter) == noErr,
              let createdConverter = newConverter else {
            return nil
        }

        // Latency mode: the converter never asks for extra leading input (it treats the history
        // before the first frame as silence), so it consumes tap frames at exactly the rate ratio.
        var primeMethod = UInt32(kConverterPrimeMethod_None)
        _ = AudioConverterSetProperty(
            createdConverter,
            kAudioConverterPrimeMethod,
            UInt32(MemoryLayout<UInt32>.size),
            &primeMethod
        )

        let ratio = inputSampleRate / outputSampleRate
        let maxInputFramesPerCycle = Int((Double(maxOutputFramesPerCycle) * ratio).rounded(.up))
        let fifo = ProcessTapDirectOutputFrameFIFO(
            channelCount: channelCount,
            capacityFrames: maxInputFramesPerCycle * ProcessTapDirectOutputResampler.fifoCapacityCycles
        )

        let stagingSampleCount = fifo.capacityFrames * channelCount
        let inputStaging = UnsafeMutablePointer<Float32>.allocate(capacity: stagingSampleCount)
        inputStaging.initialize(repeating: 0, count: stagingSampleCount)

        let convertedSampleCount = maxOutputFramesPerCycle * channelCount
        let convertedSamples = UnsafeMutablePointer<Float32>.allocate(capacity: convertedSampleCount)
        convertedSamples.initialize(repeating: 0, count: convertedSampleCount)

        let convertedList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        convertedList.initialize(to: AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channelCount),
                mDataByteSize: 0,
                mData: UnsafeMutableRawPointer(convertedSamples)
            )
        ))

        let initialStats = ProcessTapDirectResampleSnapshot(
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate
        )

        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.channelCount = channelCount
        self.maxOutputFramesPerCycle = maxOutputFramesPerCycle
        self.fifo = fifo
        self.ratio = ratio
        self.converter = createdConverter
        self.inputStaging = inputStaging
        self.convertedSamples = convertedSamples
        self.convertedList = convertedList
        self.stats = initialStats
        self.publishedStats = initialStats

        warmUp()
    }

    deinit {
        _ = AudioConverterDispose(converter)
        inputStaging.deallocate()
        convertedSamples.deallocate()
        convertedList.deallocate()
    }

    /// The converted buffer (one interleaved buffer, `channelCount` channels); its `mDataByteSize`
    /// covers the frames produced by the last `convert` / `process`.
    var convertedBufferList: UnsafePointer<AudioBufferList> {
        UnsafePointer(convertedList)
    }

    func snapshot() -> ProcessTapDirectResampleSnapshot {
        statsLock.lock()
        defer {
            statsLock.unlock()
        }

        return publishedStats
    }

    /// IOProc only. Queues this cycle's tap frames and returns what to render this cycle:
    /// - nil before the first audio (start-up detection / prefill): the caller writes silence
    ///   without starting its fade-in;
    /// - `inputData` itself once the HAL proved to deliver one tap frame per output frame;
    /// - otherwise `convertedBufferList`, holding `outputFrameCount` frames, or fewer after an
    ///   underrun or while refilling — the caller renders the rest as silence.
    func process(
        _ inputData: UnsafePointer<AudioBufferList>,
        outputFrameCount: Int
    ) -> UnsafePointer<AudioBufferList>? {
        let deliveredFrames = ProcessTapDirectOutputFrameFIFO.deliveredFrameCount(in: inputData)
        stats.cycleCount += 1
        stats.totalInputFrames += deliveredFrames
        stats.totalOutputFrames += max(0, outputFrameCount)
        defer {
            publishStats()
        }

        if stats.path == .detecting, deliveredFrames > 0, outputFrameCount > 0 {
            detectionCycles += 1
            if deliveredFrames == outputFrameCount {
                matchingDetectionCycles += 1
            }
            if detectionCycles >= ProcessTapDirectOutputResampler.detectionCycleCount {
                stats.path = matchingDetectionCycles * 2 > detectionCycles ? .passthrough : .converting
            }
        }

        switch stats.path {
        case .passthrough:
            fifo.removeAll()
            hasStartedOutput = true
            return inputData
        case .detecting:
            fifo.push(inputData, frameCount: deliveredFrames)
            return idleOutput()
        case .converting:
            fifo.push(inputData, frameCount: deliveredFrames)
        }

        if !isPrimed {
            // Start (or restart after an underrun) with this cycle's input plus ≈ one IO cycle
            // queued; older excess is dropped so the latency stays at that target.
            let primeFrames = requiredInputFrames(forOutputFrames: outputFrameCount) * 2
            guard outputFrameCount > 0, fifo.availableFrames >= primeFrames else {
                return idleOutput()
            }

            fifo.discardOldest(fifo.availableFrames - primeFrames)
            isPrimed = true
        }

        let producedFrames = convert(frameCount: outputFrameCount)
        if producedFrames < outputFrameCount {
            stats.underrunCount += 1
            isPrimed = false
        }
        hasStartedOutput = true
        return convertedBufferList
    }

    /// IOProc only (and `warmUp`). Converts up to `frameCount` output frames from the FIFO into
    /// `convertedBufferList` and returns how many were produced; fewer means the FIFO ran dry.
    @discardableResult
    func convert(frameCount: Int) -> Int {
        let requestedFrames = min(max(0, frameCount), maxOutputFramesPerCycle)
        guard requestedFrames > 0 else {
            setConvertedFrameCount(0)
            return 0
        }

        setConvertedFrameCount(requestedFrames)
        var producedPackets = UInt32(requestedFrames)
        let status = AudioConverterFillComplexBuffer(
            converter,
            { _, ioNumberDataPackets, ioData, _, inUserData in
                guard let inUserData else {
                    ioNumberDataPackets.pointee = 0
                    return ProcessTapDirectOutputResampler.fifoEmptyStatus
                }

                return Unmanaged<ProcessTapDirectOutputResampler>
                    .fromOpaque(inUserData)
                    .takeUnretainedValue()
                    .supplyConverterInput(packetCount: ioNumberDataPackets, bufferList: ioData)
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &producedPackets,
            convertedList,
            nil
        )

        let isUsableStatus = status == noErr || status == ProcessTapDirectOutputResampler.fifoEmptyStatus
        let producedFrames = isUsableStatus ? min(Int(producedPackets), requestedFrames) : 0
        setConvertedFrameCount(producedFrames)
        return producedFrames
    }

    static func interleavedFloatFormat(sampleRate: Double, channelCount: Int) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(channelCount * MemoryLayout<Float32>.stride)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// Converter input proc body: hands the converter up to the requested frames from the FIFO via
    /// the staging buffer (valid until the next input request), or reports an empty FIFO.
    private func supplyConverterInput(
        packetCount: UnsafeMutablePointer<UInt32>,
        bufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let frames = fifo.pull(into: inputStaging, maxFrames: Int(packetCount.pointee))
        guard frames > 0 else {
            packetCount.pointee = 0
            return ProcessTapDirectOutputResampler.fifoEmptyStatus
        }

        bufferList.pointee.mNumberBuffers = 1
        bufferList.pointee.mBuffers = AudioBuffer(
            mNumberChannels: UInt32(channelCount),
            mDataByteSize: UInt32(frames * channelCount * MemoryLayout<Float32>.stride),
            mData: UnsafeMutableRawPointer(inputStaging)
        )
        packetCount.pointee = UInt32(frames)
        return noErr
    }

    private func requiredInputFrames(forOutputFrames outputFrames: Int) -> Int {
        Int((Double(max(0, outputFrames)) * ratio).rounded(.up))
    }

    private func idleOutput() -> UnsafePointer<AudioBufferList>? {
        guard hasStartedOutput else {
            return nil
        }

        setConvertedFrameCount(0)
        return convertedBufferList
    }

    private func setConvertedFrameCount(_ frameCount: Int) {
        convertedList.pointee.mNumberBuffers = 1
        convertedList.pointee.mBuffers = AudioBuffer(
            mNumberChannels: UInt32(channelCount),
            mDataByteSize: UInt32(frameCount * channelCount * MemoryLayout<Float32>.stride),
            mData: UnsafeMutableRawPointer(convertedSamples)
        )
    }

    private func publishStats() {
        stats.overflowCount = fifo.overflowCount
        if statsLock.`try`() {
            publishedStats = stats
            statsLock.unlock()
        }
    }

    /// Runs one conversion of silence here, off the audio thread, so the converter's first-use
    /// setup does not happen in the IOProc; then resets it to an empty state.
    private func warmUp() {
        let warmUpFrames = min(maxOutputFramesPerCycle, 512)
        fifo.pushSilence(frameCount: requiredInputFrames(forOutputFrames: warmUpFrames) * 2)
        convert(frameCount: warmUpFrames)
        fifo.removeAll()
        _ = AudioConverterReset(converter)
    }
}
