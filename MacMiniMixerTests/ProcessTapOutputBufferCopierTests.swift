import CoreAudio
import XCTest
@testable import MacMiniMixer

final class ProcessTapOutputBufferCopierTests: XCTestCase {
    func testCopiesInterleavedMonoInputToMonoOutput() {
        let (result, output) = copy(
            buffers: [InputBuffer(channels: 1, samples: [0.1, -0.2, 0.3])],
            outputChannelCount: 1,
            outputFrameCapacity: 3
        )

        XCTAssertEqual(result?.frameCount, 3)
        XCTAssertEqual(result?.outputByteSize, UInt32(3 * MemoryLayout<Float32>.stride))
        XCTAssertFloatArrayEqual(Array(output.prefix(3)), [0.1, -0.2, 0.3])
    }

    func testCopiesInterleavedMonoInputToStereoOutputUsingChannelFallback() {
        let (result, output) = copy(
            buffers: [InputBuffer(channels: 1, samples: [0.1, 0.2])],
            outputChannelCount: 2,
            outputFrameCapacity: 2
        )

        XCTAssertEqual(result?.frameCount, 2)
        XCTAssertFloatArrayEqual(Array(output.prefix(4)), [0.1, 0.1, 0.2, 0.2])
    }

    func testCopiesInterleavedStereoInputToStereoOutput() {
        let (result, output) = copy(
            buffers: [InputBuffer(channels: 2, samples: [0.1, 0.2, 0.3, 0.4])],
            outputChannelCount: 2,
            outputFrameCapacity: 2
        )

        XCTAssertEqual(result?.frameCount, 2)
        XCTAssertFloatArrayEqual(Array(output.prefix(4)), [0.1, 0.2, 0.3, 0.4])
    }

    func testCopiesPlanarStereoInputToStereoOutput() {
        let (result, output) = copy(
            buffers: [
                InputBuffer(channels: 1, samples: [0.1, 0.3]),
                InputBuffer(channels: 1, samples: [0.2, 0.4])
            ],
            outputChannelCount: 2,
            outputFrameCapacity: 2
        )

        XCTAssertEqual(result?.frameCount, 2)
        XCTAssertFloatArrayEqual(Array(output.prefix(4)), [0.1, 0.2, 0.3, 0.4])
    }

    func testOutputFrameCountIsCappedByOutputCapacity() {
        let (result, output) = copy(
            buffers: [InputBuffer(channels: 1, samples: [0.1, 0.2, 0.3, 0.4])],
            outputChannelCount: 1,
            outputFrameCapacity: 2
        )

        XCTAssertEqual(result?.frameCount, 2)
        XCTAssertEqual(result?.outputByteSize, UInt32(2 * MemoryLayout<Float32>.stride))
        XCTAssertFloatArrayEqual(Array(output.prefix(2)), [0.1, 0.2])
    }

    func testAppliesGainMultiplication() {
        let (result, output) = copy(
            buffers: [InputBuffer(channels: 1, samples: [1.0, -0.5])],
            outputChannelCount: 1,
            outputFrameCapacity: 2,
            gain: 0.25
        )

        XCTAssertEqual(result?.frameCount, 2)
        XCTAssertFloatArrayEqual(Array(output.prefix(2)), [0.25, -0.125])
    }

    func testPlanarMissingInputBufferWritesZeroForThatChannel() {
        let (result, output) = copy(
            buffers: [
                InputBuffer(channels: 1, samples: [0.1, 0.3]),
                InputBuffer(channels: 1, samples: [0.0, 0.0], hasData: false)
            ],
            outputChannelCount: 2,
            outputFrameCapacity: 2
        )

        XCTAssertEqual(result?.frameCount, 2)
        XCTAssertFloatArrayEqual(Array(output.prefix(4)), [0.1, 0.0, 0.3, 0.0])
    }

    func testReturnsNilForEmptyInputList() {
        let (result, _) = copy(
            buffers: [],
            outputChannelCount: 1,
            outputFrameCapacity: 2
        )

        XCTAssertNil(result)
    }

    func testReturnsNilForZeroOutputChannelCount() {
        let (result, _) = copy(
            buffers: [InputBuffer(channels: 1, samples: [0.1])],
            outputChannelCount: 0,
            outputFrameCapacity: 1
        )

        XCTAssertNil(result)
    }

    func testReturnsNilForZeroOutputFrameCapacity() {
        let (result, _) = copy(
            buffers: [InputBuffer(channels: 1, samples: [0.1])],
            outputChannelCount: 1,
            outputFrameCapacity: 0
        )

        XCTAssertNil(result)
    }

    func testCustomFrameGainProviderCanVaryGainPerFrame() {
        var gainProvider = SequenceFrameGainProvider(gains: [0.25, 0.5])
        let (result, output) = copy(
            buffers: [InputBuffer(channels: 1, samples: [1.0, 1.0])],
            outputChannelCount: 2,
            outputFrameCapacity: 2,
            gainProvider: &gainProvider
        )

        XCTAssertEqual(result?.frameCount, 2)
        XCTAssertFloatArrayEqual(Array(output.prefix(4)), [0.25, 0.25, 0.5, 0.5])
    }

    private func copy(
        buffers: [InputBuffer],
        outputChannelCount: Int,
        outputFrameCapacity: Int,
        gain: Float = 1.0
    ) -> (ProcessTapOutputBufferCopyResult?, [Float32]) {
        var gainProvider = ProcessTapConstantFrameGainProvider(gain: gain)
        return copy(
            buffers: buffers,
            outputChannelCount: outputChannelCount,
            outputFrameCapacity: outputFrameCapacity,
            gainProvider: &gainProvider
        )
    }

    private func copy<GainProvider: ProcessTapOutputFrameGainProviding>(
        buffers: [InputBuffer],
        outputChannelCount: Int,
        outputFrameCapacity: Int,
        gainProvider: inout GainProvider
    ) -> (ProcessTapOutputBufferCopyResult?, [Float32]) {
        let outputSampleCapacity = max(1, outputChannelCount * max(1, outputFrameCapacity))
        var output = Array(repeating: Float32(-99), count: outputSampleCapacity)
        let outputByteCapacity = UInt32(
            outputFrameCapacity * outputChannelCount * MemoryLayout<Float32>.stride
        )

        let result = output.withUnsafeMutableBufferPointer { outputBuffer in
            withAudioBufferList(buffers: buffers) { inputData in
                ProcessTapOutputBufferCopier.copy(
                    inputData,
                    into: outputBuffer.baseAddress!,
                    outputByteCapacity: outputByteCapacity,
                    outputChannelCount: outputChannelCount,
                    gainProvider: &gainProvider
                )
            }
        }

        return (result, output)
    }

