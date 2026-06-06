# MacMiniMixer — Architecture Reference

Version: v0.12 experimental.
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
| `MockAudioController` | stub | `AudioControlling` |
| `CoreAudioOutputDeviceLister` | real | `OutputDeviceListing` |
| `CoreAudioOutputDeviceController` | real | `OutputDeviceControlling` |
| `CoreAudioSystemVolumeReader` | real | `SystemVolumeReading` |
| `CoreAudioSystemVolumeController` | real | `SystemVolumeControlling` |
| `CoreAudioProcessTapTester` | real | `ProcessTapTesting` |
| `CoreAudioProcessTapReplayProbe` | real | `ProcessTapReplayProbing` |
| `ProcessTapLiveSessionManager` wrapping `CoreAudioProcessTapLiveController` | real | `ProcessTapLiveControlling` |
| `CoreAudioProcessTapTwoAppReadinessTester` | real | `ProcessTapTwoAppReadinessTesting` |
| `CoreAudioProcessTapCandidateAudioProbe` | real | `ProcessTapCandidateAudioProbing` |
| `SystemProcessLister` | real | `ProcessListing` |
| `HelperAudioTargetResolver` | real | `AppAudioTargetResolving` |

`MockAudioController` is the only mock used in production. Per-app volume has no real
system-level API, so the per-app slider state is UI-only unless Process Tap Live Control
is active for that row.

The `MenuBarExtra` body passes `MixerViewModel` to `MenuBarRootView`, which passes it
to `MixerPanelView`.

---

## Mixer Coordination Model

`MacMiniMixer/Features/Mixer/MixerViewModel.swift`

`MixerViewModel` is no longer fully monolithic, but it remains the central `@MainActor`
traffic controller for cross-feature behavior. It still owns product Real App Control,
Two-App Readiness, app list/mock row state, lifecycle cleanup, cross-feature busy gating,
and status messages.

Extracted coordinators:

| Coordinator | Owns |
|---|---|
| `AdvancedHelperDiscoveryCoordinator` | Advanced helper discovery selection, scan, manual probe, Find audio helper, and Advanced helper target |
| `SystemOutputCoordinator` | System volume/device state and pure volume/device operations |
| `AdvancedProcessTapDiagnosticsCoordinator` | Process Tap Test, Mute Probe, Replay Probe, diagnostic target selection, and replay gain/result state |
| `AdvancedLiveControlCoordinator` | Manual Advanced Live start/stop orchestration |

`MixerViewModel` forwards coordinator state and methods to keep the existing SwiftUI view
surface stable. It also preserves centralized cleanup orchestration: output device
changes, panel close, app termination, active live sessions, helper tasks, Advanced tools,
and Two-App Readiness are still coordinated from one place.

---

## Main UI Structure

### MenuBarExtra

`MacMiniMixerApp.body` uses `MenuBarExtra` with `.window` style. The menu bar icon shows
`slider.horizontal.3` normally and `waveform.circle.fill` when Process Tap Live Control is
active. The icon state is driven by `MixerViewModel.isProcessTapLiveControlActive`.

### MenuBarRootView

`MacMiniMixer/Features/MenuBar/MenuBarRootView.swift`

A thin pass-through that renders `MixerPanelView`. No logic here.

### MixerPanelView

`MacMiniMixer/Features/MenuBar/MixerPanelView.swift`

The full mixer panel. Fixed width 352pt, ultraThinMaterial background with rounded
corners. Sections from top to bottom:

1. **Header** — title + output device button toggle.
2. **Active live control banner** — orange waveform banner with Stop button, visible only
   when `isProcessTapLiveControlActive`.
3. **Status message** — auto-clears after 2.5s. Warning, info, or success style.
4. **Output device selector** — `OutputDeviceSelectorView`, shown on button toggle.
5. **System Output section** — mute button + slider + current output device name label.
6. **Applications section** — app rows, "Show all" checkbox, "Real app control" toggle.
7. **Advanced section** — collapsible, contains `ProcessTapTestView`,
   `HelperProcessDiscoveryView`, `TwoAppReadinessTestView`.
