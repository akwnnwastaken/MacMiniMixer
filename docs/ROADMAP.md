# MacMiniMixer — Technical Roadmap

Based on README v0.12 + current code state (May 2026).

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
- Initial XCTest target with `ProcessTapOutputBufferCopierTests` and
  `ProcessTapDiagnosticsAccumulatorTests`.
- `ProcessTapDiagnosticsAccumulator` shared between Replay Probe and Live Control.
- `ProcessTapOutputBufferCopier` extracted and covered by unit tests.

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

### Improve Process Tap permission failure messaging

**Priority**: High | **Risk**: Low

When `kAudioDevicePermissionsError` is returned or System Audio Recording permission is
denied, the user sees a short warning message. There is no guidance on how to grant the
permission in System Settings.

**Files**: `CoreAudioProcessTapLiveController.swift`, `CoreAudioProcessTapReplayProbe.swift`,
`ProcessTapTestView.swift (UI)`

**Action**: Show a button or link pointing to System Settings > Privacy > Screen & System
Audio Recording when permission-denied outcomes occur.

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

### MixerViewModel split

**Priority**: High | **Risk**: Medium

`MixerViewModel.swift` is ~1900 lines and handles system volume, output devices, running
apps, Process Tap tests, Replay Probe, Live Control, Two-App Readiness, helper discovery,
and helper auto-detect. This makes it difficult to reason about individual flows in isolation.

**Files**: `MixerViewModel.swift` and likely new files such as:
- `ProcessTapDiagnosticsCoordinator.swift`
- `HelperDiscoveryCoordinator.swift`
- `TwoAppReadinessCoordinator.swift`
- `SystemAudioCoordinator.swift`

**Approach**: Extract each Advanced sub-feature into a coordinator that owns its local
state and exposes a narrow interface to `MixerViewModel`. The split should preserve all
existing behavior exactly. Start with the most self-contained subsystem (e.g., helper
discovery) to validate the pattern before splitting the larger live-control logic.

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

### Add unit tests for HelperAudioTargetResolver cache logic

**Priority**: High | **Risk**: Low

The validation-first cache (`AppAudioHelperResolutionCacheKey`, `validatedCachedTarget`)
is pure logic that can be tested with synthetic `SystemProcessInfo` lists without any real
Core Audio interaction.

**Files**: `AppAudioTargetResolving.swift`, new test file.

---

### Add unit tests for HelperProcessCandidateDiscovery

**Priority**: High | **Risk**: Low

`HelperProcessCandidateDiscovery.candidates(for:, processes:)` is pure logic.
Tests can verify that child/descendant/nameMatch relations are found correctly,
the 30-candidate cap is applied, and `isLikelyHelperResolvable` keyword matching works.

**Files**: `HelperProcessCandidateDiscovery.swift`, new test file.

---

### Add unit tests for MixerViewModel pure state logic

**Priority**: Medium | **Risk**: Low

`MixerViewModel` has pure state-transition logic (e.g., mute/restore volume arithmetic,
`preferredProcessTapAppID`, `experimentalGainOption`) that can be unit tested without
any service dependencies.

**Files**: `MixerViewModel.swift`, new test file using mock implementations.

---

### Add unit tests for ProcessTapLiveSessionManager

**Priority**: Medium | **Risk**: Low

`ProcessTapLiveSessionManager` session lifecycle (reserve, start, stop, max enforcement,
compatibility session tracking) can be tested with a mock `ProcessTapLiveControlling`.

**Files**: `ProcessTapLiveSessionManager.swift`, `MockProcessTapTester.swift` (exists),
new test file.

---

### CI: add test scheme to GitHub Actions

**Priority**: Medium | **Risk**: Low

The current workflow builds the app but may not run the XCTest target in CI. Confirm
the `xcodebuild test` command runs the `MacMiniMixerTests` scheme on the Actions runner.

**Files**: `.github/workflows/build.yml` (or equivalent).

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

### Configurable live control timeout

**Priority**: Low | **Risk**: Low

The 60-second timeout is hardcoded in `AppConstants.processTapLiveControlMaxDuration`.
A settings preference for this value would help power users who want longer sessions.

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
| High | Writable-volume UX, permission failure messaging, helper PID change handling, helper resolver confidence, MixerViewModel split, HelperAudioTargetResolver cache tests, HelperProcessCandidateDiscovery tests |
| Medium | OutputQueue evaluation, session manager tests, CI test scheme, accessibility labels, helper resolution UX feedback, multi-session architecture evaluation, GitHub release packaging |
| Low | Unified stop-reason enum, configurable timeout, settings window, CHANGELOG, centralized renderer, HAL evaluation, installer |
