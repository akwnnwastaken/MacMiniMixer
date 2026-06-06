# MacMiniMixer — Quick Start for Agents and Contributors

## What It Is

Native Swift + SwiftUI macOS menu bar app. Inspired by Windows Volume Mixer.
No third-party dependencies. No private APIs. No HAL driver. No App Store target.

---

## Current Status (v0.12)

- Stable: system output volume control, output device listing/switching, running app discovery.
- Experimental: per-app Process Tap Live Control (one app at a time), browser/helper row
  resolution, Replay Probe, Two-App Readiness diagnostic.
- Main product allows **one** real-controlled app/session at a time.
- App rows are mock-only by default. Real control requires the global "Real app control"
  toggle (OFF by default) plus explicit user interaction.

---

## What Works Reliably Now

- Menu bar app, mixer panel, liquid/glass UI.
- Real output device list, switching, live refresh, external default-output sync.
- Real system volume read, set, mute-to-zero/restore, live sync.
- Real running app discovery via NSWorkspace, with audio-relevance filtering.
- Process Tap Test and Replay Probe (user-triggered, Advanced section).
- One-app Live Control with Start/Stop, gain, fade-in/out, 60s timeout.
- Browser/helper row resolution behind the global experimental toggle.
- Validation-first in-memory helper cache.
- Advanced Helper Process Discovery + Find audio helper auto-detect.
- Two-App Readiness diagnostic (Advanced only, 10s, isolated from main product).
- macOS 14.2 availability guard; deployment target remains macOS 13.0.
- GitHub Actions build/test CI, XCTest target, and fake-backed characterization tests
  for helper discovery, helper resolution, live control, coordinators, and Two-App
  Readiness.

---

## What Is Experimental / Fragile

- Browser/helper row resolution: helper PIDs change on tab reload, browser restart, or
  navigation. Cache is validation-first but not persistent.
- Live Control audio quality: fade-in/out ramp is tuned but not regression-tested across
  all macOS versions.
- Two-App Readiness: works in controlled tests (Spotify + YouTube helper, 0 drops).
  Not production-ready as multi-app mixer.
- Helper confidence scoring: works when audio is actively playing; silent apps always
  score zero.

---

## What Must Not Be Changed Casually

- **`ProcessTapResourceContext.cleanup()`** — idempotency lock is critical. Race between
  timeout, user-stop, and output-device-change paths. Touch carefully.
- **`ProcessTapLiveOutputQueue` / `ProcessTapReplayOutputQueue`** — audio callback path.
  Any change risks audible regression. Manual audio testing required.
- **`ProcessTapLiveGainRamp`** — fade-in/fade-out frame math. Changes affect audio clicks.
- **`ProcessTapDiagnosticsAccumulator`** — shared between Live and Replay paths. Changing
  measurement semantics (peak, RMS) affects all diagnostics UI.
- **`AppConstants`** — timing values (fade durations, buffer count, timeout) are tuned.
  Changing them without testing can cause buffer drops or timing issues.
- **`HelperAudioTargetResolver` cache logic** — validation-first design is intentional.
  Do not make it persist across launches or skip PID/eligibility validation.
- **`maxSessions = 1`** in the main product `ProcessTapLiveSessionManager` — do not raise
  this without thorough Two-App Readiness validation first.

---

## Most Important Files