    private func withAudioBufferList<Result>(
        buffers: [InputBuffer],
        _ body: (UnsafePointer<AudioBufferList>) -> Result
    ) -> Result {
        let listByteCount = MemoryLayout<AudioBufferList>.size
            + max(0, buffers.count - 1) * MemoryLayout<AudioBuffer>.stride
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: listByteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawList.deallocate()
        }

        let audioBufferList = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        audioBufferList.pointee.mNumberBuffers = UInt32(buffers.count)
        let mutableList = UnsafeMutableAudioBufferListPointer(audioBufferList)

        var samplePointers: [UnsafeMutablePointer<Float32>?] = []
        samplePointers.reserveCapacity(buffers.count)

        for (index, buffer) in buffers.enumerated() {
            let samplePointer: UnsafeMutablePointer<Float32>?
            if buffer.hasData {
                let pointer = UnsafeMutablePointer<Float32>.allocate(
                    capacity: max(1, buffer.samples.count)
                )
                pointer.initialize(from: buffer.samples, count: buffer.samples.count)
                samplePointer = pointer
            } else {
                samplePointer = nil
            }

            samplePointers.append(samplePointer)
            mutableList[index] = AudioBuffer(
                mNumberChannels: buffer.channels,
                mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float32>.stride),
                mData: samplePointer.map { UnsafeMutableRawPointer($0) }
            )
        }

        defer {
            for (index, pointer) in samplePointers.enumerated() {
                pointer?.deinitialize(count: buffers[index].samples.count)
                pointer?.deallocate()
            }
        }

        return body(UnsafePointer(audioBufferList))
    }

    private func XCTAssertFloatArrayEqual(
        _ actual: [Float32],
        _ expected: [Float32],
        accuracy: Float = 0.000001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualValue, expectedValue) in zip(actual, expected) {
            XCTAssertEqual(
                Double(actualValue),
                Double(expectedValue),
                accuracy: Double(accuracy),
                file: file,
                line: line
            )
        }
    }
}

private struct InputBuffer {
    let channels: UInt32
    let samples: [Float32]
    var hasData = true
}

private struct SequenceFrameGainProvider: ProcessTapOutputFrameGainProviding {
    var gains: [Float]

    mutating func gain(forFrame frame: Int) -> Float {
        gains[min(frame, gains.count - 1)]
    }
}

final class ProcessTapDirectOutputCopierTests: XCTestCase {
    func testInterleavedStereoInputToInterleavedStereoOutputAppliesGain() {
        let (result, output) = render(
            input: [InputBuffer(channels: 2, samples: [0.1, 0.2, 0.3, 0.4])],
            output: [outputBuffer(channels: 2, frameCount: 2)],
            gain: 0.5
        )

        XCTAssertEqual(result, ProcessTapDirectOutputRenderResult(outputFrameCount: 2, inputFrameCount: 2))
        assertSamples(output[0], [0.05, 0.1, 0.15, 0.2])
    }

    func testNonInterleavedStereoInputToInterleavedStereoOutput() {
        let (result, output) = render(
            input: [
                InputBuffer(channels: 1, samples: [0.1, 0.3]),
                InputBuffer(channels: 1, samples: [0.2, 0.4])
            ],
            output: [outputBuffer(channels: 2, frameCount: 2)]
        )

        XCTAssertEqual(result, ProcessTapDirectOutputRenderResult(outputFrameCount: 2, inputFrameCount: 2))
        assertSamples(output[0], [0.1, 0.2, 0.3, 0.4])
    }

    func testInterleavedStereoInputToNonInterleavedStereoOutput() {
        let (result, output) = render(
            input: [InputBuffer(channels: 2, samples: [0.1, 0.2, 0.3, 0.4])],
            output: [
                outputBuffer(channels: 1, frameCount: 2),
                outputBuffer(channels: 1, frameCount: 2)
            ]
        )

        XCTAssertEqual(result, ProcessTapDirectOutputRenderResult(outputFrameCount: 2, inputFrameCount: 2))
        assertSamples(output[0], [0.1, 0.3])
        assertSamples(output[1], [0.2, 0.4])
    }

    func testMonoInputIsDuplicatedToBothStereoOutputChannels() {
        let (_, output) = render(
            input: [InputBuffer(channels: 1, samples: [0.1, 0.2])],
            output: [outputBuffer(channels: 2, frameCount: 2)]
        )

        assertSamples(output[0], [0.1, 0.1, 0.2, 0.2])
    }

    func testStereoInputIsAveragedIntoMonoOutput() {
        let (_, output) = render(
            input: [InputBuffer(channels: 2, samples: [0.2, 0.4, -0.2, 0.6])],
            output: [outputBuffer(channels: 1, frameCount: 2)]
        )

        assertSamples(output[0], [0.3, 0.2])
    }

    func testExtraOutputChannelsAreZeroed() {
        let (_, output) = render(
            input: [InputBuffer(channels: 2, samples: [0.1, 0.2, 0.3, 0.4])],
            output: [outputBuffer(channels: 4, frameCount: 2)]
        )

        assertSamples(output[0], [0.1, 0.2, 0, 0, 0.3, 0.4, 0, 0])
    }

    func testOutputChannelsAcrossSeveralStreamsMapByGlobalChannelIndex() {
        let (_, output) = render(
            input: [InputBuffer(channels: 2, samples: [0.1, 0.2, 0.3, 0.4])],
            output: [
                outputBuffer(channels: 1, frameCount: 2),
                outputBuffer(channels: 3, frameCount: 2)
            ]
        )

        assertSamples(output[0], [0.1, 0.3])
        assertSamples(output[1], [0.2, 0, 0, 0.4, 0, 0])
    }

    func testShortInputLeavesRemainingFramesSilentAndStillAdvancesGainPerOutputFrame() {
        var gainProvider = CountingFrameGainProvider(gain: 1)
        let (result, output) = render(
            input: [InputBuffer(channels: 2, samples: [0.1, 0.2])],
            output: [outputBuffer(channels: 2, frameCount: 3)],
            gainProvider: &gainProvider
        )

        XCTAssertEqual(result, ProcessTapDirectOutputRenderResult(outputFrameCount: 3, inputFrameCount: 1))
        assertSamples(output[0], [0.1, 0.2, 0, 0, 0, 0])
        XCTAssertEqual(gainProvider.callCount, 3)
    }

