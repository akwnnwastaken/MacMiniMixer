# MacMiniMixer — Architecture Reference

Version: internal v0.14 checkpoint plus `[Unreleased]` work (experimental; unreleased,
`MARKETING_VERSION` 0.13).
Deployment target: macOS 13.0. Process Tap features require macOS 14.2 or later.
No third-party dependencies. No private APIs. No HAL driver.

---

## App Entry Point and Dependency Injection

`MacMiniMixer/App/MacMiniMixerApp.swift`

`MacMiniMixerApp` is the `@main` SwiftUI `App`. Its `init()` constructs every service
dependency directly and passes them into `MixerViewModel`. There is no DI container or
service locator — all wiring is explicit and visible in one place.

Services constructed at launch:

| Service | Type | Protocol |
|---|---|---|
| `WorkspaceApplicationLister` | NSWorkspace adapter | `ApplicationListing` |
| `PreviewAudioStateController` | in-memory UI state | `AudioControlling` |
| `CoreAudioOutputDeviceLister` | real | `OutputDeviceListing` |
| `CoreAudioOutputDeviceController` | real | `OutputDeviceControlling` |
| `CoreAudioSystemVolumeReader` | real | `SystemVolumeReading` |
| `CoreAudioSystemVolumeController` | real | `SystemVolumeControlling` |
| `CoreAudioProcessTapTester` | real | `ProcessTapTesting` |
| `CoreAudioProcessTapReplayProbe` | real | `ProcessTapReplayProbing` |
| `ProcessTapLiveSessionManager(maxSessions: AppConstants.maxConcurrentLiveSessions /* nil = unlimited */, controllerFactory: { CoreAudioProcessTapLiveController() })` | real | `ProcessTapLiveControlling` & `ProcessTapLiveSessionManaging` |
| `CoreAudioProcessTapTwoAppReadinessTester` | real | `ProcessTapTwoAppReadinessTesting` |
| `CoreAudioProcessTapCandidateAudioProbe` | real | `ProcessTapCandidateAudioProbing` |
| `SystemProcessLister` | real | `ProcessListing` |
| `HelperAudioTargetResolver` | real | `AppAudioTargetResolving` |

`PreviewAudioStateController` (renamed from `MockAudioController`) is the production
`AudioControlling`: an in-memory store for per-app preview slider/mute values and a cached
system-volume display value. It never touches Core Audio. Per-app volume has no real
system-level API, so the per-app slider state is UI-only unless Product Real Control is
active for that row; real system volume goes through `SystemVolumeReading` /
`SystemVolumeControlling`. The only `Mock*` types left in the app target are
`MockApplicationLister` and `MockOutputDeviceLister`, which the real listers use as fallbacks.

`MixerViewModel` builds the Product Real stack itself: a `ProductRealStartSettleGate` (a
defaulted initializer parameter, injectable in tests) and, at the end of `init`, the
`ProductRealControlCoordinator` facade (see below), wired to the injected live-session manager
and helper resolver.

The `MenuBarExtra` body passes `MixerViewModel` to `MenuBarRootView`, which passes it
to `MixerPanelView`.

---

## Mixer Coordination Model

`MacMiniMixer/Features/Mixer/MixerViewModel.swift`

`MixerViewModel` is no longer monolithic. It is the `@MainActor` cross-subsystem router and
lifecycle/UI orchestration layer: app list and preview row state, the product-vs-Advanced-manual
stop router, the shared stop display and status messages, the output-device-change and
sleep/termination teardown fan-out, and cross-feature busy gating. Product Real App Control
itself lives behind the `ProductRealControlCoordinator` facade.

Extracted coordinators:

| Coordinator | Owns |
|---|---|
| `AdvancedHelperDiscoveryCoordinator` | Advanced helper discovery selection, scan, manual probe, Find audio helper, and Advanced helper target |
| `SystemOutputCoordinator` | System volume/device state, proactive volume-writability probe, and pure volume/device operations |
| `AdvancedProcessTapDiagnosticsCoordinator` | Process Tap Test, Mute Probe, Replay Probe, diagnostic target selection, and replay gain/result state |
| `AdvancedLiveControlCoordinator` | Manual Advanced Live start/stop orchestration |
| `TwoAppReadinessCoordinator` | Advanced Two-App Readiness selection, target options, start/stop orchestration, snapshot/result state, and selection repair |
| `ProductRealControlCoordinator` | Thin **facade** for Product Real Control — the only Product Real type the view model knows. Constructs the three objects below, wires their three cross-edges as `[weak self]` closures, and forwards its public API |
| `ProductRealControlStateStore` | The single `ProductRealControlState` source (sessions, start-request tokens, pending operations, resolution state, queued starts) + `onWillChange`, shared by reference |
| `ProductRealStartCoordinator` | App-audio resolution, start preflight, `requestAutomaticStart`, both `startExperimentalControl` overloads, the queued start lane, cached-helper retry, stale-start rejection, live-diagnostics focus, starvation attribution logging |
| `ProductRealStopCoordinator` | Per-app stop, Stop All core, engine stop callback, app-exit cleanup (incl. queued starts of exited apps), hard-teardown state reset, shared active-name helper |

The Product Real coordinators reach the view model only through the narrow
`ProductRealControlSideEffects` (writes) / `ProductRealControlContext` (reads) seam, held
weakly. Helper value types `RealControlBannerPresenter`, `MixerVisibleAppsFilter`, and
`MixerStatusMessageController` were also extracted from the view model.

`MixerViewModel` forwards coordinator state and methods to keep the existing SwiftUI view
surface stable. It also preserves centralized cleanup orchestration: output device
changes, panel close, app termination, system sleep/wake, active live sessions, helper tasks,
Advanced tools, and readiness cleanup triggers are still coordinated from one place.

---

## Main UI Structure

### MenuBarExtra

`MacMiniMixerApp.body` uses `MenuBarExtra` with `.window` style. The menu bar icon shows
`slider.horizontal.3` normally and `waveform.circle.fill` when Process Tap Live Control is
active. The icon state is driven by `MixerViewModel.isProcessTapLiveControlActive` (Advanced
manual active OR at least one confirmed Product Real session). The label observes the whole
view model, so every `objectWillChange` re-evaluates it — one reason product live diagnostics
are only published while the Advanced section is visible.

