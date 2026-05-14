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
