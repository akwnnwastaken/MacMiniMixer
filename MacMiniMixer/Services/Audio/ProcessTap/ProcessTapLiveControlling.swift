import Foundation

enum ProcessTapLiveTimeoutPolicy: Equatable, Sendable {
    case limited(TimeInterval)
    case indefinite

    static let standard = ProcessTapLiveTimeoutPolicy.limited(AppConstants.processTapLiveControlMaxDuration)
}

/// How a live Process Tap session plays the tapped app's audio back out.
enum ProcessTapLiveOutputMode: String, Equatable, Sendable {
    /// One private aggregate device = the default output device (main/clock sub-device) + the
    /// process tap, with one IOProc that reads the tap input and writes the device output in the
    /// same callback, on one clock. No AudioQueue and no cross-thread buffer hand-off.
    case directAggregateOutput
    /// Legacy path: a tap-only aggregate's IOProc hands buffers to a separate AudioQueue that runs
    /// on the output device's clock. Kept as an A/B fallback.
    case audioQueue

    /// Parses a stored override (`AppConstants.processTapLiveOutputModeDefaultsKey`). Only a known
    /// value (trimmed, case-insensitive) changes the mode; nil, empty or unknown yields `defaultMode`.
    static func resolve(
        storedValue: String?,
        defaultMode: ProcessTapLiveOutputMode = AppConstants.processTapLiveDefaultOutputMode
    ) -> ProcessTapLiveOutputMode {
        guard let storedValue else {
            return defaultMode
        }

        let normalizedValue = storedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalizedValue {
        case "audioqueue":
            return .audioQueue
        case "directaggregateoutput":
            return .directAggregateOutput
        default:
            return defaultMode
        }
    }

    /// The mode a live controller uses, read from `userDefaults` when the controller is created.
    static func configured(userDefaults: UserDefaults = .standard) -> ProcessTapLiveOutputMode {
        resolve(storedValue: userDefaults.string(forKey: AppConstants.processTapLiveOutputModeDefaultsKey))
    }
}

/// Whether the direct aggregate output path converts a tap whose sample rate differs from the output
/// device's (`.on`, default), or falls back to the AudioQueue path on a rate mismatch (`.off`, the
/// behavior before conversion existed). Safety valve without a rebuild:
/// `defaults write <bundle id> MacMiniMixerDirectResample off` (read per controller).
enum ProcessTapDirectResampleMode: String, Equatable, Sendable {
    case on
    case off

    /// Parses a stored override (`AppConstants.processTapDirectResampleDefaultsKey`): "off" (also
    /// "false", "no", "0"; trimmed, case-insensitive) disables conversion; anything else keeps the
    /// default `.on`.
    static func resolve(storedValue: String?) -> ProcessTapDirectResampleMode {
        guard let storedValue else {
            return AppConstants.processTapDirectResampleDefaultMode
        }

        switch storedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off", "false", "no", "0":
            return .off
        case "on", "true", "yes", "1":
            return .on
        default:
            return AppConstants.processTapDirectResampleDefaultMode
        }
    }

    /// The mode a live controller uses, read from `userDefaults` when the controller is created.
    static func configured(userDefaults: UserDefaults = .standard) -> ProcessTapDirectResampleMode {
        resolve(storedValue: userDefaults.string(forKey: AppConstants.processTapDirectResampleDefaultsKey))
    }
}

protocol ProcessTapLiveControlling: Sendable {
    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption)

    @discardableResult
    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult?
}

extension ProcessTapLiveControlling {
    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        await startLiveControl(
            for: target,
            gain: gain,
            timeoutPolicy: .standard,
            onDiagnostics: onDiagnostics,
            onStopped: onStopped
        )
    }
}