| File | Why |
|---|---|
| `MacMiniMixer/App/MacMiniMixerApp.swift` | Entry point, all DI wiring |
| `MacMiniMixer/Features/Mixer/MixerViewModel.swift` | Central traffic controller for product Real Control, app list/mock rows, lifecycle cleanup, cross-feature busy gating, and status |
| `MacMiniMixer/Features/Mixer/AdvancedHelperDiscoveryCoordinator.swift` | Advanced helper scan, probe, auto-detect, and Advanced helper target |
| `MacMiniMixer/Features/Mixer/SystemOutputCoordinator.swift` | System volume/device state and pure volume/device operations |
| `MacMiniMixer/Features/Mixer/AdvancedProcessTapDiagnosticsCoordinator.swift` | Advanced Process Tap Test, Mute Probe, and Replay Probe |
| `MacMiniMixer/Features/Mixer/AdvancedLiveControlCoordinator.swift` | Manual Advanced Live start/stop orchestration |
| `MacMiniMixer/Features/Mixer/TwoAppReadinessCoordinator.swift` | Advanced Two-App Readiness selection, target options, start/stop, snapshot/result state |
| `MacMiniMixer/Services/Audio/ProcessTap/CoreAudioProcessTapLiveController.swift` | Live Control implementation |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLifecycle.swift` | Core Audio resource management |
| `MacMiniMixer/Services/Audio/ProcessTap/AppAudioTargetResolving.swift` | Helper resolution + cache |
| `MacMiniMixer/Services/Audio/ProcessTap/HelperProcessCandidateDiscovery.swift` | Process tree scanning |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapOutputBufferCopier.swift` | Shared sample copy (unit tested) |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapDiagnosticsAccumulator.swift` | Shared peak/RMS accumulator (unit tested) |
| `MacMiniMixer/Support/AppConstants.swift` | All timing and buffer constants |
| `MacMiniMixer/Support/AppLogger.swift` | `os.Logger` categories |

---

## Safest Next Technical Steps

1. **Plan product Real Control extraction read-only** — keep implementation centralized
   until direct PID, helper PID, cache invalidation, and lifecycle cleanup boundaries are
   fully understood.
2. **Improve non-writable output volume UX** — make unwritable-device failures clearer
   without changing Core Audio behavior.
3. **Add accessibility labels** for app rows, sliders, mute buttons, Advanced controls,
   and output-device controls.
4. **Harden helper PID-change handling** and document behavior across browser reloads,
   navigation, and helper restarts.
5. **Add more lifecycle/status characterization tests** before moving more of
   `MixerViewModel`.

---

## Manual Test Essentials After Any Code Change

After touching the audio path or MixerViewModel, at minimum verify:

- System volume slider moves real system volume.
- Mute/unmute restores previous volume.
- Output device switching works and refreshes volume.
- Spotify/Music direct Live Control starts, gain applies, Stop works.
- Live control stops on 60s timeout and on output device change.
- App quit during live control stops session cleanly (check Console for cleanup logs).
- Two-App Readiness runs 10s with zero drops for Spotify + Music.
- The full XCTest suite passes.

Full checklist: `docs/MANUAL_TEST_CHECKLIST.md`

---

## Safety Rules

- **No private APIs.** Only public Core Audio, AudioToolbox, AppKit APIs.
- **No HAL driver.** No kernel extension, no user-space HAL plug-in, no system extension.
- **No persistent virtual audio device.** The private aggregate device is temporary and
  destroyed in cleanup. Nothing survives an app quit or crash.
- **No audio saving.** No audio is written to disk anywhere in the codebase.
- **Main product: one active session.** `maxSessions = 1` in the main session manager.
  Do not raise it until Two-App Readiness results are consistently stable.
- **Advanced tools stay in Advanced.** Process Tap Test, Replay Probe, Two-App Readiness,
  and Helper Discovery must remain in the collapsed Advanced section, not exposed in the
  main mixer UI.
- **Helper mappings are not persisted.** Cache is in-memory, validation-first, and
  invalidated on PID change. Do not add disk persistence without careful design.
- **Real control is opt-in.** The global "Real app control" toggle defaults to OFF.
  No capture starts automatically when an app appears in the list.

---

## Longer Reference Docs

- [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) — full system architecture with file references
- [`docs/ROADMAP.md`](ROADMAP.md) — prioritized technical roadmap with risk and file notes
- [`docs/DECISIONS.md`](DECISIONS.md) — why key design choices were made
- [`docs/MANUAL_TEST_CHECKLIST.md`](MANUAL_TEST_CHECKLIST.md) — full manual test checklist
