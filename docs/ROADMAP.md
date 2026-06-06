# MacMiniMixer — Technical Roadmap

Based on README v0.12 + current code state.

Each item lists: **priority**, **risk**, likely files, and a short explanation.

---

## Completed in v0.12

- `ProcessTapLiveSessionManager` foundation with `ProcessTapLiveSessionID` and
  `ProcessTapLiveSessionState`.
- Browser/helper row resolution in main mixer behind global Real App Control toggle.
- Validation-first in-memory helper cache (`HelperAudioTargetResolver`).
- Advanced Helper Process Discovery (`HelperProcessCandidateDiscovery`).
- `Find audio helper` auto-detect with sequential probing and scoring.
- Advanced helper target for Process Tap Test, Replay Probe, Two-App Readiness.
- Typed outcomes throughout (no string-comparison control flow).
- Thread-safe `ProcessTapResourceContext.cleanup()` with idempotency lock.
- `os.Logger` diagnostics via `AppLogger` categories.
- macOS 14.2 Process Tap availability guards (deployment target stays macOS 13.0).
- MIT License.
- GitHub Actions build/test CI.
- XCTest target with fake-backed tests for helper discovery, helper resolver/cache/fast
  path, permission messaging, live session management, live control behavior,
  coordinators, Two-App Readiness characterization, diagnostics accumulation, and output
  buffer copying.
- `ProcessTapDiagnosticsAccumulator` shared between Replay Probe and Live Control.
- `ProcessTapOutputBufferCopier` extracted and covered by unit tests.
- `AdvancedHelperDiscoveryCoordinator` extracted for helper discovery, manual probe,
  auto-detect, and Advanced helper target ownership.
- `SystemOutputCoordinator` extracted for system volume/device state and pure
  volume/device operations.
- `AdvancedProcessTapDiagnosticsCoordinator` extracted for Process Tap Test, Mute Probe,
  and Replay Probe.
- `AdvancedLiveControlCoordinator` extracted for manual Advanced Live start/stop
  orchestration.
- Fake-backed characterization tests for product/manual live-control busy gating and
  Two-App Readiness behavior.

---

## Immediate Stabilization

### Fix or document writable-volume failure UX

**Priority**: High | **Risk**: Low

Some output devices (HDMI, certain USB) return `false` from
`CoreAudioSystemVolumeController.setCurrentOutputVolumeScalar`. The app already shows a
status warning, but there is no persistent state or explanation in the UI beyond the 2.5s
auto-clearing message.

**Files**: `CoreAudioSystemVolumeController.swift`, `MixerPanelView.swift`,
`MixerViewModel.swift`

**Action**: Consider making writable-volume failure a persistent row state indicator,
or add a tooltip that explains the device does not expose a volume API.

---

### Helper PID change handling

**Priority**: High | **Risk**: Medium

Helper PIDs can change when browser tabs are closed and reopened, browser helpers restart,
or the user navigates away. The current cache is validation-first (checks PID existence and
tap eligibility) but does not re-probe on PID change during an active live session.

**Files**: `AppAudioTargetResolving.swift`, `MixerViewModel.swift`

**Action**: When a live control session stops with `liveControlAppExited` and the visible
app is still running, consider automatically retrying resolution (fresh probe) rather than
just showing a warning. Already partially handled: `invalidateCachedTarget` is called on
`liveControlAppExited`, and `startResolvedExperimentalControl(allowsCachedLookup: false)`
is called after a cached-helper start failure.

---

## Short-Term Safe Refactors

### Continue MixerViewModel split

**Priority**: High | **Risk**: Medium

`MixerViewModel.swift` is now about 1,370 lines and is no longer fully monolithic.
Advanced helper discovery, system output, Advanced Process Tap diagnostics, and manual
Advanced Live orchestration, and Advanced Two-App Readiness have been extracted into
coordinators. The view model still owns app list/mock row state, product Real App Control,
lifecycle cleanup, cross-feature coordination, and status messages.

**Files**: `MixerViewModel.swift` and likely new files such as:
- possible product Real Control or lifecycle/status coordinator files after read-only
  planning

**Approach**: Continue incrementally. Keep product Real App Control in `MixerViewModel`
until a separate read-only plan confirms safe boundaries for helper resolution, cache
invalidation, live session state, and lifecycle cleanup.

---

### Product Real Control read-only extraction plan

**Priority**: High | **Risk**: Low

Product Real App Control is the highest-risk remaining cluster because it combines direct
visible PID control, browser/helper resolution, cache invalidation, one-active-session
rules, app-row slider/mute behavior, timeout cleanup, app/helper exit handling, output
device change cleanup, and menu bar/banner state.

**Files**: `MixerViewModel.swift`, `AppAudioTargetResolving.swift`,
`ProcessTapLiveSessionManager.swift`, `MixerAppRowView.swift`.

