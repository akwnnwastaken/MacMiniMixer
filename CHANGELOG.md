# Changelog

All notable changes to MacMiniMixer are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project is experimental and pre-1.0; version numbers track internal milestones
rather than tagged releases. MacMiniMixer is not a finished Windows Volume Mixer
replacement: app rows are mock-only by default, only one real-controlled session can be
active at a time, and production multi-app per-application control is not implemented.

## [Unreleased]

### Added
- System sleep/wake lifecycle handling: a typed `.systemSleep` live-stop reason; on system
  sleep all active and pending Process Tap work (Product Real Control, Advanced manual live
  control, Two-App Readiness, and the related diagnostic/probe/resolver work) is torn down
  synchronously; on system wake the app performs refresh-only reconciliation (output devices,
  system volume/mute, visible app list) and does not automatically restart any session. The
  global Real App Control preference is preserved across sleep/wake; the user re-engages by
  interacting with a row again.
- Persistent read-only indicator for output devices that do not expose a writable volume
  API, replacing the previous transient-only warning.
- Accessibility labels, values, and hints for app rows (volume slider, mute button,
  resolving/real state), the system output slider and mute button, and output-device
  selection rows.

### Changed
- Product Real App Control now supports up to **three** simultaneous apps (raised from two).
  A three-session smoke passed on one real Mac (Release; measured CPU ≈ 19%, thermal nominal,
  clean per-app stop / Stop All / output-change / repeated start-stop). The active banner
  summarises three or more apps as "first two names +1 more" with "Stop All". Going beyond three
  (`N > 3`) remains deferred (see `docs/DECISIONS.md`). The Advanced Two-App Readiness diagnostic
  is unrelated and stays a two-session measurement tool.
- `SystemOutputCoordinator` now tracks per-device volume writability
  (`isSystemOutputVolumeWritable`), updated from the most recent write attempt and reset
  when the selected output device changes.

## [v0.12] — Browser/helper row resolution

### Added
- Global Real App Control can resolve a browser/web helper process internally for a single
  user-facing row when the user explicitly interacts with that row (e.g. YouTube/Safari).
- Fast helper resolution path for browser rows with a validation-first in-memory helper
  cache; helper mappings are reused only after validating the PID still exists and remains
  Core Audio tap-eligible.
- Advanced auto-detect ("Find audio helper") flow that probes eligible helper candidates
  with short unmuted diagnostics and scores them by detected audio, RMS, peak, and callbacks.
- Persistent Product Real App Control sessions while healthy (indefinite timeout policy).
- Product Real Control lifecycle characterization tests and extracted
  `ProductRealControlState` state/model helpers.

### Changed
- Helper PID/process names stay hidden from the main mixer UI.
- Incremental `MixerViewModel` split continued via extracted coordinators:
  `AdvancedHelperDiscoveryCoordinator`, `SystemOutputCoordinator`,
  `AdvancedProcessTapDiagnosticsCoordinator`, `AdvancedLiveControlCoordinator`, and
  `TwoAppReadinessCoordinator`.

## [v0.11] — Process Tap session foundation

### Added
- Internal `ProcessTapLiveSessionManager` foundation for future multi-session work.
- Advanced Two-App Readiness test for short-lived multi-session diagnostics (up to two
  short-lived diagnostic sessions), with per-session callbacks, peak/RMS, queued buffers,
  drops, failures, and gain.
- Advanced Helper Process Discovery for browser/helper/content process candidates, manual
  Candidate Probe, and manual helper target selection.
- Helper candidate audio probe and helper-target support in Process Tap Test, Replay Probe,
  and Two-App Readiness.

## [v0.10.1] — Hardening and tooling

### Added
- MIT License.
- GitHub Actions build/test CI.
- Initial XCTest coverage for helper discovery, helper resolver/cache, permission
  messaging, live session management, and diagnostics.
- Structured `os.Logger` diagnostics for Process Tap.
- macOS 14.2 Process Tap availability guards (deployment target remains macOS 13.0).
- Architecture documentation.

### Changed
- Replaced brittle string-based result checks with typed outcomes.
- Made Process Tap resource cleanup thread-safe.
- Unified Process Tap diagnostics accumulation and extracted a shared Process Tap output
  buffer copier with unit tests.

## [v0.10] — Initial prototype

### Added
- Native macOS menu bar app using SwiftUI `MenuBarExtra` with a compact mixer panel.
- System output volume read/set and mute/unmute (volume-to-zero plus restore).
- Real output device listing and default-device switching via public Core Audio APIs.
- Live refresh of output devices and system volume while the panel is open.
- Running application discovery via `NSWorkspace` with real app icons.
- Mock per-app sliders and mute controls for UI/UX development.
- Experimental Process Tap Test, Mute Probe, and Replay Probe (25%/50%/75%/100% gain) in a
  collapsed Advanced section.
- Experimental one-app Live Control session with start/stop, gain, smoothing, safety
  timeout, and cleanup.
</content>
</invoke>