### MenuBarRootView

`MacMiniMixer/Features/MenuBar/MenuBarRootView.swift`

A thin pass-through that renders `MixerPanelView`. No logic here.

### MixerPanelView

`MacMiniMixer/Features/MenuBar/MixerPanelView.swift`

The full mixer panel. Fixed width 352pt, ultraThinMaterial background with rounded
corners. Sections from top to bottom:

1. **Header** — title + output device button toggle.
2. **Active live control banner** — orange waveform banner, visible only when
   `isProcessTapLiveControlActive`. Text and button come from `RealControlBannerPresenter`:
   one app → "Real control: Name" + Stop; two → both names + "Stop All"; three or more →
   "first two names +N more" + "Stop All" (the accessibility label lists every app).
3. **Status message** — auto-clears after 2.5s. Warning, info, or success style (spoken with a
   severity prefix).
4. **Output device selector** — `OutputDeviceSelectorView`, shown on button toggle.
5. **System Output section** — mute button + slider + current output device name label, plus a
   "Read-only" badge when the device has no writable volume.
6. **Applications section** — app rows, "Show all" checkbox, "Real app control" toggle.
7. **Advanced section** — collapsible, contains `ProcessTapTestView`,
   `HelperProcessDiscoveryView`, `TwoAppReadinessTestView`.
8. **Quit button**.

`onAppear` records whether the Advanced section is visible
(`setLiveDiagnosticsDisplayVisible`), then refreshes apps, output devices, and system volume.
The Advanced disclosure action updates the same flag (no `onChange`, for macOS 13).
Two async `Task` loops run while the panel is visible: one refreshes system volume every
1 second, another refreshes output devices every 2 seconds.
`onDisappear` clears the visibility flag and calls `stopTwoAppReadinessForPanelClose()`, which
also drops queued Product Real starts and cancels an in-flight helper resolution (active
sessions keep running).

All panel, row, and Advanced views carry explicit VoiceOver labels/values/hints (macOS
13-compatible SwiftUI modifiers).

### MixerAppRowView

`MacMiniMixer/Features/Mixer/MixerAppRowView.swift`

Each visible app gets one row. Contains:
- App icon (real `NSImage` from NSWorkspace or system symbol fallback).
- App name (truncated, fixed width 66pt).
- Volume slider (preview state, or real gain while the row is Real).
- Mute toggle (same caveat).
- Optional live control toggle button (shown only when the "Real app control" mode is ON
  or when that row is the active experimental target).

Row state is "active" when `isExperimentalControlActive` is true for that app ID. Active
rows show an orange waveform indicator. Resolving rows show a "Resolving" spinner. Rows with
a start/stop in flight, or with a start queued behind the start lane, show a non-interactive
pending ("working") badge (`isExperimentalControlPending`). Active, resolving, and queued rows
stay visible even when "Show all" is off and the app is not otherwise considered
audio-relevant (`MixerVisibleAppsFilter`).

### Advanced Section Views

- **`ProcessTapTestView`** — select running app, run diagnostics / mute probe / replay
  probe / start/stop live control. Shows advanced target info when set.
- **`HelperProcessDiscoveryView`** — select visible app, scan for helper candidates, probe
  individual candidate, run auto-detect, use candidate as advanced target.
- **`TwoAppReadinessTestView`** — select App A, App B, gain; start/stop two-app test;
  per-session diagnostics display.

### OutputDeviceSelectorView

`MacMiniMixer/Features/MenuBar/OutputDeviceSelectorView.swift`

List of `OutputDeviceItem` values. Tapping one calls `selectOutputDevice(_:)`.
Devices are filtered by `CoreAudioOutputDeviceLister` — obvious virtual/app-created
devices are hidden unless they are the current system default.

---

## System Output Volume Control

`MacMiniMixer/Services/Audio/CoreAudioSystemVolumeController.swift`
`MacMiniMixer/Services/Audio/CoreAudioSystemVolumeReader.swift`

**Reading**: `CoreAudioSystemVolumeReader.readCurrentOutputVolumeScalar()` queries
`kAudioDevicePropertyVolumeScalar` on the default output device's output scope.

**Setting**: `CoreAudioSystemVolumeController.setCurrentOutputVolumeScalar(_:)` attempts
to write `kAudioDevicePropertyVolumeScalar` for output scope main element first, then
global scope, then per-channel. Returns `false` if the device does not expose a writable
volume property (e.g., HDMI or some external displays).