**Action**: Do a read-only boundary assessment before any extraction. Do not move product
Real Control until the plan identifies stable APIs and the required characterization
tests.

---

### OutputQueue architecture evaluation

**Priority**: Medium | **Risk**: Medium

`ProcessTapLiveOutputQueue` and `ProcessTapReplayOutputQueue` are structurally very
similar (both use `AudioQueueNewOutput`, buffer pool, same copy path). The main difference
is that the live queue starts lazily (after priming buffers) and has a gain ramp, while the
replay queue starts eagerly.

**Files**: `CoreAudioProcessTapLiveController.swift`,
`CoreAudioProcessTapReplayProbe.swift`, `ProcessTapOutputBufferCopier.swift`

**Action**: After manual audio regression testing confirms both paths are stable, evaluate
whether a shared `ProcessTapOutputQueue` with a configuration struct would reduce
duplication without introducing coupling. Do not unify prematurely — audio path changes
carry regression risk.

---

### Consistent stop-reason propagation

**Priority**: Medium | **Risk**: Low

`ProcessTapLiveStopReason` and `ProcessTapReplayProbeStopReason` and
`ProcessTapCandidateProbeStopReason` are three separate enums with overlapping values. The
names are clear enough today but could be consolidated into one typed stop reason if the
code grows.

**Files**: `ProcessTapLiveState.swift`, various protocol files.

---

## Testing and CI Improvements

### Add more targeted unit tests around remaining MixerViewModel clusters

**Priority**: Medium | **Risk**: Low

The remaining `MixerViewModel` clusters are product Real App Control, app list/mock row
state, lifecycle cleanup, cross-feature busy gating, and status messages. Add narrow
tests before moving any of these responsibilities.

**Files**: `MixerViewModel.swift`, new test file using mock implementations.

---

### Structured release notes / CHANGELOG

**Priority**: Low | **Risk**: Low

Consider adopting a `CHANGELOG.md` in Keep a Changelog format. Each roadmap milestone
can produce one entry rather than embedding changes only in README.

---

## UX and Accessibility Improvements

### Accessibility labels for mixer rows

**Priority**: Medium | **Risk**: Low

App rows, sliders, and mute buttons lack explicit `accessibilityLabel` and
`accessibilityHint` values. Screen reader users would get generic slider and button labels.

**Files**: `MixerAppRowView.swift`, `MixerPanelView.swift`.

---

### Better visual feedback during helper resolution

**Priority**: Medium | **Risk**: Low

When a helper row is being resolved (`.resolving` state), the row shows a spinner. The
duration can be up to several seconds if multiple candidates are probed. A brief
explanation of what is happening would help users understand the delay.

**Files**: `MixerAppRowView.swift`, `MixerViewModel.swift`.

---

### Experimental per-app volume boost

**Priority**: Low | **Risk**: High | **Status**: Later research / experimental

Product Real App Control may eventually allow an eligible selected app to be amplified
above its original audio level, with an initial research target of 100-200%.

**User value**: Mute, reduce, or experimentally boost applications that provide no
built-in volume controls.

This is not part of the current implementation phase. It must be off by default and
require a separate explicit opt-in from normal 0-100% per-app volume control. The first
implementation should begin later with characterization tests and a narrowly scoped
experimental mode.

Required constraints:
- Continue using only public Process Tap/Core Audio APIs.
- No HAL driver, persistent virtual audio device, private APIs, third-party dependencies,
  or disk audio saving.
- Preserve the current one-active-real-session limitation initially.
- Affect only the selected application.
- Do not boost system output volume.
- Do not affect unrelated applications.
- Test direct visible-PID and browser/helper-PID paths separately.
- Avoid sudden gain jumps, especially with headphones.
- Show a clear warning before enabling gain above 100%.

Before implementation, require a separate read-only assessment of current gain mapping,
available audio headroom, clipping risk, distortion risk, hard clipping versus limiter or
soft-clipping options, CPU usage, latency, long-running Process Tap resource behavior,
repeated gain updates, sleep/wake behavior, output-device changes, controlled app exit
cleanup, browser/helper PID exit or replacement, and recovery after Core Audio failure.

Do not begin implementation until current Product Real App Control lifecycle and
coordinator cleanup work are stable. Do not treat 200% as guaranteed clean output; the
actual safe maximum may depend on clipping, limiter behavior, source material, and output
hardware.

**Files**: likely `MixerAppRowView.swift`, `MixerViewModel.swift`,
`CoreAudioProcessTapLiveController.swift`, and focused tests after a read-only assessment.

---

### Configurable Advanced live control timeout

**Priority**: Low | **Risk**: Low

Manual Advanced Live Control still uses the limited live policy from
`AppConstants.processTapLiveControlMaxDuration`; Product Real App Control uses an
indefinite policy while healthy. A settings preference for the Advanced/manual value could
help power users who want different diagnostic session lengths.

