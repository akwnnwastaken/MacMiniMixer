# Changelog

All notable changes to MacMiniMixer are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project is experimental and pre-1.0; version numbers track internal milestones
rather than tagged releases. MacMiniMixer is not a finished Windows Volume Mixer
replacement: app rows are mock-only by default, only one real-controlled session can be
active at a time, and production multi-app per-application control is not implemented.

## [Unreleased]

## [v0.14] - 2026-07-03

Stability release focused on **Product Real Control** teardown and starvation handling, driven by
real-hardware feedback. Product Real Control remains experimental and capped at **three**
simultaneous sessions; going beyond three (`N > 3`) is still deferred. Requires macOS 14.2+ for
Process Tap support.

### Changed
- **Product Real teardown hardening.** Process-tap destruction now retries on transient failure and
  reports a persistent failure as a fault instead of a clean stop. This makes cleanup safer when a
  `.mutedWhenTapped` tap has trouble tearing down — a leaked muted tap could otherwise leave apps
  muted inside coreaudiod until the app or coreaudiod restarts.
- **Output-queue teardown ordering.** The live output queue is now disposed **after** the IOProc is
  stopped/destroyed, so the producer is gone before the queue goes away. This removes self-inflicted
  Drops/Fail during output-device transitions and teardown.
- **Stop→start settle gate.** A Product Real start now waits for any recent teardown to finish and a
  short settle window before creating new Core Audio objects, so a fresh tap/aggregate is not built
  while coreaudiod is still releasing the previous one.
- **Core Audio lifecycle serialization.** Product Real start/stop create/destroy operations are
  serialized so no two run at once. This reduces shared-route churn during app combination changes
  (stop one app, start another while a third stays active), which previously caused audible clicks.
- **Starvation diagnostics improved.** A silent app now shows a neutral "Waiting for app audio" /
  "No app audio detected" state instead of false starvation, and a freshly (re)started output queue
  gets a short startup warmup so its first-cadence transient is not reported as a real underrun.
  Steady-state starvation is still counted.

### Fixed
- Swift 6 language-mode test failure: `NSLock.lock()/unlock()` called from an async context is
  replaced with scoped `withLock` (async-safe locking).
- Full-suite test flake: live-control test waits are now bounded by a wall-clock deadline instead of
  a fixed `Task.yield()` budget, so they no longer time out spuriously under parallel-suite load.

### Validated
- Real-hardware normal-use testing (one Mac): three Product Real sessions ran cleanly; per-app
  stop/start during use was clean; Drops/Fail/Starv stayed 0 during normal usage; CPU settled
  roughly in the 20–35% range depending on panel / Activity Monitor state; **no
  `sudo killall coreaudiod`** was needed in the final normal-use retest.
- The 30–60 minute three-session long-run smoke **PASSED (with caveat)** — see below.

### Known limitations / caveats
- **Rapid manual toggling.** Extremely rapid repeated Real on/off toggling can still cause
  crackle/Starv if spammed aggressively. The intended flow is Real Control staying enabled during
  use, not rapid manual toggling, so this is not a normal-use blocker. Tracked for v0.15 as a
  UI-level debounce / disabled pending-operation state.
- Product Real Control remains **experimental**; `N > 3` simultaneous sessions remains deferred.
- The previously-tried unsafe default-output-device observer was **not** reintroduced;
  output-device-change teardown stays on the existing consolidated path.
- Requires **macOS 14.2+** for Process Tap support.

## [v0.13] - 2026-06-10

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

### Fixed
- Two-App Readiness coordinator tests were made deterministic (thread-safe test doubles and
  waits bound to the asserted state) to remove intermittent CI failures. Test-only; no runtime
  behaviour change.

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
