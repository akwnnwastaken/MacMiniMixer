# Changelog

All notable changes to MacMiniMixer are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project is experimental and pre-1.0; version numbers track internal milestones
rather than tagged public releases. MacMiniMixer is not a finished Windows Volume Mixer
replacement: normal app-row sliders are UI-state/preview by default, and Product Real Control is
experimental and opt-in. Since the `[Unreleased]` owner decision below, Product Real Control has no
app-count limit, but real-hardware characterization only covers up to three concurrent sessions,
so production-grade multi-app per-application control is not claimed. Older entries that say
"capped at three" / "`N > 3` deferred" describe the state at that time.

## [Unreleased]

### Added
- **Queued Product Real start lane.** At most one Product Real helper resolution or product start is
  in flight at a time; a start requested meanwhile (slider, mute, or row toggle; direct-PID or helper
  row) is queued FIFO, the row shows the existing pending badge, and the entry re-runs its full
  preflight against current state when the lane frees up (gain = the slider value at that moment).
  Queued starts are dropped by per-app stop, Stop All, Real off, output-device change, sleep,
  termination, panel close, app exit, and when their app quits. Direct-PID starts queue too, because
  a helper probe creates its own tap + aggregate outside the lifecycle/settle gates. New
  `ProductRealStartLaneTests` plus state, stop, facade, and view-model coverage (`774268a`).
- **Proactive system-output volume writability probe.** `SystemVolumeControlling` gained a
  read-only `isCurrentOutputVolumeSettable()` (`AudioObjectHasProperty` /
  `AudioObjectIsPropertySettable` on exactly the addresses the write path uses; the default
  implementation returns `nil` = unknown). `SystemOutputCoordinator` probes at init, on an
  output-device change, and after a successful device selection, so the "Read-only" badge appears
  before the first slider drag; `nil` assumes writable (no false badge) and rejected writes still
  flip the flag. 20 new `SystemOutputCoordinatorTests`, including coordinator failure paths
  (`3c2f4e8`).
- **Accessibility coverage completed** for the rest of the menu bar UI (macOS 13-compatible SwiftUI
  modifiers only, no layout or behavior change): panel header/section captions, the Output devices
  button, the "Real app control" and "Show all" toggles, the Advanced disclosure, severity-prefixed
  status banner, the read-only badge, the device list, the Advanced Process Tap test view, helper
  discovery, and Two-App Readiness (`3a84483`).
- **Release packaging.** `scripts/package-app.sh` builds Release, ad-hoc signs a staged copy (not
  notarized), and writes `dist/MacMiniMixer-<version>[-<label>].zip` + `.sha256`. The `Build`
  workflow gained a `package` job that uploads the zip as the `MacMiniMixer-app` artifact (14 days),
  plus `permissions: contents: read` and a cancel-in-progress concurrency group. A new `Release`
  workflow runs on `v*` tags (tests → package → tag must equal `v` + `MARKETING_VERSION` → **draft**
  GitHub Release) and on manual dispatch (artifact only). Maintainer guide in `docs/RELEASING.md`.
  No release or tag has been cut (`e0a60b4`).
- **Per-session starvation attribution logging.** Product Real starvation escalations are logged
  with the session id and app, rate-shaped per session (first nonzero Starv, then each 100-count
  bucket, and any Drops/Fail increase immediately) so a spike cannot flood the log. Diagnostics only:
  audio, state, UI, and callback acceptance are unchanged (`617b7f2`).
- `NSHumanReadableCopyright` in `Info.plist`: "Copyright © 2026 Ahmed Tuğra Kasem. MIT License."
  (`1469eb2`).

### Changed
- **Product Real Control has no app-count limit (owner decision).** Like the Windows Volume Mixer,
  every app the user interacts with (global "Real app control" ON) can be Real at the same time.
  `AppConstants.maxConcurrentLiveSessions` is now `Int? = nil` (unlimited),
  `ProcessTapLiveSessionManager` takes `maxSessions: Int?`, and the start coordinator keeps an
  injectable `maxConcurrentSessions: Int?` so tests can still prove the cap mechanism and its
  message. Each session still owns its own tap + private aggregate + IOProc + `AudioQueue`, so CPU
  grows per active app, and a resource failure shows the normal per-app start-failure warning.
  Real-hardware characterization beyond three sessions has **not** been done. This supersedes the
  "Cap stays 3; `N > 3` deferred" notes in the entries below (`08d49bc`).
