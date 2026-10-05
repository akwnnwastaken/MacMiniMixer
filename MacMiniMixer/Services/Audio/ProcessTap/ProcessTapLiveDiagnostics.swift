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
    /// True while real audio is flowing but the fresh output queue is still establishing its
    /// playback cadence (the startup-warmup window). During it a transient queue drain is not
    /// counted as `outputStarvationCount`, and the UI shows a neutral "Starting audio…" state
    /// rather than alarming Starv. Defaulted so existing diagnostics producers/tests need not
    /// supply it.
    let isWarmingUpOutput: Bool
    /// Direct aggregate output with sample-rate conversion only (0 otherwise): measured average tap
    /// frames delivered and output frames rendered per IOProc cycle. Their ratio shows whether the
    /// HAL hands the tap over at its own rate (≈ tap rate / output rate) or already resampled (≈ 1).
    /// In that mode the resampler's FIFO underruns are reported as `outputStarvationCount` and its
    /// overflows (oldest frames dropped) as `droppedBufferCount`. Defaulted so existing producers
    /// and tests need not supply them.
    let averageTapFramesPerCycle: Double
    let averageOutputFramesPerCycle: Double

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
        outputStarvationCount: Int = 0,
        isWarmingUpOutput: Bool = false,
        averageTapFramesPerCycle: Double = 0,
        averageOutputFramesPerCycle: Double = 0
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
        self.isWarmingUpOutput = isWarmingUpOutput
        self.averageTapFramesPerCycle = averageTapFramesPerCycle
        self.averageOutputFramesPerCycle = averageOutputFramesPerCycle
    }

    var audioDetected: Bool {
        peakLevel > AppConstants.processTapRealAudioPeakThreshold
    }

    var totalFailureCount: Int {
        droppedBufferCount + enqueueFailureCount + copyFailureCount
    }

    /// Neutral live-session status, or nil once the session is in steady state (show normal
    /// diagnostics then). Three transient states are distinguished so a healthy session is never
    /// mistaken for a broken route:
    ///   - no real audio yet → "Waiting for app audio" / "No app audio detected" (silent session);
    ///   - real audio flowing but the fresh queue still warming up → "Starting audio…" (a transient
    ///     startup drain here is expected and not counted as Starv);
    ///   - warmed up, real audio flowing → nil (normal diagnostics; any Starv now is real).
    var realAudioStatusText: String? {
        if !audioDetected {
            return callbackCount == 0 ? "Waiting for app audio" : "No app audio detected"
        }

        if isWarmingUpOutput {
            return "Starting audio…"
        }

        return nil
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
