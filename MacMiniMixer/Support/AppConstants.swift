import Foundation

enum AppConstants {
    static let appTitle = "MacMiniMixer"
    static let volumeRange: ClosedRange<Double> = 0...100
    static let outputDeviceRefreshInterval: TimeInterval = 2
    static let systemVolumeRefreshInterval: TimeInterval = 1
    static let statusMessageAutoClearDelay: TimeInterval = 2.5
    static let processTapDiagnosticDuration: TimeInterval = 2.5
    static let processTapHelperAutoDetectDuration: TimeInterval = 1.25
    static let processTapHelperEarlyAcceptRMSLevel: Double = 0.01
    static let processTapHelperEarlyAcceptPeakLevel: Double = 0.05
    static let processTapReplayProbeDuration: TimeInterval = 2.5
    static let processTapLiveControlMaxDuration: TimeInterval = 60
    static let processTapTwoAppReadinessDuration: TimeInterval = 10
    /// Optional cap on concurrent live Process Tap sessions for Product Real Control; `nil` means
    /// unlimited. Owner decision: Product Real Control has **no app-count limit** — like the
    /// Windows Volume Mixer, every app the user interacts with (while the global "Real app control"
    /// toggle is ON) can be controlled at the same time. Each session owns its own process tap +
    /// private aggregate device + IOProc + replay AudioQueue, so CPU scales roughly linearly per
    /// active app; a resource failure for an extra session surfaces through the normal per-app
    /// start-failure path ("Could not start live control for this app"), not a preemptive limit.
    /// The cap mechanism itself is kept and stays testable: the shared session manager and the
    /// product start preflight (count guard + "supports N apps at a time" message) both honour a
    /// non-nil value; it is simply off by default. History: capped at 2, then 3 (Phase 5a) — see
    /// docs/PLAN_MULTI_APP.md / DECISIONS.md.
    static let maxConcurrentLiveSessions: Int? = nil
    static let processTapLiveFadeInDuration: TimeInterval = 0.06
    static let processTapLiveFadeOutDuration: TimeInterval = 0.04
    /// Live output path for Process Tap live control (Product Real and Advanced live). The direct
    /// aggregate path renders the tap straight into the output device on one clock (no AudioQueue),
    /// which removes the two-clock hand-off behind random crackle. A/B fallback without a rebuild:
    /// `defaults write <bundle id> MacMiniMixerLiveOutputMode audioQueue` (read per controller).
    static let processTapLiveDefaultOutputMode: ProcessTapLiveOutputMode = .directAggregateOutput
    static let processTapLiveOutputModeDefaultsKey = "MacMiniMixerLiveOutputMode"
    static let processTapLivePrimingBufferCount = 2
    static let processTapReplayFallbackSampleRate: Double = 48_000
    static let processTapReplayBufferCount = 8
    static let processTapReplayBufferByteSize: UInt32 = 65_536
    /// Number of successful buffer enqueues (including the priming buffers) after which a fresh live
    /// output queue is considered warmed up, so a drained queue starts counting as real output
    /// starvation. Below this, the queue is still establishing its playback cadence and a transient
    /// drain is expected even on a healthy route (the residual Starv seen after a per-app Real
    /// restart). At ~one IOProc callback per enqueue this is several full pool cycles — a short
    /// startup grace, not a mask for steady-state starvation. Tunable after real-hardware retest.
    static let processTapReplayStartupWarmupBufferCount = 48
    static let processTapLevelMeterUpdateInterval: TimeInterval = 0.1
    /// Minimum spacing between live-diagnostics publishes to the UI. The audio path still measures
    /// on every callback and the diagnostics timer still ticks at `processTapLevelMeterUpdateInterval`,
    /// but the SwiftUI-facing refresh is rate-limited to ~4 Hz so the panel does not redraw on every
    /// tick (×N sessions). Start/stop/final samples and failure/starvation escalations bypass this.
    static let processTapLiveDiagnosticsPublishMinimumIntervalMilliseconds: Double = 250
    /// How many times teardown attempts to destroy the process tap before giving up. The tap
    /// carries `.mutedWhenTapped`, so a tap that survives teardown leaves the tapped apps muted
    /// inside coreaudiod until the app or coreaudiod restarts. During an output-device route
    /// transition the first `AudioHardwareDestroyProcessTap` can fail transiently; retrying gives
    /// the route time to settle so the mute is released rather than leaked.
    static let processTapDestroyMaxAttempts = 3
    /// Delay between process-tap destroy attempts, to let an in-flux Core Audio route settle
    /// before retrying. Runs off the main thread (teardown already sleeps for the fade-out there).
    static let processTapDestroyRetryDelay: TimeInterval = 0.15
    /// How long a new Product Real start waits, after the previous Product Real session teardown
    /// has finished, before creating its tap/aggregate/IOProc/AudioQueue. coreaudiod releases the
    /// prior private aggregate/tap and resettles the shared output route asynchronously after our
    /// Swift cleanup returns; creating a fresh AudioQueue inside that window can start with poor
    /// cadence and briefly drain (nondeterministic Starv after changing app combinations). This is
    /// a suspension off the main thread, not a blocking sleep, and only applies when a Product Real
    /// teardown actually preceded the start.
    static let productRealStartAfterStopSettleDelay: TimeInterval = 0.2
    /// Absolute sample-peak above which a Process Tap input callback counts as real (non-silent)
    /// audio rather than silence. Used both to report "audio detected" and to gate output
    /// starvation counting: a Real session on an app that has not produced audio yet must not log
    /// starvation just because its output queue drains (it is waiting for audio, not underrunning).
    static let processTapRealAudioPeakThreshold: Double = 0.001
    static let defaultSystemOutputRestoreVolume: Double = 50

    enum Layout {
        static let panelWidth: CGFloat = 352
        static let panelPadding: CGFloat = 12
        static let panelSpacing: CGFloat = 9
        static let sectionSpacing: CGFloat = 8
        static let sectionPadding: CGFloat = 10
        static let cornerRadius: CGFloat = 14
        static let panelCornerRadius: CGFloat = 22
        static let rowCornerRadius: CGFloat = 10
        static let rowSpacing: CGFloat = 8
        static let rowInnerSpacing: CGFloat = 5
        static let rowIconSize: CGFloat = 36
        static let rowIconImageArtworkSize: CGFloat = 31
        static let rowIconSymbolFrameSize: CGFloat = 36
        static let rowIconSymbolSize: CGFloat = 18
        static let rowIconMuteBadgeSize: CGFloat = 14
        static let rowLiveButtonSize: CGFloat = 24
        static let headerButtonSize: CGFloat = 28
        static let appNameWidth: CGFloat = 66
        static let volumeValueWidth: CGFloat = 28
        static let deviceRowSpacing: CGFloat = 2
        static let appRowApproxHeight: CGFloat = 48
        static let appListMinHeight: CGFloat = 56
        static let appListMaxHeight: CGFloat = 450
    }
}