**Writability probe**: `isCurrentOutputVolumeSettable()` is a read-only, synchronous probe
(`AudioObjectHasProperty` / `AudioObjectIsPropertySettable`) over exactly the addresses the
write path uses; it returns `nil` when it cannot tell (the protocol's default implementation).
`SystemOutputCoordinator` probes at init, when a refresh detects an output-device change, and
after a successful `selectOutputDevice(_:)`, so `isSystemOutputVolumeWritable` (the "Read-only"
badge) is known before the first slider drag. `nil` assumes writable (no false badge); a
rejected or successful write still updates the flag; refreshes without a device change do not
re-probe, so evidence from a rejected write is kept.

**Mute**: `SystemOutputCoordinator` implements mute as set-to-zero + restore.
`lastNonZeroSystemVolume` remembers the pre-mute value. On unmute,
`restoredSystemOutputVolume` returns that value or `defaultSystemOutputRestoreVolume`
(50) as fallback.

**Live sync**: `MixerPanelView` runs a background loop that refreshes volume every 1 second
while the panel is open, so external changes (e.g., physical keyboard keys) stay in sync.

---

## Output Device Listing and Switching

`MacMiniMixer/Services/Audio/CoreAudioOutputDeviceLister.swift`
`MacMiniMixer/Services/Audio/CoreAudioOutputDeviceController.swift`

**Listing**: `CoreAudioOutputDeviceLister.listOutputDevices()` calls
`kAudioHardwarePropertyDevices`, filters devices that have output channels or are the
default device, then removes devices whose names match virtual/app-created keywords
(Teams, Zoom, BlackHole, Loopback, SoundFlower, aggregate/multi-output). The default
device is always included even if virtual. Icons are heuristically assigned by name
(AirPods, HDMI, speakers, display).

**Switching**: `CoreAudioOutputDeviceController.setDefaultOutputDevice(_:)` calls
`AudioObjectSetPropertyData` with `kAudioHardwarePropertyDefaultOutputDevice`.

**Live refresh**: Panel runs a background loop that refreshes devices every 2 seconds.
`SystemOutputCoordinator` refreshes device state. If the default output changes externally
(AirPods auto-connect), `MixerViewModel.refreshOutputDevices()` invalidates every pending
Product start (and the start queue), then `stopActiveAudioWorkForOutputDeviceChange` stops all
Product Real sessions (or Advanced manual Live Control), Two-App Readiness, helper probe /
auto-detect, an in-flight helper resolution, and Replay Probe, and the helper cache is
invalidated.

---

## Running App Discovery

`MacMiniMixer/Services/Applications/WorkspaceApplicationLister.swift`

`WorkspaceApplicationLister.listApplications()` reads `NSWorkspace.shared.runningApplications`,
filters to `.regular` activation policy apps, and maps each to a `MixerAppItem` with:
- `id` = bundle identifier or fallback.
- `name` = localizedName.
- `icon` = `NSWorkspace.shared.icon(forFile:)` or system symbol fallback.
- `processIdentifier` = pid_t cast to Int32.
- `volume` = 100 (default preview value).
- `isMuted` = false.

**Audio-relevance filtering**: `MixerAppItem.isLikelyAudioRelevant` matches name or
bundle ID against allow-keywords (Spotify, Music, Safari, Chrome, Discord, Zoom, etc.)
and deny-keywords (Finder, Notes, Xcode, Terminal, etc.). The "Show all" checkbox bypasses
this filter.

---

## Main Real App Control Flow

The main product path can start real control for a row when the global
`isExperimentalRealAppControlEnabled` toggle is ON and the user moves a slider or clicks
mute on an eligible inactive row (or clicks the row's Real toggle). There is **no app-count
limit**: `AppConstants.maxConcurrentLiveSessions` is `nil` (owner decision), so every
interacted row can get its own session. The cap mechanism stays injectable
(`maxConcurrentSessions` on the facade / start coordinator, `maxSessions` on the manager) and
is exercised only by tests.

**Triggers**:
- `MixerViewModel.setAppVolume(_:for:)` / `setMuted(_:for:)` update the preview value, call
  `ProductRealControlCoordinator.requestAutomaticStart(for:)`, and then push the new gain to an
  already-confirmed session (`updateGain(sessionID:gain:)`).
- `MixerViewModel.toggleExperimentalControl(for:)` (row toggle) ignores the click while the row
  has a pending operation, stops the row if it is active, and otherwise calls
  `startExperimentalControl(for:)`.

**`requestAutomaticStart(for:)` order** (`ProductRealStartCoordinator`):
1. Global mode must be enabled (silent return otherwise).
2. Two-App Readiness must not be running ("Stop two-app test first").
3. The app must still be in `context.apps` and eligible (`isEligibleForExperimentalLiveControl`).
4. Dedupe: already resolving, or pending (start/stop in flight or queued) → no-op.
5. A helper probe / auto-detect must not be running ("Stop helper probe first").
6. Already active for this app → no-op.
7. **Lane busy → enqueue** (see "Queued Start Lane").
8. Only with the lane free: `productSessionStartBlockReason` — blocks while an Advanced diagnostic
   is running or Advanced manual Live Control is active (mutually exclusive with product), and,
   only when a cap is configured, once that many sessions exist.
9. `startResolvedExperimentalControl(for: app)`.

The row toggle path (`startExperimentalControl(for:)`) checks Two-App Readiness, then enqueues
while the lane is busy, then ("Process Tap is already busy" — now only for Advanced work) the
same block-reason check plus app/eligibility/PID/`NSRunningApplication` validation before calling
the async start body.

---

## Queued Start Lane

`ProductRealStartCoordinator` + `ProductRealControlState.queuedStarts`

At most **one** Product Real helper resolution or product start is physically in flight.
`isStartLaneBusy` is true while a resolution task has not finished (`inFlightResolutionTaskCount`,
which counts a cancelled task until it returns), while a start body has not reached its
post-await block (`inFlightStartRequestIDs`), or while state says a resolution is running. This
tracking is private to the start coordinator — not in the shared state — so global resets (Stop
All, Real off, sleep) cannot free the lane while a cancelled start or probe is still running.

- A start requested while busy is appended FIFO as `ProductRealQueuedStart(appID, origin)` (origin
  `.automatic` or `.toggle`), at most one entry per app. A queued app reports
  `isOperationPending`, so its row shows the pending badge and further attempts dedupe.
- **Drain points** (only where the lane physically frees): the end of a start's post-await block
  (after a cached-helper retry has already taken the lane; in the stale branch only after the
  orphan teardown is registered with the settle gate) and the end of a resolution task. Cancelling
  a resolution does **not** drain — the cancelled probe keeps running briefly plus its Core Audio
  cleanup.
- Each drained entry re-enters its original entry point, so it re-runs the full preflight
  against current state (fresh app item and gain from `context.apps`); a now-blocked entry shows
  its message and is dropped, a vanished app is skipped, and the loop stops as soon as one entry
  takes the lane.
- Cancellation: per-app stop (`clearStartRequest`), Stop All / Real off / output change
  (`clearAllStartRequests` / `clearAllOperations`), sleep / termination (hard-teardown reset), panel
  close (`clearQueuedStarts`), and app exit (`removeQueuedStarts(notIn:)`) all drop queued entries.

Direct-PID starts queue too: the helper probe (`CoreAudioProcessTapCandidateAudioProbe`) creates
and destroys its own tap + aggregate outside the lifecycle gate and the settle gate, and every
product start owns the shared Advanced "running" flag. Rationale in `docs/DECISIONS.md`.

---

## Direct Visible PID Path

`ProductRealStartCoordinator.startResolvedExperimentalControl(for: app, allowsCachedLookup:)`

First checks `ProcessTapCoreAudio.processTapEligibility(for: app.processIdentifier)`.

`processTapEligibility(for:)` in `ProcessTapLifecycle.swift`:
1. Requires `#available(macOS 14.2, *)`.
2. Requires `NSAudioCaptureUsageDescription` in Info.plist.
3. Requires PID > 0.
4. Calls `ProcessTapCoreAudio.processObjectID(for: pid)` — translates PID to Core Audio
   process object via `kAudioHardwarePropertyTranslatePIDToProcessObject`.

If eligible, calls `startExperimentalControl(for: app, target: visibleTarget)` directly.
This path is used for apps like Spotify or Music that are directly registered with
Core Audio.

---

## Async Start Body and Live Diagnostics

`ProductRealStartCoordinator.startExperimentalControl(for:target:resolutionSource:)`

1. Takes a fresh per-app start-request token, sets an optimistic session entry (keeps the row
   visible and lets app-exit detection see it), writes the "Starting…" result / zero progress to
   the shared Advanced surface, marks the row's operation pending, takes the start lane, and makes
   this app the **live-diagnostics focus**.
2. In a `Task`: `startSettleGate.waitForReadyToStart()` (waits for registered teardowns + a 0.2 s
   settle), then `liveSessionManager.startSession(..., timeoutPolicy: .indefinite)`, which runs
   inside the manager's Core Audio lifecycle gate.
3. Post-await on the main actor: clears the pending flag; rejects a stale completion (newer token
   or any cancellation) and tears its orphan session down by id, registered with the settle gate;
   otherwise re-asserts the session with its engine `liveSessionID`, or on failure invalidates a
   cached helper and retries one fresh resolve (suppressed only by Advanced manual control, not by
   other product sessions) or shows "Could not start live control for this app". Finally it
   releases the lane and drains the queue.

Per-session callbacks carry the session id. `onDiagnostics` is accepted only via
`shouldAcceptCallback` (current token, or the confirmed session that owns it). Accepted callbacks:
- publish to the shared Advanced surface (`setProcessTapLiveDiagnostics` /
  `setLiveControlDiagnosticProgress`) **only for the focused app and only while
  `isLiveDiagnosticsDisplayVisible`** (panel open with Advanced expanded). The newest start takes
  the focus; if the focused app no longer has a session, the next accepted callback adopts it;
- always feed `ProductRealStarvationAttributionLog`, which emits a bounded debug log (session id,
  app, Starv/Drops/Fail/enqueued/warmup) on the first nonzero Starv, each new 100-count Starv
  bucket, and any Drops/Fail increase.

Upstream of that, each controller's diagnostics timer ticks every 100 ms and
`ProcessTapDiagnosticsPublishGate` limits each session's publishes to ~4 Hz (start/stop/final
samples and failure/starvation escalations bypass it). Start, failure, and stop display writes are
never gated by focus or visibility.

---

## Browser/Helper Resolution Path

For apps like Safari or YouTube whose visible PID returns `"Core Audio process unavailable"`,
the app enters helper resolution if `HelperProcessCandidateDiscovery.isLikelyHelperResolvable`
returns true (name/bundle ID contains a browser keyword: safari, chrome, youtube, etc.).

**`HelperAudioTargetResolver.resolveTarget(for: request, allowsCachedLookup:)`**
(`AppAudioTargetResolving.swift`)

Steps:
1. Acquires a UUID-based resolution lock — only one resolution at a time.
2. Re-checks visible PID eligibility (direct path fast-exit).
3. Calls `processLister.listProcesses()` on a detached task.
4. Checks the validation-first cache.
5. Calls `HelperProcessCandidateDiscovery.candidates(for:, processes:)` to find candidates.
6. Filters to tap-eligible candidates.
7. Sequentially probes each candidate with `helperProcessAudioProbe.probeAudio(for:, duration:)`.
8. Scores each probe result. Early-accepts if `hasDetectedAudio && (rms >= 0.01 || peak >= 0.05)`.
9. If no early-accept, picks `scoredCandidates.max()` provided it `hasDetectedAudio`.
10. Caches the winner. Returns `.resolved(ResolvedAppAudioTarget)`.

On failure: returns `.unavailable(reason)`. On cancellation: returns `.cancelled`.

---

## Validation-First Helper Cache

`HelperAudioTargetResolver` maintains `cachedHelpersByKey: [AppAudioHelperResolutionCacheKey: AppAudioHelperResolutionCacheEntry]` guarded by `NSLock`.

**Cache key**: `AppAudioHelperResolutionCacheKey(visibleAppID:, visibleProcessIdentifier:)`.
Only valid when visible PID > 0.

**Validation** (called before using cache):
1. Checks that the cached helper PID still exists in the current process list.
2. Checks that the cached helper PID is still Core Audio tap-eligible.
3. If either fails, removes the entry and treats as cache miss.

**Invalidation triggers**:
- App removed from running list or its PID changed (refresh cycle).
- Output device change.
- `setExperimentalRealAppControlEnabled(false)`.
- Live control stopped with `.liveControlAppExited` outcome.
- Live control start failed with `.cachedHelper` source → retries without cache (also while
  other Product Real sessions run; only Advanced manual control suppresses the retry).
- Live control start failed with `.discoveredHelper` source (no retry).

**Not persisted** across launches. No background scanning updates it.

---

## Advanced Helper Process Discovery

`MacMiniMixer/Services/Audio/ProcessTap/HelperProcessCandidateDiscovery.swift`

`HelperProcessCandidateDiscovery.candidates(for: target, processes:)` finds helper/content
process candidates for a visible browser/web app.

**Candidate relations** (sorted by priority):
- `.directApp` — the visible app PID itself.
- `.child` — direct child (parent PID == visible PID).
- `.descendant` — deeper descendant (walks up to 64 hops).
- `.nameMatch` — name/path matches browser-specific keywords.

**Browser keyword sets**:
- Safari/WebKit: `["safari", "webkit", "webcontent", "com.apple.webkit"]`
- Chrome family: `["chrome helper", "chrome", "chromium", "renderer", "gpu", "utility", "audio", ...]`
- YouTube: combined Safari + Chrome keywords.
- Other: derived from the first 3 words of the app name (> 2 chars each).

Results are filtered, sorted, and capped at 30 entries. Each candidate has an
`eligibility: ProcessTapProcessEligibility` checked at discovery time.

`isLikelyHelperResolvable(_:)` checks if the app name/bundle ID contains any of:
`safari, chrome, chromium, youtube, browser, webkit, arc, brave, edge, opera`.

---

## Helper Audio Probe and Find Audio Helper

`MacMiniMixer/Services/Audio/ProcessTap/ProcessTapCandidateAudioProbing.swift`

`ProcessTapCandidateAudioProbing` protocol exposes:
- `probeAudio(for: target, duration:, onProgress:) async -> ProcessTapTestResult`
- `stopCurrentProbe(reason:)`

The concrete implementation (`CoreAudioProcessTapCandidateAudioProbe`) runs a short
diagnostic Process Tap with `muteBehavior: .unmuted`. It does not suppress or replay
audio. It accumulates callbacks, peak, and RMS, then returns a `ProcessTapTestResult`.

**Auto-detect flow** (`AdvancedHelperDiscoveryCoordinator.autoDetectHelperProcessCandidate()`):
1. Gets tap-eligible candidates from `helperProcessCandidates`.
2. Iterates candidates sequentially.
3. Probes each for `processTapHelperAutoDetectDuration` (1.25s).
4. Accumulates `HelperProcessAutoDetectScore` values.
5. Selects `scoredResults.max()`. If it `hasDetectedAudio`, sets it as the advanced target.

The product helper resolution path (`HelperAudioTargetResolver`) uses the same probe
mechanism with the same duration, but adds early-accept logic and caching.

---

## Advanced Helper Target

`AdvancedProcessTapTarget` struct (defined in `AdvancedHelperDiscoveryState.swift`):
- `target: ProcessTapTarget` (appID, appName, processIdentifier).
- `parentAppName: String` — the visible browser app's name.
- `relation: HelperProcessRelation`.
- `eligibility: ProcessTapProcessEligibility`.
- `probeResult: ProcessTapTestResult?` — result from last manual probe, if any.

Set by `AdvancedHelperDiscoveryCoordinator.useHelperCandidateAsAdvancedTarget(_:)`.
Cleared by `AdvancedHelperDiscoveryCoordinator.clearAdvancedProcessTapTarget()`.

When `advancedProcessTapTarget` is set, Process Tap Test, Replay Probe, and Two-App
Readiness can operate against this target's PID from Advanced. The UI shows the visible
parent app name + `" helper"` label. `MixerViewModel` forwards the target to Process Tap
diagnostics and Two-App Readiness.

---

## Replay Probe

`MacMiniMixer/Services/Audio/ProcessTap/CoreAudioProcessTapReplayProbe.swift`

Replay Probe UI orchestration is owned by
`MacMiniMixer/Features/Mixer/AdvancedProcessTapDiagnosticsCoordinator.swift`.

`CoreAudioProcessTapReplayProbe.runReplayProbe(for: target, gain:, onProgress:)` runs on a
detached task and:

1. Calls `ProcessTapResourceContext.createProcessTap(muteBehavior: .mutedWhenTapped)` —
   original app audio is suppressed.
2. Creates private aggregate device with the tap UID.
3. Reads stream description from the aggregate device. Requires Float32 PCM mono or stereo.
4. Creates `ProcessTapReplayOutputQueue` (an `AudioQueueNewOutput`-backed queue).
5. Creates IOProc with callback that calls `accumulator.observe(inputData)` +
   `replayOutput.enqueue(inputData, gain:)`.
6. Starts IO.
7. Polls for `processTapReplayProbeDuration` (2.5s) at 100ms intervals, publishing progress.
8. Stops IO, cleans up resources.
9. Returns a `ProcessTapReplayResult` with callback count, peak, RMS, queued/dropped/failed.

Replay Output Queue: `AudioQueueNewOutput` with 8 buffers of 65536 bytes each.
Gain is a constant scalar applied per-sample via `ProcessTapOutputBufferCopier`.

---

## Two-App Readiness

`MacMiniMixer/Features/Mixer/TwoAppReadinessCoordinator.swift`

`TwoAppReadinessCoordinator` owns the Advanced UI-facing readiness state: selected App A,
selected App B, gain, tap eligibility, target options including one selected Advanced
helper target, running flag, snapshots, results, selection repair, and start/stop calls.
`MixerViewModel` forwards this state to existing views and still triggers cross-feature
cleanup for panel close, output-device changes, app termination, and Advanced helper
target removal.

`MacMiniMixer/Services/Audio/ProcessTap/ProcessTapTwoAppReadinessTesting.swift`

`CoreAudioProcessTapTwoAppReadinessTester.startTest(appA:, appB:, gain:, onUpdate:, onFinished:)`:

1. Preflights both targets for tap eligibility.
2. Creates a `TwoAppReadinessRun` with a **separate** `ProcessTapLiveSessionManager(maxSessions: 2)`.
   This is **isolated from the main product session manager**.
3. Starts App A session via `run.manager.startSession(...)`. On failure, marks setup failed.
4. Starts App B session. On failure, stops App A and marks setup failed.
5. Starts a timeout `Task` for the selected duration (`ProcessTapTwoAppReadinessDurationOption`:
   10 s by default, or 1 / 5 / 30 minutes).
6. Returns `.running`.

`TwoAppReadinessRun` tracks `sessions: [Slot: SessionSnapshot]` and
`sessionSlots: [SessionID: Slot]`. Diagnostics from each live session are merged into the
snapshot. `onUpdate` fires on each diagnostic tick.

**Stop paths**: user calls `stopAll`, timeout fires, or one session's `onStopped` fires
(which cascades to stop the other).

`finalizeUnresolvedStoppingSessions()` ensures any session still in `.starting` or
`.stopping` is finalized as `.failed` or `.stopped` before the snapshot is published.

---

## Process Tap Session Manager

`MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLiveSessionManager.swift`

`ProcessTapLiveSessionManager` wraps one or more `ProcessTapLiveControlling` controllers
behind a session abstraction.

- Each session gets a `ProcessTapLiveSessionID` (UUID wrapper).
- Sessions are tracked in `sessions: [SessionID: ProcessTapLiveSessionState]` + a
  parallel `controllers: [SessionID: ProcessTapLiveControlling]` dict.
- `maxSessions: Int?` is enforced at reservation time; `nil` means unlimited, and a non-nil
  value is clamped to at least 1.
- For the main product path, `maxSessions` is `AppConstants.maxConcurrentLiveSessions` (`nil`)
  and a fresh `CoreAudioProcessTapLiveController` is created per session via `controllerFactory`.
- For Two-App Readiness, a separate manager with `maxSessions = 2` and its own factory.
- The compatibility initializer `init(controller:)` shares one controller and keeps
  `maxSessions = 1`.
- A `ProductRealCoreAudioLifecycleGate` (actor) serializes every session create/destroy this
  manager performs (`startSession` / `stopSession`), so no teardown overlaps a setup on the
  shared coreaudiod route (P181). Stops that a controller initiates itself (target-app exit or
  output-device change seen by its diagnostics timer, timeout) and the synchronous
  `stopLiveControlNow` hard stop do **not** go through this gate (see "Known Multi-Session
  Gaps").

The class also implements `ProcessTapLiveControlling` directly (the compatibility interface),
routing through `compatibilityActiveSessionID` for `startLiveControl`, `stopLiveControl`,
and `updateLiveControlGain`. The Advanced manual Live Control path uses that interface; Product
Real Control uses the per-session `ProcessTapLiveSessionManaging` API (`startSession`,
`stopSession(id:)`, `updateGain(sessionID:)`).

---

## CoreAudio Live Controller and Session Internals

`MacMiniMixer/Services/Audio/ProcessTap/CoreAudioProcessTapLiveController.swift`

### Setup sequence (macOS 14.2+):

1. Checks no existing session is active.
2. Reads default output device ID (saved as `startDefaultOutputDeviceID`).
3. `ProcessTapCoreAudio.processObjectID(for: pid)` translates PID to Core Audio object.
4. `resources.createProcessTap(muteBehavior: .mutedWhenTapped)` — suppresses original output.
5. Reads tap UID from `kAudioTapPropertyUID`.
6. `resources.createPrivateAggregateDevice(...)` — private aggregate device wrapping the tap.
7. Reads stream description from aggregate device.
8. Validates Float32 PCM mono or stereo.
9. `ProcessTapLiveOutputQueue.start(format:)` — creates `AudioQueueNewOutput` with 8 buffers.
   Queue is not started yet; it waits for `processTapLivePrimingBufferCount` (2) enqueues.
10. `ProcessTapDiagnosticsAccumulator` created.
11. IOProc created with a callback that calls `accumulator.observe(inputData)` and
    `outputQueue.enqueue(inputData, gain: gainState.scalar)`.
12. `resources.startIO()`.
13. `ProcessTapLiveSession` created and stored as `activeSession`.
14. Timers are started:
    - Diagnostics timer: fires every 100ms, checks process liveness, checks output device
      change (either one stops the session from inside the controller), and calls
      `onDiagnostics` through a per-session `ProcessTapDiagnosticsPublishGate` (~4 Hz, with
      escalation bypass).
    - Timeout timer: limited live sessions only; fires after 60s and calls
      `stop(session:, reason: .timedOut)`. Product Real App Control requests an
      indefinite policy and keeps only the diagnostics/liveness timer.

### Gain

`ProcessTapLiveGainState` is thread-safe (`NSLock`). It holds the current `ProcessTapReplayGainOption`.
`updateLiveControlGain(_:)` updates it under lock; the IOProc reads `gainState.scalar` on
each callback.

`ProcessTapLiveGainRamp` implements per-frame fade-in (60ms default) and fade-out (40ms
default). `beginFadeOut()` is called before stopping to smooth the ending.

### Stop sequence:

1. `session.beginStopping()` — claimed under `cleanupLock`, idempotent.
2. Removes from `activeSession`.
3. `session.cleanup()`:
   a. Cancels both timers.
   b. Calls `outputQueue.beginFadeOut()`.
   c. Sleeps `processTapLiveFadeOutDuration` (40ms).
   d. Calls `outputQueue.stop()`.
   e. Calls `resources.cleanup()`.
4. `resources.cleanup()`:
   a. Claims `cleanupLock`, sets `didCleanUp = true`.
   b. Stops IO: `AudioDeviceStop`.
   c. Destroys IOProc: `AudioDeviceDestroyIOProcID`.
   d. Destroys aggregate device: `AudioHardwareDestroyAggregateDevice`.
   e. Destroys tap: `AudioHardwareDestroyProcessTap`.
5. `session.onStopped(result, diagnostics)` fires.

---

## Process Tap Output Buffer Copier

`MacMiniMixer/Services/Audio/ProcessTap/ProcessTapOutputBufferCopier.swift`

Shared utility for copying `AudioBufferList` samples into a flat interleaved `Float32`
output buffer, applying per-frame gain.

Handles two cases:
- **Interleaved** (1 `AudioBuffer`): direct sample copy with channel folding if input has
  fewer channels than output.
- **Planar** (multiple `AudioBuffer`s): one buffer per channel, indexed by output channel.

The `ProcessTapOutputFrameGainProviding` protocol allows callers to supply per-frame gain.
Replay Probe uses a constant `ProcessTapConstantFrameGainProvider`. Live Control uses
`ProcessTapLiveFrameGainProvider` which advances a `ProcessTapLiveGainRamp`.

This logic is covered by `ProcessTapOutputBufferCopierTests`.

---

## Process Tap Diagnostics Accumulator

`MacMiniMixer/Services/Audio/ProcessTap/ProcessTapDiagnosticsAccumulator.swift`

Thread-safe (`NSLock`) accumulator for IOProc callbacks. On each `observe(inputData)` call:
- Increments `callbackCount`.
- Iterates all `AudioBuffer` samples, skipping non-finite values.
- Tracks running max (`peakLevel`) and sum-of-squares for RMS.

`snapshot()` returns a `ProcessTapDiagnosticsSnapshot` with:
- `callbackCount`, `measuredSampleCount`, `peakLevel`, `rmsLevel`.
- `detectedNonSilentAudio`: `peakLevel > 0.001`.
- `progress: ProcessTapDiagnosticProgress` (for UI level meter).

Shared by both Replay Probe and Live Control to keep measurement semantics consistent.
Covered by `ProcessTapDiagnosticsAccumulatorTests`.

---

## Cleanup Lifecycle

**`ProcessTapResourceContext`** (`ProcessTapLifecycle.swift`) is the Core Audio resource
holder. Its `cleanup()` method:
- Is idempotent: guarded by `cleanupLock` + `didCleanUp` flag.
- Multiple concurrent stop paths (timeout, user stop, output change) can race — only the
  first one proceeds.
- Logs every step via `AppLogger.cleanup`.

**`ProcessTapLiveSession`** has its own `cleanupLock` + `didBeginStop` flag so
`beginStopping()` is also idempotent.

On app termination (`NSApplication.willTerminateNotification` + `deinit`),
`stopProcessTapLiveControlForTermination()` runs a synchronous (no async) teardown of every
active/pending Process Tap work item via the shared `tearDownAllProcessTapWork(liveStopReason:)`
helper — `stopLiveControlNow`, Two-App Readiness stop, and cancellation of all tasks, probes,
and helper resolution.

`MixerViewModel` also owns two app-lifetime `NSWorkspace` observers for system sleep/wake
(registered in `init`, removed in `deinit`), independent of the menu-bar panel lifecycle:
- **`willSleepNotification` → `handleSystemWillSleep()`** reuses the same
  `tearDownAllProcessTapWork(liveStopReason:)` path with a typed `.systemSleep` reason, so a
  sleep tears down all active/pending work exactly like termination but with accurate
  logs/diagnostics. Pending Product start tokens are invalidated and any late start is rejected
  as stale (session-ID-keyed teardown), preventing resurrection across sleep.
- **`didWakeNotification` → `handleSystemDidWake()`** is refresh-only: it re-reads output
  devices, system volume/mute, and the visible app list, and deliberately does not restart any
  session. See `docs/DECISIONS.md` ("Why system wake is refresh-only").

The hard teardown also clears queued Product starts (via the hard-teardown state reset).

### Product Real stop paths

- **Per-app stop** (row toggle, app exit): `ProductRealStopCoordinator.stopExperimentalControl`
  invalidates only that app's start token and queued start, marks the row pending, and stops its
  session by id in a task registered with the settle gate.
- **Stop All** (banner, Real off, output change): `stopProductLiveSessions` stops every session
  id **sequentially** in one settle-gate-registered task; the public `stopProcessTapLiveControl()`
  also cancels an in-flight helper resolution.
- **App exit**: `stopRealControlForExitedTargetApps` stops only the exited apps' sessions, drops
  their queued starts, and cancels a resolution for a vanished app. Quitting the app selected in
  the Advanced picker stops only Advanced manual control, never other product sessions.

### Known Multi-Session Gaps (open, need real hardware)

- Stops that a controller initiates itself (output change / app exit seen by its diagnostics
  timer, timeout) bypass the lifecycle and settle gates, so many sessions can tear down
  concurrently.
- `tearDownAllProcessTapWork` → `stopLiveControlNow` runs synchronously on the main thread, one
  fade + destroy per session — estimated from the code path at roughly 0.4–3.4 s with many
  sessions, not measured.
- Stop All is sequential (N × fade + destroy).
- No real-hardware resource/CPU characterization exists for more than three sessions.

---

## Logging

`MacMiniMixer/Support/AppLogger.swift`

Uses `os.Logger` from the `OSLog` framework. Five named categories:

| Category | Used for |
|---|---|
| `app` | general app events |
| `audio` | output device changes, volume events |
| `processTap` | tap creation, start, stop, gain updates, per-session starvation attribution (debug) |
| `helperResolution` | helper candidate scanning, cache hits/misses |
| `cleanup` | Core Audio resource teardown |

All logs use `privacy: .public` for app-specific strings (app names, PIDs) to make them
visible in Console.app without redaction in debug builds. No secrets or user content is
logged.

---

## macOS 14.2 Process Tap Availability

The app targets macOS 13.0 but Process Tap requires macOS 14.2.

**Guards**:
- `ProcessTapCoreAudio.isProcessTapAvailable`: `#available(macOS 14.2, *)` check.
- `processTapEligibility(for:)` returns `.unavailable(unsupportedOSMessage)` on older
  macOS.
- All `@available(macOS 14.2, *)` annotated methods in `ProcessTapLifecycle.swift` and
  both live controller implementations.
- Live controller `startLiveControlSynchronously` checks `#available(macOS 14.2, *)`
  before calling `attemptStart`.

On macOS < 14.2:
- App launches and runs normally.
- Output device and system volume features work.
- App discovery works.
- All Process Tap diagnostic UI is visible but returns `unsupportedOS` outcomes.
- No crash or degraded state.

---

## What Is Real vs Mock-Only

### Real (production behavior)

- `MenuBarExtra`, panel, app rows.
- `WorkspaceApplicationLister` — real running app list.
- `CoreAudioOutputDeviceLister` — real hardware output devices.
- `CoreAudioOutputDeviceController` — real default output switching.
- `CoreAudioSystemVolumeReader` — real system volume reading.
- `CoreAudioSystemVolumeController` — real system volume setting.
- All Process Tap paths when macOS 14.2+ and permission granted.
- Helper process scanning and probing.
- Helper cache.

### Preview-Only / Fallbacks in Production Build

- `PreviewAudioStateController` — per-app volume/mute state for rows without an active Product
  Real session is UI state only, no system effect. When global "Real app control" is OFF, slider
  moves do nothing to real audio.
- `MockApplicationLister`, `MockOutputDeviceLister` — fallbacks inside
  `WorkspaceApplicationLister` / `CoreAudioOutputDeviceLister`, not the main app flow. The other
  former production mocks (`MockSystemVolumeController`, `MockSystemVolumeReader`,
  `MockOutputDeviceController`, `MockProcessTapTester`) were deleted; tests use their own private
  fakes.

---

## What Is Intentionally Not Implemented

- **HAL driver**: no kernel extension, no user-space HAL plug-in, no virtual audio driver.
- **Persistent virtual audio device**: the app does not install any audio device that
  persists across sessions.
- **Production-grade multi-app mixer**: any number of rows can be Real at once (no app-count
  limit, `maxSessions: nil`), but this is experimental and only characterized on real hardware
  up to three sessions; the gaps above are still open.
- **Audio saving**: no audio is written to disk at any point.
- **Private APIs**: the app uses only public Core Audio, AudioToolbox, and AppKit APIs.
- **App Store distribution**: not targeted; System Audio Recording permission and
  per-process tap require entitlements that may be incompatible with sandbox.
- **Automatic control on app appearance**: no capture starts until the user explicitly
  interacts with a row while global mode is ON.
- **Tab-level browser mapping**: helper PIDs are not stable across tab reloads or browser
  restarts. Cached mappings are validation-first but not persistently tracked.
- **General per-app volume for all apps by default**: only rows the user has made Real (with the
  global toggle ON) are real. All others are preview/UI state.
- **Notarized distribution**: packaged zips (`scripts/package-app.sh`, CI artifact, draft
  releases) are ad-hoc signed only; Developer ID signing + notarization is documented in
  `docs/RELEASING.md` but not implemented.

---

## Key File Reference

| File | Purpose |
|---|---|
| `MacMiniMixer/App/MacMiniMixerApp.swift` | Entry point, DI wiring |
| `MacMiniMixer/Features/Mixer/MixerViewModel.swift` | `@MainActor` cross-subsystem router and lifecycle/UI orchestration: app list/preview state, product-vs-Advanced stop router, shared stop display/status, output-change and sleep/termination fan-out, busy gating |
| `MacMiniMixer/Features/Mixer/ProductRealControlCoordinator.swift` | Product Real facade (constructs, wires, forwards) |
| `MacMiniMixer/Features/Mixer/ProductRealControlStateStore.swift` | Single `ProductRealControlState` source + `onWillChange` |
| `MacMiniMixer/Features/Mixer/ProductRealControlState.swift` | Product Real state value types (sessions, tokens, pending ops, queued starts) + `ProductRealStartSettleGate` |
| `MacMiniMixer/Features/Mixer/ProductRealStartCoordinator.swift` | Resolution, start preflight/body, queued start lane, diagnostics focus, starvation attribution log |
| `MacMiniMixer/Features/Mixer/ProductRealStopCoordinator.swift` | Per-app stop, Stop All, stop callback, app-exit cleanup, hard-teardown reset |
| `MacMiniMixer/Features/Mixer/ProductRealControlSideEffects.swift` | Seam protocols between the Product Real coordinators and the view model |
| `MacMiniMixer/Features/Mixer/RealControlBannerPresenter.swift` | Pure banner text/labels ("first two +N more", Stop / Stop All) |
| `MacMiniMixer/Features/Mixer/MixerVisibleAppsFilter.swift` | Pure visible-row filter (audio-relevant, active, resolving, queued) |
| `MacMiniMixer/Features/Mixer/AdvancedHelperDiscoveryCoordinator.swift` | Advanced helper discovery, probe, auto-detect, and Advanced helper target |
| `MacMiniMixer/Features/Mixer/AdvancedHelperDiscoveryState.swift` | Advanced helper target and auto-detect score value types |
| `MacMiniMixer/Features/Mixer/SystemOutputCoordinator.swift` | System volume/device state and pure operations |
| `MacMiniMixer/Features/Mixer/AdvancedProcessTapDiagnosticsCoordinator.swift` | Process Tap Test, Mute Probe, and Replay Probe orchestration |
| `MacMiniMixer/Features/Mixer/AdvancedLiveControlCoordinator.swift` | Manual Advanced Live start/stop orchestration |
| `MacMiniMixer/Features/Mixer/TwoAppReadinessCoordinator.swift` | Advanced Two-App Readiness orchestration |
| `MacMiniMixer/Features/MenuBar/MixerPanelView.swift` | Panel UI layout |
| `MacMiniMixer/Features/MenuBar/MenuBarRootView.swift` | Thin root wrapper |
| `MacMiniMixer/Features/Mixer/MixerAppRowView.swift` | Per-app row UI |
| `MacMiniMixer/Features/Mixer/MixerAppItem.swift` | App data model + audio-relevance filter |
| `MacMiniMixer/Services/Audio/ProcessTap/AppAudioTargetResolving.swift` | Helper resolution protocol + `HelperAudioTargetResolver` |
| `MacMiniMixer/Services/Audio/ProcessTap/HelperProcessCandidateDiscovery.swift` | Process tree / name-match scanning |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLifecycle.swift` | `ProcessTapCoreAudio` utilities + `ProcessTapResourceContext` |
| `MacMiniMixer/Services/Audio/ProcessTap/CoreAudioProcessTapLiveController.swift` | Live control implementation + session, output queue, gain ramp |
| `MacMiniMixer/Services/Audio/ProcessTap/CoreAudioProcessTapReplayProbe.swift` | Replay Probe implementation |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapTwoAppReadinessTesting.swift` | Two-App Readiness implementation |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLiveSessionManager.swift` | Session manager (`maxSessions: Int?`) + Core Audio lifecycle gate + compatibility adapter |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLiveSessionState.swift` | Session ID, phase, state value types |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapOutputBufferCopier.swift` | Shared Float32 sample copy + gain |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapDiagnosticsAccumulator.swift` | Thread-safe callback/peak/RMS accumulator + per-session diagnostics publish gate (~4 Hz) |
| `MacMiniMixer/Services/Audio/PreviewAudioStateController.swift` | Production `AudioControlling`: in-memory preview slider/mute state |
| `MacMiniMixer/Services/Audio/CoreAudioSystemVolumeController.swift` | System volume write + read-only writability probe |
| `MacMiniMixer/Services/Audio/CoreAudioSystemVolumeReader.swift` | System volume read |
| `MacMiniMixer/Services/Audio/CoreAudioOutputDeviceLister.swift` | Output device enumeration + filtering |
| `MacMiniMixer/Services/Audio/CoreAudioOutputDeviceController.swift` | Default output device switching |
| `MacMiniMixer/Support/AppConstants.swift` | All timing, buffer size, layout constants; `maxConcurrentLiveSessions` (`nil`) |
| `MacMiniMixer/Support/AppLogger.swift` | `os.Logger` category definitions |
| `scripts/package-app.sh` | Release build → ad-hoc signed zip + `.sha256` (CI `package` job, `release.yml`) |