**Files**: `AppConstants.swift`, `MixerPanelView.swift` or a new Settings window.

---

### Settings / Preferences window

**Priority**: Low | **Risk**: Low

Currently there are no user-configurable preferences beyond the in-panel toggles.
Possible settings: live control timeout, default gain, Show All default, audio-relevance
keyword customization.

**Files**: new `SettingsView.swift`, `AppConstants.swift`.

---

## Browser/Helper Production Hardening

### Improve helper resolver confidence scoring

**Priority**: High | **Risk**: Medium

The current scoring formula weights `hasDetectedAudio` >> RMS >> peak >> callback count.
This works well when audio is actively playing, but silent-at-rest apps always score zero.
A production-grade resolver would need a better signal (e.g., short test with user-visible
audio state, or heuristic based on process name hierarchy).

**Files**: `AppAudioTargetResolving.swift`.

---

### Handle tab/page navigation causing helper PID change

**Priority**: High | **Risk**: High

When the user navigates to a new YouTube tab or reloads the page, the WebKit GPU or
content process PID may change. The live session would stop with `liveControlAppExited`.
The next slider interaction would re-resolve from scratch (cache is invalidated). This
behavior is correct but surprising. A smarter approach would be to monitor PID stability
before treating the helper as stable.

**Files**: `AppAudioTargetResolving.swift`, `CoreAudioProcessTapLiveController.swift`.

---

### Safari/WebKit helper confidence improvements

**Priority**: Medium | **Risk**: High

`com.apple.WebKit.GPU` is a known helper for Safari/YouTube audio. It may serve multiple
tabs at once. Selecting it as the per-row target gives system-wide WebKit audio, not
per-tab. This is a fundamental architectural limitation of the Process Tap + helper PID
approach for browser audio.

**Files**: `HelperProcessCandidateDiscovery.swift`, `AppAudioTargetResolving.swift`.

---

## Future Multi-App Mixer Research

### Multi-session architecture evaluation

**Priority**: Medium | **Risk**: High

`ProcessTapLiveSessionManager` has `maxSessions` infrastructure. Raising it to > 1 in
the main product path would allow simultaneous control of multiple rows. The key open
questions are:
- CPU and latency impact of multiple concurrent IOProcs.
- Drop-free buffer timing across independent `AudioQueueRef` instances.
- Whether a centralized renderer (one AudioQueue that mixes N taps) is better than N
  independent output queues.

**Files**: `ProcessTapLiveSessionManager.swift`,
`CoreAudioProcessTapLiveController.swift`.

**Not a short-term action**: Two-App Readiness diagnostics need to show stable results
(zero drops, low failure count, consistent callbacks) across many test runs before
considering exposing this in the main UI.

---

### Centralized mixer / renderer evaluation

**Priority**: Low | **Risk**: High

Independent per-app `AudioQueue` instances have independent timing. A centralized mixer
that receives audio from N process taps and routes them through a single output queue
would have better timing guarantees. This would require a significantly different
architecture than the current one-controller-per-session model.

---

## Long-Term HAL / Virtual Device Evaluation

If the Process Tap + AudioQueue replay approach proves insufficient for stable multi-app
simultaneous control (latency, drops, timing), a user-space HAL audio plug-in (virtual
audio device) could act as a proper mixer. This is a large engineering effort and requires
installer/uninstaller work.

- **Background Music** and **BlackHole** can be studied architecturally as reference
  implementations. Their code is not copied.
- This is only worth evaluating after the pure Process Tap approach has been exhausted
  and documented as insufficient.

**Priority**: Low | **Risk**: Very High

**Files involved**: would require new driver infrastructure outside the current app bundle.

---

## Packaging and Distribution

### GitHub release packaging

**Priority**: Medium | **Risk**: Low

The README says the app targets direct distribution (not App Store). A `.dmg` or
notarized `.zip` would allow users to install without building from source.

**Files**: new release workflow in `.github/workflows/`.

---

### Installer / uninstaller consideration

**Priority**: Low | **Risk**: Low

Currently the app leaves no persistent state. If a HAL driver or launch agent is ever
added, an uninstaller would be required. For the current architecture (no kernel
extension, no persistent virtual device), uninstalling is as simple as deleting the app.

---

## Summary by Priority

| Priority | Items |
|---|---|
| Critical | — |
| High | Writable-volume UX, helper PID change handling, helper resolver confidence, continue MixerViewModel split, Product Real Control read-only plan |
| Medium | OutputQueue evaluation, accessibility labels, helper resolution UX feedback, multi-session architecture evaluation, GitHub release packaging |
| Low | Experimental per-app volume boost, unified stop-reason enum, configurable timeout, settings window, CHANGELOG, centralized renderer, HAL evaluation, installer |
