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
    /// Diagnostic-only timing/starvation signals (default 0). They surface glitches that the
    /// drop/failure counters miss: a callback stall (`maxCallbackGapMilliseconds` /
    /// `lateCallbackCount`) and the AudioQueue draining while playing (`outputStarvationCount`).
    /// Defaulted so existing diagnostics producers (probes, tests) need not supply them.
    let maxCallbackGapMilliseconds: Double
    let lateCallbackCount: Int
    let outputStarvationCount: Int

    init(
        selectedGain: ProcessTapReplayGainOption,
        callbackCount: Int,
        peakLevel: Double,
        rmsLevel: Double,
        enqueuedBufferCount: Int,
        droppedBufferCount: Int,
        enqueueFailureCount: Int,
        copyFailureCount: Int,
        maxCallbackGapMilliseconds: Double = 0,
        lateCallbackCount: Int = 0,
        outputStarvationCount: Int = 0
    ) {
        self.selectedGain = selectedGain
        self.callbackCount = callbackCount
        self.peakLevel = peakLevel
        self.rmsLevel = rmsLevel
        self.enqueuedBufferCount = enqueuedBufferCount
        self.droppedBufferCount = droppedBufferCount
        self.enqueueFailureCount = enqueueFailureCount
        self.copyFailureCount = copyFailureCount
        self.maxCallbackGapMilliseconds = maxCallbackGapMilliseconds
        self.lateCallbackCount = lateCallbackCount
        self.outputStarvationCount = outputStarvationCount
    }

    var audioDetected: Bool {
        peakLevel > 0.001
    }

    var totalFailureCount: Int {
        droppedBufferCount + enqueueFailureCount + copyFailureCount
    }

    /// Compact, one-line summary of the diagnostic-only timing/starvation signals, for the live
    /// Advanced diagnostics card (kept off the normal user banner). Pure/testable so the live card
    /// does not depend on the truncation-prone stop-result detail string.
    var timingSummaryText: String {
        "Gap \(String(format: "%.1f", maxCallbackGapMilliseconds))ms · Late \(lateCallbackCount) · Starv \(outputStarvationCount)"
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
