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