    func testMissingInputDataOverwritesStaleOutputWithSilence() {
        var gainProvider = CountingFrameGainProvider(gain: 1)
        let (result, output) = render(
            input: [InputBuffer(channels: 2, samples: [0.5, 0.5, 0.5, 0.5], hasData: false)],
            output: [outputBuffer(channels: 2, frameCount: 2)],
            gainProvider: &gainProvider
        )

        XCTAssertEqual(result, ProcessTapDirectOutputRenderResult(outputFrameCount: 2, inputFrameCount: 0))
        assertSamples(output[0], [0, 0, 0, 0])
        XCTAssertEqual(gainProvider.callCount, 2)
    }

    func testEmptyInputListWritesSilence() {
        let (result, output) = render(
            input: [],
            output: [outputBuffer(channels: 2, frameCount: 2)]
        )

        XCTAssertEqual(result, ProcessTapDirectOutputRenderResult(outputFrameCount: 2, inputFrameCount: 0))
        assertSamples(output[0], [0, 0, 0, 0])
    }

    func testMissingRightChannelInNonInterleavedInputLeavesOnlyThatChannelSilent() {
        let (_, output) = render(
            input: [
                InputBuffer(channels: 1, samples: [0.1, 0.3]),
                InputBuffer(channels: 1, samples: [0.0, 0.0], hasData: false)
            ],
            output: [outputBuffer(channels: 2, frameCount: 2)]
        )

        assertSamples(output[0], [0.1, 0, 0.3, 0])
    }

    func testNonFiniteInputSamplesAreWrittenAsSilence() {
        let (_, output) = render(
            input: [InputBuffer(channels: 2, samples: [.nan, 0.2, .infinity, 0.4])],
            output: [outputBuffer(channels: 2, frameCount: 2)]
        )

        assertSamples(output[0], [0, 0.2, 0, 0.4])
    }

    func testPerFrameGainAppliesToEveryChannelOfTheFrame() {
        var gainProvider = SequenceFrameGainProvider(gains: [0, 0.5, 1])
        let (_, output) = render(
            input: [InputBuffer(channels: 1, samples: [1, 1, 1])],
            output: [outputBuffer(channels: 2, frameCount: 3)],
            gainProvider: &gainProvider
        )

        assertSamples(output[0], [0, 0, 0.5, 0.5, 1, 1])
    }

    func testOutputWithoutBuffersRendersNothing() {
        var gainProvider = CountingFrameGainProvider(gain: 1)
        let (result, _) = render(
            input: [InputBuffer(channels: 2, samples: [0.1, 0.2])],
            output: [],
            gainProvider: &gainProvider
        )

        XCTAssertEqual(result, ProcessTapDirectOutputRenderResult(outputFrameCount: 0, inputFrameCount: 0))
        XCTAssertEqual(gainProvider.callCount, 0)
    }

    func testFormatCheckAcceptsMatchingFloatFormatsIncludingMultichannelOutput() {
        XCTAssertNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(channels: 2),
            output: pcmFormat(channels: 2)
        ))
        XCTAssertNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(channels: 1),
            output: pcmFormat(channels: 8)
        ))
    }

    func testFormatCheckAcceptsSampleRateMismatchWhenConversionIsAllowed() {
        XCTAssertNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(sampleRate: 48_000, channels: 2),
            output: pcmFormat(sampleRate: 44_100, channels: 2)
        ))
        XCTAssertNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(sampleRate: 44_100, channels: 1),
            output: pcmFormat(sampleRate: 48_000, channels: 2),
            allowsSampleRateConversion: true
        ))
    }

    func testFormatCheckRejectsSampleRateMismatchWhenConversionIsOff() {
        XCTAssertNotNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(sampleRate: 48_000, channels: 2),
            output: pcmFormat(sampleRate: 44_100, channels: 2),
            allowsSampleRateConversion: false
        ))
        XCTAssertNotNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(sampleRate: 44_100, channels: 2),
            output: pcmFormat(sampleRate: 48_000, channels: 2),
            allowsSampleRateConversion: false
        ))
        // Equal rates never need conversion, so they pass either way.
        XCTAssertNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(sampleRate: 48_000, channels: 2),
            output: pcmFormat(sampleRate: 48_000, channels: 2),
            allowsSampleRateConversion: false
        ))
    }

    func testFormatCheckRejectsInvalidSampleRatesAndExtremeRatios() {
        XCTAssertNotNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(sampleRate: 0, channels: 2),
            output: pcmFormat(sampleRate: 0, channels: 2)
        ))
        XCTAssertNotNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(sampleRate: 48_000, channels: 2),
            output: pcmFormat(sampleRate: 0, channels: 2)
        ))
        XCTAssertNotNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(sampleRate: 384_000, channels: 2),
            output: pcmFormat(sampleRate: 8_000, channels: 2)
        ))
    }

    func testSampleRateConversionIsRequiredOnlyForDifferingRates() {
        XCTAssertTrue(ProcessTapDirectOutputCopier.requiresSampleRateConversion(
            input: pcmFormat(sampleRate: 48_000, channels: 2),
            output: pcmFormat(sampleRate: 44_100, channels: 2)
        ))
        XCTAssertFalse(ProcessTapDirectOutputCopier.requiresSampleRateConversion(
            input: pcmFormat(sampleRate: 48_000, channels: 2),
            output: pcmFormat(sampleRate: 48_000, channels: 8)
        ))
        XCTAssertFalse(ProcessTapDirectOutputCopier.requiresSampleRateConversion(
            input: pcmFormat(sampleRate: 44_100, channels: 2),
            output: pcmFormat(sampleRate: 44_100.2, channels: 2)
        ))
    }

    func testOutputFrameCountMatchesTheFramesRenderWrites() {
        let outputList = TestAudioBufferList(buffers: [
            outputBuffer(channels: 2, frameCount: 3),
            outputBuffer(channels: 1, frameCount: 3)
        ])
        defer {
            outputList.deallocate()
        }

        XCTAssertEqual(ProcessTapDirectOutputCopier.outputFrameCount(in: outputList.pointer), 3)

        let emptyList = TestAudioBufferList(buffers: [])
        defer {
            emptyList.deallocate()
        }

        XCTAssertEqual(ProcessTapDirectOutputCopier.outputFrameCount(in: emptyList.pointer), 0)
    }

    func testRenderSilenceZeroesEveryOutputBuffer() {
        let outputList = TestAudioBufferList(buffers: [
            outputBuffer(channels: 2, frameCount: 2),
            outputBuffer(channels: 1, frameCount: 2)
        ])
        defer {
            outputList.deallocate()
        }

        let result = ProcessTapDirectOutputCopier.renderSilence(into: outputList.pointer)

        XCTAssertEqual(result, ProcessTapDirectOutputRenderResult(outputFrameCount: 2, inputFrameCount: 0))
        let samples = outputList.samples()
        assertSamples(samples[0], [0, 0, 0, 0])
        assertSamples(samples[1], [0, 0])
    }

    func testFormatCheckRejectsUnsupportedTapOrOutputFormat() {
        XCTAssertNotNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(channels: 3),
            output: pcmFormat(channels: 2)
        ))
        XCTAssertNotNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(channels: 2),
            output: pcmFormat(channels: 2, isFloat: false, bitsPerChannel: 16)
        ))
        XCTAssertNotNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(channels: 2),
            output: pcmFormat(channels: 0)
        ))
    }

    private func outputBuffer(channels: UInt32, frameCount: Int, hasData: Bool = true) -> InputBuffer {
        // Pre-filled with a sentinel so any sample the renderer fails to write is caught.
        InputBuffer(
            channels: channels,
            samples: Array(repeating: Float32(-99), count: Int(channels) * frameCount),
            hasData: hasData
        )
    }

    private func render(
        input: [InputBuffer],
        output: [InputBuffer],
        gain: Float = 1.0
    ) -> (ProcessTapDirectOutputRenderResult, [[Float32]]) {
        var gainProvider = ProcessTapConstantFrameGainProvider(gain: gain)
        return render(input: input, output: output, gainProvider: &gainProvider)
    }

    private func render<GainProvider: ProcessTapOutputFrameGainProviding>(
        input: [InputBuffer],
        output: [InputBuffer],
        gainProvider: inout GainProvider
    ) -> (ProcessTapDirectOutputRenderResult, [[Float32]]) {
        let inputList = TestAudioBufferList(buffers: input)
        let outputList = TestAudioBufferList(buffers: output)
        defer {
            inputList.deallocate()
            outputList.deallocate()
        }

        let result = ProcessTapDirectOutputCopier.render(
            UnsafePointer(inputList.pointer),
            into: outputList.pointer,
            gainProvider: &gainProvider
        )
        return (result, outputList.samples())
    }

    private func pcmFormat(
        sampleRate: Double = 48_000,
        channels: UInt32,
        isFloat: Bool = true,
        bitsPerChannel: UInt32 = 32
    ) -> AudioStreamBasicDescription {
        let bytesPerFrame = (bitsPerChannel / 8) * channels
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: isFloat
                ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )
    }

    private func assertSamples(
        _ actual: [Float32],
        _ expected: [Float32],
        accuracy: Float = 0.000001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualValue, expectedValue) in zip(actual, expected) {
            XCTAssertEqual(
                Double(actualValue),
                Double(expectedValue),
                accuracy: Double(accuracy),
                file: file,
                line: line
            )
        }
    }
}

