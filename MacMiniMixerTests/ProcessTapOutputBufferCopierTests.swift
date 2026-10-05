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

    func testFormatCheckRejectsSampleRateMismatch() {
        XCTAssertNotNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(sampleRate: 44_100, channels: 2),
            output: pcmFormat(sampleRate: 48_000, channels: 2)
        ))
        XCTAssertNotNil(ProcessTapDirectOutputCopier.formatIncompatibility(
            input: pcmFormat(sampleRate: 0, channels: 2),
            output: pcmFormat(sampleRate: 0, channels: 2)
        ))
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
