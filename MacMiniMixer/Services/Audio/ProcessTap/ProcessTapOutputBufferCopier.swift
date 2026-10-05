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

    /// Why the aggregate's tap input / device output formats cannot be rendered directly (the
    /// caller then falls back to the AudioQueue path), or nil when they can. The direct path copies
    /// frame-for-frame without resampling, so both sides must run at the same sample rate.
    static func formatIncompatibility(
        input: AudioStreamBasicDescription,
        output: AudioStreamBasicDescription
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

        guard input.mSampleRate > 0,
              output.mSampleRate > 0,
              abs(input.mSampleRate - output.mSampleRate) < 0.5 else {
            return "sample rate mismatch (tap \(input.mSampleRate) Hz, output \(output.mSampleRate) Hz)"
        }

        return nil
    }

    private static func channelCount(in buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        var count = 0
        for buffer in buffers {
            count += Int(buffer.mNumberChannels)
        }
        return count
    }

    /// Locates global channel `index` across `buffers` (each interleaving `mNumberChannels`).
    private static func channel(
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