private struct CountingFrameGainProvider: ProcessTapOutputFrameGainProviding {
    let gain: Float
    var callCount = 0

    mutating func gain(forFrame frame: Int) -> Float {
        callCount += 1
        return gain
    }
}

/// Heap-allocated AudioBufferList for the direct-output tests (usable as input or output). Freed
/// explicitly with `deallocate()` (not in a deinit, so ARC cannot free it while a raw pointer into
/// it is still in use).
private struct TestAudioBufferList {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    private let rawList: UnsafeMutableRawPointer
    private let samplePointers: [UnsafeMutablePointer<Float32>?]
    private let sampleCounts: [Int]

    init(buffers: [InputBuffer]) {
        let listByteCount = MemoryLayout<AudioBufferList>.size
            + max(0, buffers.count - 1) * MemoryLayout<AudioBuffer>.stride
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: listByteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let audioBufferList = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        audioBufferList.pointee.mNumberBuffers = UInt32(buffers.count)
        let mutableList = UnsafeMutableAudioBufferListPointer(audioBufferList)

        var samplePointers: [UnsafeMutablePointer<Float32>?] = []
        for (index, buffer) in buffers.enumerated() {
            let samplePointer: UnsafeMutablePointer<Float32>?
            if buffer.hasData {
                let allocatedPointer = UnsafeMutablePointer<Float32>.allocate(
                    capacity: max(1, buffer.samples.count)
                )
                allocatedPointer.initialize(from: buffer.samples, count: buffer.samples.count)
                samplePointer = allocatedPointer
            } else {
                samplePointer = nil
            }

            samplePointers.append(samplePointer)
            mutableList[index] = AudioBuffer(
                mNumberChannels: buffer.channels,
                mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float32>.stride),
                mData: samplePointer.map { UnsafeMutableRawPointer($0) }
            )
        }

        self.pointer = audioBufferList
        self.rawList = rawList
        self.samplePointers = samplePointers
        self.sampleCounts = buffers.map { $0.samples.count }
    }

    /// Current contents of every buffer (`[]` for a buffer without data).
    func samples() -> [[Float32]] {
        var contents: [[Float32]] = []
        for (samplePointer, count) in zip(samplePointers, sampleCounts) {
            if let samplePointer {
                contents.append(Array(UnsafeBufferPointer(start: samplePointer, count: count)))
            } else {
                contents.append([])
            }
        }
        return contents
    }

    func deallocate() {
        for (samplePointer, count) in zip(samplePointers, sampleCounts) {
            samplePointer?.deinitialize(count: count)
            samplePointer?.deallocate()
        }
        rawList.deallocate()
    }
}

final class ProcessTapLiveOutputModeTests: XCTestCase {
    func testDefaultModeIsDirectAggregateOutput() {
        XCTAssertEqual(AppConstants.processTapLiveDefaultOutputMode, .directAggregateOutput)
        XCTAssertEqual(AppConstants.processTapLiveOutputModeDefaultsKey, "MacMiniMixerLiveOutputMode")
    }

    func testMissingOrBlankStoredValueUsesDefault() {
        XCTAssertEqual(ProcessTapLiveOutputMode.resolve(storedValue: nil), .directAggregateOutput)
        XCTAssertEqual(ProcessTapLiveOutputMode.resolve(storedValue: ""), .directAggregateOutput)
        XCTAssertEqual(ProcessTapLiveOutputMode.resolve(storedValue: "  \n"), .directAggregateOutput)
    }