- Product Real start requests made while another resolution/start is in flight are queued instead
  of rejected: "Finish resolving app audio first", "Stop active live control first", and "Process Tap
  is already busy" no longer appear for product rows just because another product start is running
  (they can still appear while an Advanced diagnostic or manual session is active). The slider/mute
  auto-start moved from `MixerViewModel` into `ProductRealStartCoordinator.requestAutomaticStart(for:)`
  (`774268a`).
- `MockAudioController` renamed to `PreviewAudioStateController` and documented as the production
  in-memory preview-state `AudioControlling` (it never touched Core Audio). The unused production
  mocks `MockSystemVolumeController`, `MockSystemVolumeReader`, `MockOutputDeviceController`, and
  `MockProcessTapTester` were deleted; `MockApplicationLister` and `MockOutputDeviceLister` stay as
  the fallbacks of the real listers. No behavior change (`54d351b`, `f94a5cd`).
- **Product Real coordinator internal split completed: `ProductRealStartCoordinator` extracted, facade
  slimmed** (internal refactor, no behavior change). Following the state-store and stop-coordinator
  extractions, the start + resolution path (app-audio resolution + task ownership/`deinit`, start
  preflight, both `startExperimentalControl` overloads, async start body, cached-helper retry,
  stale-start rejection/cleanup, settle-gate ordering) moved into `ProductRealStartCoordinator`, and
  `ProductRealControlCoordinator` was slimmed to a **true facade** (~170 lines, no start/stop logic,
  no redundant stored dependencies). Final architecture: the facade composes one
  `ProductRealControlStateStore` (single state source), `ProductRealStartCoordinator`, and
  `ProductRealStopCoordinator`; the three Start↔Stop cross-edges are narrow `[weak self]` facade-wired
  closures (no sibling ownership, no retain cycle). The facade **public API and initializer signature
  are unchanged** and **`MixerViewModel` is byte-for-byte unchanged**. Start/resolution tests moved to
  `ProductRealStartCoordinatorTests` (facade forwarding + cross-edge integration tests retained). Full
  suite green (**414 passed / 0 failed / 0 skipped**). Cap stays **3**; `N > 3` deferred;
  `MARKETING_VERSION` unchanged; no tag/release.
- **Product Real coordinator internal split: `ProductRealControlStateStore` + `ProductRealStopCoordinator`**
  (internal refactor, no behavior change). `ProductRealControlCoordinator` is now a thin facade that
  composes two internal sub-objects behind its **unchanged public API**: `ProductRealControlStateStore`
  (the single `ProductRealControlState` source and `onWillChange` notification storage — one shared
  instance, notifies exactly once before each write, never on reads) and `ProductRealStopCoordinator`
  (the product-only stop path: per-app stop, Stop All, stop callback, app-exit cleanup, hard-teardown
  reset, active-name helper). `MixerViewModel` is **unchanged** and still knows only the facade;
  start/resolution logic remains in the facade for now; the Start↔Stop cross-edges are narrow closures
  (no ownership cycle). Focused `ProductRealControlStateStoreTests` and `ProductRealStopCoordinatorTests`
  added. Full suite green (**407 passed / 0 failed / 0 skipped**). Cap stays **3**; `N > 3` deferred;
  `MARKETING_VERSION` unchanged; no tag/release.