8. **Quit button**.

`onAppear` refreshes apps, output devices, and system volume.
Two async `Task` loops run while the panel is visible: one refreshes system volume every
1 second, another refreshes output devices every 2 seconds.
`onDisappear` calls `stopTwoAppReadinessForPanelClose()`.

### MixerAppRowView

`MacMiniMixer/Features/Mixer/MixerAppRowView.swift`

Each visible app gets one row. Contains:
- App icon (real `NSImage` from NSWorkspace or system symbol fallback).
- App name (truncated, fixed width 66pt).
- Volume slider (mock or real, depending on mode).
- Mute toggle (same caveat).
- Optional live control toggle button (shown only when the "Real app control" mode is ON
  or when that row is the active experimental target).

Row state is "active" when `isExperimentalControlActive` is true for that app ID. Active
rows show an orange waveform indicator. Resolving rows show a spinner.

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
(AirPods auto-connect), `MixerViewModel.refreshOutputDevices()` preserves the existing
cross-feature cleanup behavior and stops any active Live Control, Two-App Readiness, or
helper probe.

---

## Running App Discovery

`MacMiniMixer/Services/Applications/WorkspaceApplicationLister.swift`

`WorkspaceApplicationLister.listApplications()` reads `NSWorkspace.shared.runningApplications`,
filters to `.regular` activation policy apps, and maps each to a `MixerAppItem` with:
- `id` = bundle identifier or fallback.
- `name` = localizedName.
- `icon` = `NSWorkspace.shared.icon(forFile:)` or system symbol fallback.
- `processIdentifier` = pid_t cast to Int32.
- `volume` = 100 (default mock).
- `isMuted` = false.

**Audio-relevance filtering**: `MixerAppItem.isLikelyAudioRelevant` matches name or
bundle ID against allow-keywords (Spotify, Music, Safari, Chrome, Discord, Zoom, etc.)
and deny-keywords (Finder, Notes, Xcode, Terminal, etc.). The "Show all" checkbox bypasses
this filter.

---

## Main Real App Control Flow

The main product path can start real control for one row when the global
`isExperimentalRealAppControlEnabled` toggle is ON and the user moves a slider or clicks
mute on an eligible inactive row.

**Trigger**: `MixerViewModel.setAppVolume(_:for:)` and `setMuted(_:for:)` both call
`startAutomaticRealControlIfNeeded(for: app)`.

**Guard checks**:
- Global mode must be enabled.
- Not currently two-app readiness running.
- App must be eligible (`isEligibleForExperimentalLiveControl` = has valid PID).
- No other resolution or live control is already active.

**Flow**: `startResolvedExperimentalControl(for: app)` is called.

---

## Direct Visible PID Path

`MixerViewModel.startResolvedExperimentalControl(for: app, allowsCachedLookup:)`

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
- Live control start failed with `.cachedHelper` source → retries without cache.

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

`MacMiniMixer/Services/Audio/ProcessTap/ProcessTapTwoAppReadinessTesting.swift`

`CoreAudioProcessTapTwoAppReadinessTester.startTest(appA:, appB:, gain:, onUpdate:, onFinished:)`:

1. Preflights both targets for tap eligibility.
2. Creates a `TwoAppReadinessRun` with a **separate** `ProcessTapLiveSessionManager(maxSessions: 2)`.
   This is **isolated from the main product session manager**.
3. Starts App A session via `run.manager.startSession(...)`. On failure, marks setup failed.
4. Starts App B session. On failure, stops App A and marks setup failed.
5. Starts a timeout `Task` for `processTapTwoAppReadinessDuration` (10s).
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
- `maxSessions` enforced at reservation time.
- For the main product path, `maxSessions = 1` and one `CoreAudioProcessTapLiveController`
  is injected at init.
- For Two-App Readiness, `maxSessions = 2` and a fresh controller is created per session
  via `controllerFactory`.