    func testAudioQueueValueSelectsLegacyPath() {
        XCTAssertEqual(ProcessTapLiveOutputMode.resolve(storedValue: "audioQueue"), .audioQueue)
        XCTAssertEqual(ProcessTapLiveOutputMode.resolve(storedValue: " AudioQueue\n"), .audioQueue)
        XCTAssertEqual(ProcessTapLiveOutputMode.resolve(storedValue: "AUDIOQUEUE"), .audioQueue)
    }

    func testDirectValueSelectsDirectPathEvenWhenDefaultDiffers() {
        XCTAssertEqual(
            ProcessTapLiveOutputMode.resolve(storedValue: "directAggregateOutput", defaultMode: .audioQueue),
            .directAggregateOutput
        )
    }

    func testUnknownValueFallsBackToDefault() {
        XCTAssertEqual(ProcessTapLiveOutputMode.resolve(storedValue: "audio-queue"), .directAggregateOutput)
        XCTAssertEqual(
            ProcessTapLiveOutputMode.resolve(storedValue: "bogus", defaultMode: .audioQueue),
            .audioQueue
        )
    }

    func testConfiguredReadsTheUserDefaultsOverride() throws {
        let suiteName = "ProcessTapLiveOutputModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(ProcessTapLiveOutputMode.configured(userDefaults: defaults), .directAggregateOutput)

        defaults.set("audioQueue", forKey: AppConstants.processTapLiveOutputModeDefaultsKey)
        XCTAssertEqual(ProcessTapLiveOutputMode.configured(userDefaults: defaults), .audioQueue)

        defaults.set("directAggregateOutput", forKey: AppConstants.processTapLiveOutputModeDefaultsKey)
        XCTAssertEqual(ProcessTapLiveOutputMode.configured(userDefaults: defaults), .directAggregateOutput)
    }
}

final class ProcessTapDirectResampleModeTests: XCTestCase {
    func testDefaultIsOnWithItsDefaultsKey() {
        XCTAssertEqual(AppConstants.processTapDirectResampleDefaultMode, .on)
        XCTAssertEqual(AppConstants.processTapDirectResampleDefaultsKey, "MacMiniMixerDirectResample")
    }

    func testMissingBlankOrUnknownValueKeepsConversionOn() {
        XCTAssertEqual(ProcessTapDirectResampleMode.resolve(storedValue: nil), .on)
        XCTAssertEqual(ProcessTapDirectResampleMode.resolve(storedValue: ""), .on)
        XCTAssertEqual(ProcessTapDirectResampleMode.resolve(storedValue: " \n"), .on)
        XCTAssertEqual(ProcessTapDirectResampleMode.resolve(storedValue: "bogus"), .on)
    }

    func testOffValuesDisableConversion() {
        XCTAssertEqual(ProcessTapDirectResampleMode.resolve(storedValue: "off"), .off)
        XCTAssertEqual(ProcessTapDirectResampleMode.resolve(storedValue: " OFF\n"), .off)
        XCTAssertEqual(ProcessTapDirectResampleMode.resolve(storedValue: "false"), .off)
        XCTAssertEqual(ProcessTapDirectResampleMode.resolve(storedValue: "No"), .off)
        XCTAssertEqual(ProcessTapDirectResampleMode.resolve(storedValue: "0"), .off)
    }

    func testOnValuesEnableConversion() {
        XCTAssertEqual(ProcessTapDirectResampleMode.resolve(storedValue: "on"), .on)
        XCTAssertEqual(ProcessTapDirectResampleMode.resolve(storedValue: "TRUE"), .on)
        XCTAssertEqual(ProcessTapDirectResampleMode.resolve(storedValue: "1"), .on)
    }

    func testConfiguredReadsTheUserDefaultsOverride() throws {
        let suiteName = "ProcessTapDirectResampleModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(ProcessTapDirectResampleMode.configured(userDefaults: defaults), .on)

        defaults.set("off", forKey: AppConstants.processTapDirectResampleDefaultsKey)
        XCTAssertEqual(ProcessTapDirectResampleMode.configured(userDefaults: defaults), .off)

        defaults.set("on", forKey: AppConstants.processTapDirectResampleDefaultsKey)
        XCTAssertEqual(ProcessTapDirectResampleMode.configured(userDefaults: defaults), .on)
    }
}

final class ProcessTapDirectOutputFrameFIFOTests: XCTestCase {
    func testPushThenPullReturnsInterleavedFramesInOrderAcrossTheWrap() {
        let fifo = ProcessTapDirectOutputFrameFIFO(channelCount: 2, capacityFrames: 4)

        push([InputBuffer(channels: 2, samples: [1, 2, 3, 4, 5, 6])], into: fifo)
        XCTAssertEqual(fifo.availableFrames, 3)
        XCTAssertEqual(pull(from: fifo, maxFrames: 2), [1, 2, 3, 4])

        push([InputBuffer(channels: 2, samples: [7, 8, 9, 10, 11, 12])], into: fifo)
        XCTAssertEqual(fifo.availableFrames, 4)
        XCTAssertEqual(pull(from: fifo, maxFrames: 4), [5, 6, 7, 8, 9, 10, 11, 12])
        XCTAssertEqual(fifo.availableFrames, 0)
        XCTAssertEqual(fifo.overflowCount, 0)
    }

    func testPullBeyondTheQueuedFramesReturnsOnlyThoseAndLeavesTheRestUntouched() {
        let fifo = ProcessTapDirectOutputFrameFIFO(channelCount: 1, capacityFrames: 8)
        push([InputBuffer(channels: 1, samples: [0.1, 0.2])], into: fifo)

        var destination = [Float32](repeating: -99, count: 5)
        let pulledFrames = destination.withUnsafeMutableBufferPointer { buffer in
            fifo.pull(into: buffer.baseAddress!, maxFrames: 5)
        }

        XCTAssertEqual(pulledFrames, 2)
        XCTAssertEqual(destination, [0.1, 0.2, -99, -99, -99])
        XCTAssertEqual(fifo.availableFrames, 0)
        XCTAssertEqual(pull(from: fifo, maxFrames: 3), [])
    }