- **Product Real Control stop path extracted into `ProductRealControlCoordinator`** (internal
  refactor, no behavior change). Following the start-path extraction, the coordinator now also owns
  the full Product Real **stop** path: the per-app stop leaf (`stopExperimentalControl(for:reason:)`),
  the Stop All core (`stopProductLiveSessions(reason:)`), the engine stop callback
  (`handleProductLiveControlStopped(...)`), the app-exit slice (`stopRealControlForExitedTargetApps()`),
  and the hard-teardown Product Real state reset (`tearDownProductStateForHardStop()`). The
  cross-subsystem router (`stopProcessTapLiveControl`), the **shared** display cleanup
  (`applyLiveControlStoppedDisplay`, reached through a new narrow seam callback and also used by
  advanced-manual stop), the lifecycle / sleep / wake / termination entry points, the
  output-device-change fan-out, and the `tearDownAllProcessTapWork` teardown fan-out all
  **intentionally remain** in `MixerViewModel` (they are not product-only). Hard teardown preserved
  exact ordering by moving only the Product Real state-reset sub-block. Migrated in small,
  independently-tested steps (per-app leaf → Stop All core + stop callback → app-exit slice →
  hard-teardown state reset) rather than one large refactor. Full suite green
  (387 passed / 0 failed / 0 skipped). Product Real Control remains capped at **three** concurrent
  sessions; `N > 3` stays deferred. `MARKETING_VERSION` unchanged; no tag/release.
- **Product Real Control start path extracted into `ProductRealControlCoordinator`** (internal
  refactor, no behavior change). The coordinator now owns `ProductRealControlState`, the app-audio
  resolution task and resolution handling, stale-start cleanup, and the async Product Real start
  path (both the `startExperimentalControl` preflight and the resolved/async start body). It talks
  to `MixerViewModel` only through the narrow `ProductRealControlSideEffects` /
  `ProductRealControlContext` seam. Migrated in small, independently-tested steps (seam → state
  ownership → resolution slice → stale cleanup → async start body) rather than one large refactor.
  Product Real Control remains capped at **three** concurrent sessions; `N > 3` stays deferred.
  `MARKETING_VERSION` unchanged; no tag/release.

### Fixed
- Quitting the app selected in the Advanced picker no longer stops every Product Real session. The
  selection-refresh path now stops only Advanced manual control; an exited app's own product session
  is still stopped per app and every other session keeps running (`da2b06e`).
- The cached-helper retry (fresh resolve after a stale cached helper fails to start) now runs while
  other Product Real sessions are active; only the mutually exclusive Advanced manual session
  suppresses it. Previously any other running app turned a stale cache into "Could not start live
  control for this app" (`c57bf37`).
- The Advanced live-diagnostics card no longer shows interleaved values from concurrent sessions:
  only the focused (newest) Product Real session publishes there, focus falls back to a surviving
  session when the focused one ends, and per-callback publishing happens only while the Advanced
  section is on screen (a plain, non-`@Published` `isLiveDiagnosticsDisplayVisible`). Before, every
  session published ~4 times per second, each publish firing `objectWillChange` twice and
  re-rendering the panel and menu bar scene even with the panel closed or Advanced collapsed. Start/failure/stop display writes and the attribution logging are not gated
  (`5a78656`).
- Stop All now also cancels an in-flight helper resolution, so its late result can no longer start a
  session after the user stopped everything (`774268a`).

## [v0.14] - Unreleased

**Internal stability checkpoint — not a public release.** This is an unreleased v0.14 baseline
focused on **Product Real Control** teardown and starvation handling, driven by real-hardware
feedback. It is not shipped: `MARKETING_VERSION` is unchanged, no tag/release is cut, and the app
is not yet finished enough for a public release (the README may still describe the earlier
one-session state and Product Real UX still has caveats). Product Real Control remains experimental
and capped at **three** simultaneous sessions; going beyond three (`N > 3`) is still deferred.
Requires macOS 14.2+ for Process Tap support.

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
- **Rapid Real-toggle guard.** A per-app pending-operation state now ignores toggle / slider
  auto-start attempts for a row while its Product Real start or stop is in flight, and the row shows
  a non-interactive "working" badge. This is a UI/view-model guard layered above the settle and
  lifecycle-serialization gates so a burst of rapid on/off clicks cannot pile up Core Audio
  create/destroy churn (crackle/Starv). The audio callback is unchanged; cap stays 3.

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
