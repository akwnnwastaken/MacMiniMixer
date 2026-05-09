import Foundation

struct ProcessTapLiveDiagnostics: Equatable, Sendable {
    let selectedGain: ProcessTapReplayGainOption
    let callbackCount: Int
    let peakLevel: Double
    let rmsLevel: Double
    let enqueuedBufferCount: Int
    let droppedBufferCount: Int
    let enqueueFailureCount: Int
    let copyFailureCount: Int

    var audioDetected: Bool {
        peakLevel > 0.001
    }

    var totalFailureCount: Int {
        droppedBufferCount + enqueueFailureCount + copyFailureCount
    }

    var progress: ProcessTapDiagnosticProgress {
        ProcessTapDiagnosticProgress(
            callbackCount: callbackCount,
            peakLevel: peakLevel,
            rmsLevel: rmsLevel,
            audioDetected: audioDetected
        )
    }
}