    func testOverflowDropsTheOldestFramesAndCountsIt() {
        let fifo = ProcessTapDirectOutputFrameFIFO(channelCount: 1, capacityFrames: 4)
        push([InputBuffer(channels: 1, samples: [1, 2, 3])], into: fifo)
        push([InputBuffer(channels: 1, samples: [4, 5, 6])], into: fifo)

        XCTAssertEqual(fifo.overflowCount, 1)
        XCTAssertEqual(fifo.droppedFrameCount, 2)
        XCTAssertEqual(fifo.availableFrames, 4)
        XCTAssertEqual(pull(from: fifo, maxFrames: 4), [3, 4, 5, 6])
    }

    func testPushLargerThanTheWholeFIFOKeepsTheNewestFrames() {
        let fifo = ProcessTapDirectOutputFrameFIFO(channelCount: 1, capacityFrames: 4)
        push([InputBuffer(channels: 1, samples: [1, 2, 3, 4, 5, 6])], into: fifo)

        XCTAssertEqual(fifo.overflowCount, 1)
        XCTAssertEqual(fifo.droppedFrameCount, 2)
        XCTAssertEqual(pull(from: fifo, maxFrames: 6), [3, 4, 5, 6])
    }

    func testPushInterleavesNonInterleavedInputAndQueuesNonFiniteSamplesAsSilence() {
        let fifo = ProcessTapDirectOutputFrameFIFO(channelCount: 2, capacityFrames: 4)
        push([
            InputBuffer(channels: 1, samples: [0.1, .nan]),
            InputBuffer(channels: 1, samples: [0.2, 0.4])
        ], into: fifo)

        XCTAssertEqual(pull(from: fifo, maxFrames: 2), [0.1, 0.2, 0, 0.4])
    }

    func testMonoInputFillsBothChannelsOfAStereoFIFO() {
        let fifo = ProcessTapDirectOutputFrameFIFO(channelCount: 2, capacityFrames: 4)
        push([InputBuffer(channels: 1, samples: [0.5, 0.25])], into: fifo)

        XCTAssertEqual(pull(from: fifo, maxFrames: 2), [0.5, 0.5, 0.25, 0.25])
    }

    func testDeliveredFrameCountComesFromTheBufferByteSize() {
        XCTAssertEqual(deliveredFrames([InputBuffer(channels: 2, samples: [0, 0, 0, 0, 0, 0])]), 3)
        XCTAssertEqual(deliveredFrames([
            InputBuffer(channels: 1, samples: [0, 0, 0]),
            InputBuffer(channels: 1, samples: [0, 0])
        ]), 3)
        XCTAssertEqual(deliveredFrames([InputBuffer(channels: 2, samples: [0, 0, 0, 0], hasData: false)]), 2)
        XCTAssertEqual(deliveredFrames([]), 0)
    }

    func testMissingInputDataIsQueuedAsSilence() {
        let fifo = ProcessTapDirectOutputFrameFIFO(channelCount: 2, capacityFrames: 4)
        push([InputBuffer(channels: 2, samples: [0.5, 0.5, 0.5, 0.5], hasData: false)], into: fifo)

        XCTAssertEqual(pull(from: fifo, maxFrames: 2), [0, 0, 0, 0])
    }

    func testPushSilenceDiscardOldestAndRemoveAll() {
        let fifo = ProcessTapDirectOutputFrameFIFO(channelCount: 1, capacityFrames: 8)
        push([InputBuffer(channels: 1, samples: [1, 2])], into: fifo)
        fifo.pushSilence(frameCount: 2)
        XCTAssertEqual(fifo.availableFrames, 4)

        fifo.discardOldest(1)
        XCTAssertEqual(pull(from: fifo, maxFrames: 8), [2, 0, 0])

        push([InputBuffer(channels: 1, samples: [3])], into: fifo)
        fifo.removeAll()
        XCTAssertEqual(fifo.availableFrames, 0)
        XCTAssertEqual(fifo.overflowCount, 0)
    }

    private func push(_ buffers: [InputBuffer], into fifo: ProcessTapDirectOutputFrameFIFO) {
        let list = TestAudioBufferList(buffers: buffers)
        defer {
            list.deallocate()
        }

        let inputData = UnsafePointer(list.pointer)
        fifo.push(inputData, frameCount: ProcessTapDirectOutputFrameFIFO.deliveredFrameCount(in: inputData))
    }

    private func pull(from fifo: ProcessTapDirectOutputFrameFIFO, maxFrames: Int) -> [Float32] {
        var destination = [Float32](repeating: -99, count: max(1, maxFrames * fifo.channelCount))
        let pulledFrames = destination.withUnsafeMutableBufferPointer { buffer in
            fifo.pull(into: buffer.baseAddress!, maxFrames: maxFrames)
        }
        return Array(destination.prefix(pulledFrames * fifo.channelCount))
    }

    private func deliveredFrames(_ buffers: [InputBuffer]) -> Int {
        let list = TestAudioBufferList(buffers: buffers)
        defer {
            list.deallocate()
        }

        return ProcessTapDirectOutputFrameFIFO.deliveredFrameCount(in: UnsafePointer(list.pointer))
    }
}

final class ProcessTapDirectOutputResamplerTests: XCTestCase {
    private let outputFrames = 512

    func testEqualRatesNeedNoResampler() {
        XCTAssertNil(ProcessTapDirectOutputResampler(
            inputSampleRate: 48_000,
            outputSampleRate: 48_000,
            channelCount: 2,
            maxOutputFramesPerCycle: 4_096
        ))
        XCTAssertNil(ProcessTapDirectOutputResampler(
            inputSampleRate: 44_100,
            outputSampleRate: 44_100.2,
            channelCount: 2,
            maxOutputFramesPerCycle: 4_096
        ))
        XCTAssertFalse(ProcessTapDirectOutputCopier.requiresSampleRateConversion(
            input: ProcessTapDirectOutputResampler.interleavedFloatFormat(sampleRate: 48_000, channelCount: 2),
            output: ProcessTapDirectOutputResampler.interleavedFloatFormat(sampleRate: 48_000, channelCount: 2)
        ))
    }

    func testRejectsInvalidRatesAndChannelCounts() {
        XCTAssertNil(ProcessTapDirectOutputResampler(
            inputSampleRate: 0,
            outputSampleRate: 44_100,
            channelCount: 2,
            maxOutputFramesPerCycle: 4_096
        ))
        XCTAssertNil(ProcessTapDirectOutputResampler(
            inputSampleRate: 48_000,
            outputSampleRate: 44_100,
            channelCount: 3,
            maxOutputFramesPerCycle: 4_096
        ))
        XCTAssertNil(ProcessTapDirectOutputResampler(
            inputSampleRate: 48_000,
            outputSampleRate: 44_100,
            channelCount: 2,
            maxOutputFramesPerCycle: 0
        ))
    }