The class also implements `ProcessTapLiveControlling` directly (the compatibility interface),
routing through `compatibilityActiveSessionID` for `startLiveControl`, `stopLiveControl`,
and `updateLiveControlGain`. This allows `MixerViewModel` to use it without knowing about
sessions.

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
      change, calls `onDiagnostics`.
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
`stopProcessTapLiveControlForTermination()` calls `stopLiveControlNow` (synchronous, no
async) and cancels all tasks and probes.

---

## Logging

`MacMiniMixer/Support/AppLogger.swift`

Uses `os.Logger` from the `OSLog` framework. Five named categories:

| Category | Used for |
|---|---|
| `app` | general app events |
| `audio` | output device changes, volume events |
| `processTap` | tap creation, start, stop, gain updates |
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

### Mock-Only in Production Build

- `MockAudioController` — per-app volume/mute state is UI state only, no system effect.
  When global "Real app control" is OFF, slider moves do nothing to real audio.
- `MockApplicationLister`, `MockOutputDeviceLister`, `MockSystemVolumeController`, etc.
  are used in tests or as development fallbacks, not in the main app flow.

---

## What Is Intentionally Not Implemented

- **HAL driver**: no kernel extension, no user-space HAL plug-in, no virtual audio driver.
- **Persistent virtual audio device**: the app does not install any audio device that
  persists across sessions.
- **Production multi-app mixer**: only one real-controlled row/session is active at a time
  in the main product path. `maxSessions = 1` in the main session manager.
- **Audio saving**: no audio is written to disk at any point.
- **Private APIs**: the app uses only public Core Audio, AudioToolbox, and AppKit APIs.
- **App Store distribution**: not targeted; System Audio Recording permission and
  per-process tap require entitlements that may be incompatible with sandbox.
- **Automatic control on app appearance**: no capture starts until the user explicitly
  interacts with a row while global mode is ON.
- **Tab-level browser mapping**: helper PIDs are not stable across tab reloads or browser
  restarts. Cached mappings are validation-first but not persistently tracked.
- **General per-app volume for all apps**: only the one active experimental row is real.
  All others are mock.

---

## Key File Reference

| File | Purpose |
|---|---|
| `MacMiniMixer/App/MacMiniMixerApp.swift` | Entry point, DI wiring |
| `MacMiniMixer/Features/Mixer/MixerViewModel.swift` | Central `@MainActor` traffic controller for product Real Control, Two-App Readiness, app list/mock state, lifecycle cleanup, and status |
| `MacMiniMixer/Features/Mixer/AdvancedHelperDiscoveryCoordinator.swift` | Advanced helper discovery, probe, auto-detect, and Advanced helper target |
| `MacMiniMixer/Features/Mixer/AdvancedHelperDiscoveryState.swift` | Advanced helper target and auto-detect score value types |
| `MacMiniMixer/Features/Mixer/SystemOutputCoordinator.swift` | System volume/device state and pure operations |
| `MacMiniMixer/Features/Mixer/AdvancedProcessTapDiagnosticsCoordinator.swift` | Process Tap Test, Mute Probe, and Replay Probe orchestration |
| `MacMiniMixer/Features/Mixer/AdvancedLiveControlCoordinator.swift` | Manual Advanced Live start/stop orchestration |
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
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLiveSessionManager.swift` | Session manager + compatibility adapter |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLiveSessionState.swift` | Session ID, phase, state value types |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapOutputBufferCopier.swift` | Shared Float32 sample copy + gain |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapDiagnosticsAccumulator.swift` | Thread-safe callback/peak/RMS accumulator |
| `MacMiniMixer/Services/Audio/CoreAudioSystemVolumeController.swift` | System volume write |
| `MacMiniMixer/Services/Audio/CoreAudioSystemVolumeReader.swift` | System volume read |
| `MacMiniMixer/Services/Audio/CoreAudioOutputDeviceLister.swift` | Output device enumeration + filtering |
| `MacMiniMixer/Services/Audio/CoreAudioOutputDeviceController.swift` | Default output device switching |
| `MacMiniMixer/Support/AppConstants.swift` | All timing, buffer size, layout constants |
| `MacMiniMixer/Support/AppLogger.swift` | `os.Logger` category definitions |
