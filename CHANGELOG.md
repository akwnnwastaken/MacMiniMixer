# Changelog

All notable changes to MacMiniMixer are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project is experimental and pre-1.0. v0.14 is the first public release (an ad-hoc signed,
not notarized `.zip`, published as a GitHub pre-release); v0.10 to v0.13 were internal milestones,
not tagged public releases. MacMiniMixer is not a finished Windows Volume Mixer replacement:
app-row sliders are UI-state/preview until you interact with an eligible row, and Product Real
Control is experimental. It is always on (a row only becomes Real after you interact with it) and
has no app-count limit. Real-hardware resource characterization (CPU, teardown timing) only covers
up to three concurrent sessions; the direct output engine was additionally listened to (no crackle,
underruns 0) with up to six, but not measured for CPU/memory/sleep/Stop All, so production-grade
multi-app per-application control is not claimed. Older entries that say "capped at three" /
"`N > 3` deferred" describe the state at that time.

## [Unreleased]

## [v0.14.1] - 2026-10-06

### Highlights
- **Cleaner output list.** MacMiniMixer's own temporary devices ("MacMiniMixer Process Tap Live
  Output", one per controlled app) no longer appear in the panel's output device list, where one
  could be picked as the system output by mistake.

### Fixed
- **The output selector no longer lists MacMiniMixer's own devices.** With the direct output engine,
  each Real app's private aggregate ("MacMiniMixer Process Tap Live Output") has output channels, so
  it appeared in MacMiniMixer's own output device list — once per active app — and could be picked as
  the system output. Devices whose UID starts with `com.macminimixer.` (every aggregate the app
  creates) are now left out of the list. They were never visible to other apps (they are private to
  the MacMiniMixer process) and disappear when their session stops.

## [v0.14] - 2026-10-06

### Highlights
- **No app-count limit.** Every app you touch can have its own real volume control at the same time.
- **Real control is always on.** There is no toggle; nothing is captured until you move an app's
  slider or mute it.
- **Safari, Chrome and web apps work.** All of a browser's audio processes are controlled together,
  and Safari web apps, Chrome PWAs and Chrome Canary no longer steal each other's audio.
- **Crackle-free output.** A new direct output engine plays at the device's own sample rate (48 kHz
  and the built-in speakers' 44.1 kHz) and never changes it.
- **A simpler panel.** Header with the output-device button and a `⋯` menu (Show all apps, Quit),
  a compact "N apps controlled" banner, then the System Output row and your apps.
- **Advanced is for developers.** The diagnostics section only appears in developer mode.
- **Queued starts.** Start several apps in a row and they start one after another, with a pending
  badge while they wait.
- **Sturdier stop and start.** Safer teardown, a settle gate between stop and start, and a calm
  "Waiting for app audio" state for silent apps.
- **Better accessibility.** VoiceOver labels across the panel, and the "Read-only" badge for outputs
  without volume control shows before you touch the slider.
- **New app icon** (three mixer sliders), shown in Finder, Launchpad and the permission prompts.
- **Ad-hoc signed `.zip` download** with a SHA-256 checksum. Needs macOS 13.0+, and macOS 14.2+ for
  per-app control.

### Checkpoint 2 — direct engine at the default 44.1 kHz (`da6ed70`, tag `checkpoint-direct-engine-44k`)
The direct output engine now runs on built-in speakers at their default **44.1 kHz** without touching
the device's sample rate. Real-hardware log: the tap stream *reports* 48 kHz, but inside the aggregate
the HAL already delivers it at the aggregate's rate (512 tap frames per 512 output frames every cycle,
`measuredRatio=1.00000`), so the engine detects this and copies straight through (`path=passthrough`);
the earlier "sample rate mismatch" fallback was a false alarm. The in-engine `AudioConverter` path stays
as a safety net for HALs that do deliver a different rate. Owner's test: up to **six concurrent sessions**
(Safari, Spotify, YouTube and two Netflix Safari web apps, Music) with repeated stop/start rounds, every
start `output=direct`, `underruns=0 overflows=0`, and **no crackle heard**. AirPods (normal listening)
also ran on the direct engine (`output=direct rate=48000`, five apps, no crackle heard). Output devices
that expose input streams on the same device (some USB headsets, audio interfaces) still use the
AudioQueue path.