    func testConverts48kTapTo44_1kOutputWithExactFrameAccounting() throws {
        try assertSteadyConversion(tapRate: 48_000, outputRate: 44_100)
    }

    func testConverts44_1kTapTo48kOutputWithExactFrameAccounting() throws {
        try assertSteadyConversion(tapRate: 44_100, outputRate: 48_000)
    }

    func testConvertProducesOutputFramesInProportionToTheQueuedTapFrames() throws {
        let resampler = try makeResampler(tapRate: 48_000, outputRate: 44_100)
        // 100 ms of tap audio at 48 kHz is 4410 frames at 44.1 kHz.
        let tapFrameCount = 4_800
        let list = TestAudioBufferList(buffers: [sineBuffer(tapRate: 48_000, startFrame: 0, frameCount: tapFrameCount)])
        defer {
            list.deallocate()
        }

        resampler.fifo.push(UnsafePointer(list.pointer), frameCount: tapFrameCount)

        var producedTotal = 0
        var chunkSizes: [Int] = []
        for _ in 0..<20 {
            let producedFrames = resampler.convert(frameCount: 1_000)
            chunkSizes.append(producedFrames)
            XCTAssertTrue(convertedSamples(resampler).allSatisfy { $0.isFinite })
            XCTAssertEqual(convertedSamples(resampler).count, producedFrames * 2)
            producedTotal += producedFrames
            if producedFrames < 1_000 {
                break
            }
        }

        XCTAssertEqual(chunkSizes.first, 1_000)
        XCTAssertEqual(resampler.fifo.availableFrames, 0)
        XCTAssertEqual(Double(producedTotal), 4_410, accuracy: 300)
        // With the FIFO empty a full cycle cannot be produced (the caller renders the rest silent).
        XCTAssertLessThan(resampler.convert(frameCount: 1_000), 1_000)
        XCTAssertTrue(convertedSamples(resampler).allSatisfy { $0.isFinite })
    }

    func testStartsSilentThenPassesThroughWhenTheTapAlreadyArrivesAtTheOutputRate() throws {
        let resampler = try makeResampler(tapRate: 48_000, outputRate: 44_100)
        var outputs: [CycleOutput] = []
        for cycle in 0..<6 {
            outputs.append(runCycle(
                resampler,
                input: sineBuffer(tapRate: 48_000, startFrame: cycle * outputFrames, frameCount: outputFrames),
                outputFrameCount: outputFrames
            ))
        }

        let detectionCycles = ProcessTapDirectOutputResampler.detectionCycleCount
        for cycle in 0..<(detectionCycles - 1) {
            XCTAssertNil(outputs[cycle].frames, "cycle \(cycle)")
        }
        for cycle in (detectionCycles - 1)..<outputs.count {
            XCTAssertTrue(outputs[cycle].isInputPassthrough, "cycle \(cycle)")
            XCTAssertEqual(outputs[cycle].frames, outputFrames, "cycle \(cycle)")
        }

        let snapshot = resampler.snapshot()
        XCTAssertEqual(snapshot.path, .passthrough)
        XCTAssertEqual(snapshot.measuredRatio, 1, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.underrunCount, 0)
        XCTAssertEqual(resampler.fifo.availableFrames, 0)
    }

    func testUnderrunRendersSilenceCountsOnceAndRecovers() throws {
        let tapRate = 48_000.0
        let outputRate = 44_100.0
        let resampler = try makeResampler(tapRate: tapRate, outputRate: outputRate)
        var tapFrame = 0
        var cycle = 0

        for _ in 0..<20 {
            let frames = tapFrames(inCycle: cycle, tapRate: tapRate, outputRate: outputRate)
            _ = runCycle(
                resampler,
                input: sineBuffer(tapRate: tapRate, startFrame: tapFrame, frameCount: frames),
                outputFrameCount: outputFrames
            )
            tapFrame += frames
            cycle += 1
        }
        XCTAssertEqual(resampler.snapshot().underrunCount, 0)

        // The tap stops delivering: the queued cycle still plays, then the FIFO runs dry and the
        // missing frames are rendered silent (never stale data).
        var shortCycles = 0
        for _ in 0..<4 {
            let output = runCycle(resampler, input: InputBuffer(channels: 2, samples: []), outputFrameCount: outputFrames)
            cycle += 1
            let frames = try XCTUnwrap(output.frames, "output never returns to the start-up state")
            XCTAssertLessThanOrEqual(frames, outputFrames)
            XCTAssertTrue(output.samples.allSatisfy { $0.isFinite })
            XCTAssertFalse(output.rendered.contains(-99))
            XCTAssertTrue(output.rendered.dropFirst(frames * 2).allSatisfy { $0 == 0 })
            if frames < outputFrames {
                shortCycles += 1
            }
        }
        XCTAssertGreaterThanOrEqual(shortCycles, 1)
        XCTAssertEqual(resampler.snapshot().underrunCount, 1)

        // Delivery resumes: it refills to the latency target, then renders full cycles again.
        var fullCycles = 0
        for _ in 0..<10 {
            let frames = tapFrames(inCycle: cycle, tapRate: tapRate, outputRate: outputRate)
            let output = runCycle(
                resampler,
                input: sineBuffer(tapRate: tapRate, startFrame: tapFrame, frameCount: frames),
                outputFrameCount: outputFrames
            )
            tapFrame += frames
            cycle += 1
            if output.frames == outputFrames {
                fullCycles += 1
            }
        }
        XCTAssertGreaterThanOrEqual(fullCycles, 7)
        XCTAssertEqual(resampler.snapshot().underrunCount, 1)
        XCTAssertEqual(resampler.snapshot().overflowCount, 0)
    }

    // MARK: - Helpers

    private struct CycleOutput {
        /// Frames the resampler returned this cycle, or nil while it has not started output.
        let frames: Int?
        /// The returned interleaved samples.
        let samples: [Float32]
        /// The returned list rendered by the copier into a sentinel-filled stereo output buffer.
        let rendered: [Float32]
        let isInputPassthrough: Bool
    }

    private func makeResampler(tapRate: Double, outputRate: Double) throws -> ProcessTapDirectOutputResampler {
        try XCTUnwrap(ProcessTapDirectOutputResampler(
            inputSampleRate: tapRate,
            outputSampleRate: outputRate,
            channelCount: 2,
            maxOutputFramesPerCycle: 4_096
        ))
    }

    /// Simulates an IOProc cycle stream with a tap delivering frames at `tapRate` against
    /// `outputRate` output cycles of `outputFrames`, and checks frame accounting and signal level.
    private func assertSteadyConversion(
        tapRate: Double,
        outputRate: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let resampler = try makeResampler(tapRate: tapRate, outputRate: outputRate)
        let cycleCount = 300
        var tapFrame = 0
        var startedCycle: Int?
        var peakLeft: Float32 = 0
        var peakRight: Float32 = 0

        for cycle in 0..<cycleCount {
            let frames = tapFrames(inCycle: cycle, tapRate: tapRate, outputRate: outputRate)
            let output = runCycle(
                resampler,
                input: sineBuffer(tapRate: tapRate, startFrame: tapFrame, frameCount: frames),
                outputFrameCount: outputFrames
            )
            tapFrame += frames

            guard let producedFrames = output.frames else {
                XCTAssertNil(startedCycle, "output stopped at cycle \(cycle)", file: file, line: line)
                continue
            }

            if startedCycle == nil {
                startedCycle = cycle
            }
            XCTAssertFalse(output.isInputPassthrough, file: file, line: line)
            XCTAssertEqual(producedFrames, outputFrames, "cycle \(cycle)", file: file, line: line)
            XCTAssertTrue(output.samples.allSatisfy { $0.isFinite }, "cycle \(cycle)", file: file, line: line)
            XCTAssertFalse(output.rendered.contains(-99), "cycle \(cycle)", file: file, line: line)

            if cycle >= cycleCount / 2 {
                for frame in 0..<producedFrames {
                    peakLeft = max(peakLeft, abs(output.samples[frame * 2]))
                    peakRight = max(peakRight, abs(output.samples[frame * 2 + 1]))
                }
            }
        }

        // Output starts right after detection, once this cycle's input plus ≈ one cycle is queued.
        let start = try XCTUnwrap(startedCycle, file: file, line: line)
        XCTAssertLessThanOrEqual(start, ProcessTapDirectOutputResampler.detectionCycleCount, file: file, line: line)

        let expectedRatio = tapRate / outputRate
        let snapshot = resampler.snapshot()
        XCTAssertEqual(snapshot.path, .converting, file: file, line: line)
        XCTAssertEqual(snapshot.cycleCount, cycleCount, file: file, line: line)
        XCTAssertEqual(snapshot.totalInputFrames, tapFrame, file: file, line: line)
        XCTAssertEqual(snapshot.totalOutputFrames, cycleCount * outputFrames, file: file, line: line)
        XCTAssertEqual(snapshot.averageOutputFramesPerCycle, Double(outputFrames), accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(snapshot.averageInputFramesPerCycle, Double(outputFrames) * expectedRatio, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(snapshot.measuredRatio, expectedRatio, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(snapshot.expectedRatio, expectedRatio, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(snapshot.underrunCount, 0, file: file, line: line)
        XCTAssertEqual(snapshot.overflowCount, 0, file: file, line: line)
        // Latency target: about one cycle of tap frames stays queued.
        let tapFramesPerCycle = Int((Double(outputFrames) * expectedRatio).rounded(.up))
        XCTAssertLessThanOrEqual(resampler.fifo.availableFrames, 2 * tapFramesPerCycle, file: file, line: line)
        // The sine keeps its level through the converter (left 0.5, right 0.25).
        XCTAssertEqual(Double(peakLeft), 0.5, accuracy: 0.05, file: file, line: line)
        XCTAssertEqual(Double(peakRight), 0.25, accuracy: 0.03, file: file, line: line)
    }

    /// Tap frames the HAL hands over in output cycle `cycle` when the tap runs at its own rate
    /// (cumulative rounding, e.g. 557 or 558 per 512-frame cycle for 48 kHz → 44.1 kHz).
    private func tapFrames(inCycle cycle: Int, tapRate: Double, outputRate: Double) -> Int {
        let framesPerCycle = Double(outputFrames) * tapRate / outputRate
        return Int((Double(cycle + 1) * framesPerCycle).rounded(.down))
            - Int((Double(cycle) * framesPerCycle).rounded(.down))
    }

    /// Interleaved stereo 1 kHz sine at `tapRate` (left 0.5, right 0.25 amplitude).
    private func sineBuffer(tapRate: Double, startFrame: Int, frameCount: Int) -> InputBuffer {
        var samples: [Float32] = []
        samples.reserveCapacity(frameCount * 2)
        for frame in startFrame..<(startFrame + frameCount) {
            let value = Float32(sin(2 * Double.pi * 1_000 * Double(frame) / tapRate))
            samples.append(0.5 * value)
            samples.append(0.25 * value)
        }
        return InputBuffer(channels: 2, samples: samples)
    }

    private func runCycle(
        _ resampler: ProcessTapDirectOutputResampler,
        input: InputBuffer,
        outputFrameCount: Int
    ) -> CycleOutput {
        let inputList = TestAudioBufferList(buffers: [input])
        let outputList = TestAudioBufferList(buffers: [
            InputBuffer(channels: 2, samples: Array(repeating: Float32(-99), count: outputFrameCount * 2))
        ])
        defer {
            inputList.deallocate()
            outputList.deallocate()
        }

        let inputData = UnsafePointer(inputList.pointer)
        guard let result = resampler.process(inputData, outputFrameCount: outputFrameCount) else {
            return CycleOutput(frames: nil, samples: [], rendered: [], isInputPassthrough: false)
        }

        let samples = interleavedSamples(of: result)
        var gainProvider = ProcessTapConstantFrameGainProvider(gain: 1)
        _ = ProcessTapDirectOutputCopier.render(result, into: outputList.pointer, gainProvider: &gainProvider)
        let channelCount = max(1, Int(result.pointee.mBuffers.mNumberChannels))

        return CycleOutput(
            frames: samples.count / channelCount,
            samples: samples,
            rendered: outputList.samples()[0],
            isInputPassthrough: result == inputData
        )
    }

    private func convertedSamples(_ resampler: ProcessTapDirectOutputResampler) -> [Float32] {
        interleavedSamples(of: resampler.convertedBufferList)
    }

    private func interleavedSamples(of list: UnsafePointer<AudioBufferList>) -> [Float32] {
        let buffer = list.pointee.mBuffers
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride
        guard let data = buffer.mData, sampleCount > 0 else {
            return []
        }

        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float32.self), count: sampleCount))
    }
}