### Checkpoint — direct output engine, real-hardware result (`c6a1338`, tag `checkpoint-direct-engine-48k`)
Commits after the docs refresh (`222b652`) that are not itemized below: per-app audio processes found
through the HAL process-object list and tapped together (`5a498c2`), attribution by resource coalition
so Safari, Safari web apps, Chrome, Chrome PWAs and Canary each keep their own processes (`6d1d265`),
the direct aggregate output engine (`377f1a8`), and packaging that keeps code-coverage
instrumentation out of Release builds (`c6a1338`). Owner's test on one MacBook Pro, built-in speakers
**set to 48 kHz**: Netflix (Safari web app), Safari, YouTube (Safari web app), Spotify and Music ran
**five sessions at once, three rounds**, every start `output=direct rate=48000`, no fallbacks, no
Core Audio overload/IOProc errors, and **no audible crackle** in repeated tests (previously the
AudioQueue path crackled at random, typically when a second session started). At the default
44.1 kHz the tap stream reports 48 kHz, so the direct engine falls back to the AudioQueue path —
in-engine sample-rate conversion is the next step (owner decision: never change the user's device
sample rate automatically).

### Added
- **App icon.** `MacMiniMixer/Support/Assets.xcassets/AppIcon.appiconset` (16–1024 px, macOS
  rounded-rect plate with the three-slider artwork); `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.
  The System Audio Recording usage text now describes per-app volume control instead of "future
  experiments".
- **Direct aggregate output engine (default live output path).** Product Real and Advanced live
  control now play the tapped audio straight out of one Core Audio IOProc: a single private
  aggregate device made of the default output device (main/clock sub-device, drift compensated)
  plus the process tap, whose one IOProc reads the tap from `inInputData` and writes the faded and
  gained samples to `outOutputData`. There is no `AudioQueue` and no cross-thread buffer hand-off.
  Why: the old live path ran **two clocks** — a tap-only aggregate's IOProc (tap clock) pushed
  buffers across threads into a separate `AudioQueue` (output-device clock) — so underruns were
  inevitable and showed up as random crackle, typically when a second session started. The new path
  follows Apple's tap-playback structure. New types: `ProcessTapLiveOutputMode`
  (`.directAggregateOutput` default, `.audioQueue` legacy),
  `ProcessTapResourceContext.createPrivateOutputAggregateDevice` (the tap-only variant stays for the
  legacy path and the probes), `ProcessTapDirectOutputCopier` (pure, real-time-safe copy + per-frame
  gain + channel mapping: interleaved/non-interleaved, mono↔stereo, extra channels zeroed, silence
  for missing/short input, plus the format-compatibility check) and a direct renderer that reuses
  `ProcessTapLiveGainRamp` (fade-in on start, fade-out before stop); gain/fade requests reach the
  IOProc through a try-lock only. The start falls back to the legacy `AudioQueue` path when the output
  device has input streams (the tap stream's position in the aggregate's input list cannot be
  known, and the wrong one would play a microphone), when the formats or rates cannot be
  rendered directly, or when any aggregate/IOProc step fails. Queue-only diagnostics (`Queued`,
  enqueue failures, queue warmup) report 0 in direct mode (`377f1a8`).
- **In-engine sample-rate conversion with passthrough detection.** When the tap and output rates
  differ (the tap stream reports 48 kHz while built-in speakers run at their default 44.1 kHz) the
  direct engine no longer falls back to `AudioQueue`: `ProcessTapDirectOutputResampler` (created and
  warmed up off the audio thread) feeds the tap frames actually delivered into a preallocated FIFO
  and pulls exactly the output frame count through an `AudioConverter`. If most of the first three
  cycles that carry frames have exactly one tap frame per output frame, the frames pass through
  unconverted (`path=passthrough`); that is what real hardware does: the HAL already hands the tap
  over at the aggregate's rate (`measuredRatio=1.00000`). A FIFO underrun renders the missing frames
  silent and counts as starvation; an overflow drops the oldest frames and counts as a drop. A single notice log ~2 s after start,
  "Live control direct resample report", records the tap/output rates, the chosen `path`, average
  frames per cycle, the measured ratio, and the underrun/overflow counts. The device's own sample
  rate is never changed (owner decision). Equal rates keep the frame-for-frame copy (`da6ed70`).
- **Two `defaults write` switches** (read when a live controller is created, no rebuild needed):
  `MacMiniMixerLiveOutputMode` = `audioQueue` forces the legacy output path;
  `MacMiniMixerDirectResample` = `off` restores the old "sample rate mismatch → `AudioQueue`
  fallback" behavior. Both default to the direct, converting behavior (`377f1a8`, `da6ed70`).
- **Real-hardware results for the direct engine** (one Mac, owner's listening tests; details in the
  two checkpoint entries above): crackle-free at 48 kHz and at the default
  44.1 kHz, with up to six concurrent sessions, and also on a second output device at 48 kHz with
  Firefox, Safari, Spotify, Music and YouTube. Which output path that second device used was not
  recorded here. CPU, memory, Stop All and sleep timing with more than three sessions were not
  measured.
- **Every audio process of an app is tapped together.** Browsers and other multi-process apps
  (Chrome/Edge/Brave/Arc, Electron apps such as Discord/Slack/VS Code, Firefox, Safari's WebKit GPU
  process) render audio in helper processes, so a tap over the visible PID alone captured nothing.
  The HAL's own client list (`kAudioHardwarePropertyProcessObjectList` +
  `kAudioProcessPropertyPID` / `BundleID` / `IsRunningOutput`, macOS 14.2+, behind an injectable
  `AudioProcessObjectListing`) is matched to the app row by the pure `AppAudioProcessMatcher`, and
  `ProcessTapTarget.additionalProcessIdentifiers` carries the result into **one multi-process tap**
  (`createProcessTap(processObjectIDs:)`; the start fails only when none of the pids maps).
  `HelperAudioTargetResolver` matches first (no probing, not cached); a non-browser app without a
  match gets a "play audio first" message instead of the keyword-gate rejection; processes another
  Product Real session already taps are excluded (no double tap) (`5a498c2`).
- **Attribution by resource coalition** (`6d1d265`). Real-hardware report: a Safari row plus a
  "YouTube" Safari web app row (`com.apple.Safari.WebApp.<UUID>`, with its own WebKit GPU/WebContent
  processes) made whichever row started second fail with "This app's audio is already under real
  control in another row", because the bundle-id rules over-matched (Safari took every
  `com.apple.WebKit.*` process and the web app's own process). Same class of bug for Chrome vs Chrome
  PWA shims (`com.google.Chrome.app.*`) and Chrome Canary. `SystemProcessInfo` gained
  `resourceCoalitionID`, read by `SystemProcessLister` with `proc_pidinfo` flavor
  `PROC_PIDCOALITIONINFO` (20) into a 40-byte buffer (`coalition_id[COALITION_TYPE_RESOURCE]`); a
  failed or short read, or id 0, means unknown. **Grey area:** that flavor and struct come from
  XNU's *private* `bsd/sys/proc_info_private.h`, so the SDK does not expose them and the raw values
  are mirrored in code (verified against the XNU sources, not against Apple documentation). The call
  itself is the public `proc_pidinfo` libproc function, and it degrades safely: when a coalition id
  is unknown the matcher uses the **bundle-rule fallback** (exact bundle id or an allow-listed helper
  such as `<app>.helper`, `.helper.*`, `.framework.*`; never `.app.*`, `.WebApp.*`, `.canary`/`.beta`/
  `.dev`, never another row's exact bundle id, and Safari's WebKit rule only while no other
  WebKit-owning row runs). Matcher order: exact app pid; never another running row's own app pid;
  descendants; then, when both coalition ids are known, match iff they are equal (authoritative, no
  bundle rules). The resolver also lists the app's own pid and logs `pid:bundle:coalition` for every
  match; when every process is already tapped by other sessions the message is unchanged but the
  conflicting pids and owning sessions are now logged.
- **Project delegation tooling.** A `delegate-subagents` skill with a shared
  `project-brief.md`, and typed agents under `.claude/agents` with cost-tiered models (`code-scout`
  haiku read-only, `docs-writer` and `swift-editor` sonnet, `swift-implementer` opus), plus a narrowed
  `.claude/` ignore rule so shared skills/agents are committed while worktrees and local settings
  stay ignored (`0c0e724`). No effect on the app.
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
  GitHub Release) and on manual dispatch (artifact only). Maintainer guide in `docs/RELEASING.md`
  (`e0a60b4`).
- **Per-session starvation attribution logging.** Product Real starvation escalations are logged
  with the session id and app, rate-shaped per session (first nonzero Starv, then each 100-count
  bucket, and any Drops/Fail increase immediately) so a spike cannot flood the log. Diagnostics only:
  audio, state, UI, and callback acceptance are unchanged (`617b7f2`).
- `NSHumanReadableCopyright` in `Info.plist`: "Copyright © 2026 Ahmed Tuğra Kasem. MIT License."
  (`1469eb2`).

### Changed
- **Real app control is always on (owner decision).** The "Real app control" toggle strip and its
  "Exp" badge are removed from the panel; `MacMiniMixerApp` enables Product Real Control when it builds
  the view model (`AppConstants.realAppControlEnabledAtLaunch`). Moving any eligible row's slider or
  mute starts real control exactly as it did with the toggle on, and nothing is captured until the user
  interacts with a row. `MixerViewModel.setExperimentalRealAppControlEnabled` and its OFF default are
  kept, so the test suite is unchanged.
- **Advanced is developer-only (owner decision).** The Advanced diagnostics section is not built at all
  unless the `MacMiniMixerDeveloperMode` bool default is true (read once when the panel is created), so
  nothing in it runs otherwise. Enable it with
  `defaults write com.example.MacMiniMixer MacMiniMixerDeveloperMode -bool YES` and relaunch;
  `defaults delete com.example.MacMiniMixer MacMiniMixerDeveloperMode` hides it again.
- **Simpler panel.** The panel is now: header (title, output-device button, and a `⋯` menu holding
  `Show all apps` and `Quit`), a compact one-line active banner ("N apps controlled" for two or more
  apps, with `Stop`/`Stop All`; `RealControlBannerPresenter` strings and accessibility labels are
  unchanged), status messages (including the "Open Settings" permission action), the System Output
  row, and the Applications list. No audio-path changes.
- **Live output path is now the direct aggregate engine; `AudioQueue` is a legacy fallback.** A Product
  Real or Advanced live session now owns a tap, a private output aggregate (default output device +
  tap) and one IOProc; it owns an `AudioQueue` only when the legacy path is used (override
  `MacMiniMixerLiveOutputMode=audioQueue`, an output device that has input streams, or a failed direct
  setup). In direct mode the Advanced card's `Queued` count is 0 and a Product Real start logs
  `output=direct`. The legacy `AudioQueue` output code moves to
  `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLegacyAudioQueueOutput.swift` and is scheduled for
  removal once the direct engine has covered more devices. Replay Probe keeps its own separate
  `AudioQueue`. Shared tap creation and session activation were extracted; teardown ordering is
  unchanged (the direct path fades out in the IOProc and waits, bounded, for the ramp to render before
  stopping IO) (`377f1a8`, `da6ed70`).
- **Release packaging no longer inherits code-coverage instrumentation.** A local run showed the
  Release build compiled with `-profile-generate -profile-coverage-mapping` after an `xcodebuild
  test` in the same derived data folder, which instruments every function including the audio IOProc.
  `scripts/package-app.sh` now builds into its own `./.DerivedData-release` and passes
  `CLANG_ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO` explicitly (`c6a1338`).
- **CI spends fewer macOS runner minutes and nothing waits on it.** `build.yml` skips runs for
  docs/`.md`/`.claude`-only changes, gives the build job a 30-minute timeout, adds `workflow_dispatch`,
  and runs the Release `package` job only for `main` pushes and manual runs. GitHub Actions jobs for
  this repo had started failing within seconds with no runner assigned (likely out of macOS minutes
  or a spending limit — not confirmed). New working rule: never block on unavailable CI; re-run an
  infra failure at most once, then report CI as unavailable and run `xcodebuild test` locally;
  delegated agents never push, trigger or poll CI (`fde8ceb`).
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
  suite green (**414 passed / 0 failed / 0 skipped**). Cap stays **3**; `N > 3` deferred.
- **Product Real coordinator internal split: `ProductRealControlStateStore` + `ProductRealStopCoordinator`**
  (internal refactor, no behavior change). `ProductRealControlCoordinator` is now a thin facade that
  composes two internal sub-objects behind its **unchanged public API**: `ProductRealControlStateStore`
  (the single `ProductRealControlState` source and `onWillChange` notification storage — one shared
  instance, notifies exactly once before each write, never on reads) and `ProductRealStopCoordinator`
  (the product-only stop path: per-app stop, Stop All, stop callback, app-exit cleanup, hard-teardown
  reset, active-name helper). `MixerViewModel` is **unchanged** and still knows only the facade;
  start/resolution logic remains in the facade for now; the Start↔Stop cross-edges are narrow closures
  (no ownership cycle). Focused `ProductRealControlStateStoreTests` and `ProductRealStopCoordinatorTests`
  added. Full suite green (**407 passed / 0 failed / 0 skipped**). Cap stays **3**; `N > 3` deferred.
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
  sessions; `N > 3` stays deferred.
- **Product Real Control start path extracted into `ProductRealControlCoordinator`** (internal
  refactor, no behavior change). The coordinator now owns `ProductRealControlState`, the app-audio
  resolution task and resolution handling, stale-start cleanup, and the async Product Real start
  path (both the `startExperimentalControl` preflight and the resolved/async start body). It talks
  to `MixerViewModel` only through the narrow `ProductRealControlSideEffects` /
  `ProductRealControlContext` seam. Migrated in small, independently-tested steps (seam → state
  ownership → resolution slice → stale cleanup → async start body) rather than one large refactor.
  Product Real Control remains capped at **three** concurrent sessions; `N > 3` stays deferred.

### Fixed
- **Random crackle in Product Real Control** came from the live path running two clocks (tap IOProc →
  cross-thread hand-off → `AudioQueue` on the output device's clock). The direct aggregate output
  engine removes the hand-off; on the owner's Mac it was crackle-free at 48 kHz and at 44.1 kHz in
  repeated tests (`377f1a8`, `da6ed70`).
- **Safari vs Safari web app (and Chrome vs Chrome PWAs / Canary) rows no longer steal each other's
  audio processes.** The row that started second used to fail with "This app's audio is already under
  real control in another row"; each row now gets only its own coalition's processes (`6d1d265`).
- Release packages built after a local test run no longer carry coverage instrumentation (`c6a1338`).
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

### Earlier v0.14 checkpoint
The first v0.14 baseline, focused on **Product Real Control** teardown and starvation handling and
driven by real-hardware feedback, before the work above. Where it mentions three simultaneous
sessions or a cap, the entries above supersede it. Requires macOS 14.2+ for Process Tap support.

#### Changed
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

#### Fixed
- Swift 6 language-mode test failure: `NSLock.lock()/unlock()` called from an async context is
  replaced with scoped `withLock` (async-safe locking).
- Full-suite test flake: live-control test waits are now bounded by a wall-clock deadline instead of
  a fixed `Task.yield()` budget, so they no longer time out spuriously under parallel-suite load.

#### Validated
- Real-hardware normal-use testing (one Mac): three Product Real sessions ran cleanly; per-app
  stop/start during use was clean; Drops/Fail/Starv stayed 0 during normal usage; CPU settled
  roughly in the 20–35% range depending on panel / Activity Monitor state; **no
  `sudo killall coreaudiod`** was needed in the final normal-use retest.
- The 30–60 minute three-session long-run smoke **PASSED (with caveat)** — see below.

#### Known limitations / caveats
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
