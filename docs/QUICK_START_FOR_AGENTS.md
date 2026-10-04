# MacMiniMixer — Quick Start for Agents and Contributors

## What It Is

Native Swift + SwiftUI macOS menu bar app. Inspired by Windows Volume Mixer.
No third-party dependencies. No private APIs. No HAL driver. No App Store target.

---

## Current Status (internal v0.14 checkpoint + `[Unreleased]` work)

- Unreleased: no tag, `MARKETING_VERSION` stays `0.13`. See `CHANGELOG.md` and `docs/HANDOFF.md`.
- Stable: system output volume control (with a proactive "Read-only" badge for non-writable
  devices), output device listing/switching, running app discovery.
- Experimental: **Product Real Control** — per-app Process Tap control with **no app-count limit**
  (owner decision; `AppConstants.maxConcurrentLiveSessions` is `nil`). Any number of rows can be
  Real at once; starts go through a single **queued start lane** (one resolution or start in flight,
  the rest wait FIFO with the pending badge). Also browser/helper row resolution, Replay Probe, and
  the Two-App Readiness diagnostic.
- Real-hardware evidence covers **up to three** concurrent sessions only; more sessions have only
  been exercised by fake-backed tests.
- App rows are preview/UI-state only by default. Real control requires the global "Real app control"
  toggle (OFF by default) plus explicit user interaction with a row.

---

## What Works Reliably Now

- Menu bar app, mixer panel, liquid/glass UI.
- Real output device list, switching, live refresh, external default-output sync.
- Real system volume read, set, mute-to-zero/restore, live sync.
- Real running app discovery via NSWorkspace, with audio-relevance filtering.
- Process Tap Test and Replay Probe (user-triggered, Advanced section).
- Product Real Control for several apps at once (a three-session long-run smoke passed on one Mac),
  indefinite while healthy, with per-app stop and Stop All.
- Advanced manual one-app Live Control with Start/Stop, gain, fade-in/out, 60s timeout.
- Browser/helper row resolution behind the global experimental toggle.
- Validation-first in-memory helper cache.
- Advanced Helper Process Discovery + Find audio helper auto-detect.
- Two-App Readiness diagnostic (Advanced only, 10 s by default with 1/5/30 min options, isolated
  from the main product).
- macOS 14.2 availability guard; deployment target remains macOS 13.0.
- VoiceOver labels/values/hints across the main panel and the Advanced diagnostics.
- GitHub Actions build/test CI (plus a `package` job that uploads an ad-hoc signed zip), a
  draft-only release workflow, an XCTest target, and fake-backed characterization tests for helper
  discovery, helper resolution, live control, the Product Real coordinators and start lane, and
  Two-App Readiness.

---

## What Is Experimental / Fragile

- Browser/helper row resolution: helper PIDs change on tab reload, browser restart, or
  navigation. Cache is validation-first but not persistent.
- Live Control audio quality: fade-in/out ramp is tuned but not regression-tested across
  all macOS versions.
- Two-App Readiness: works in controlled tests (Spotify + YouTube helper, 0 drops).
  It is a diagnostic, separate from Product Real Control.
- Many concurrent Product Real sessions: allowed, but not characterized on real hardware beyond
  three. Known open items: engine self-stops bypass the lifecycle/settle gates, the sleep/quit hard
  teardown blocks the main thread longer with every session, and Stop All is sequential.
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
- **Product Real session count** — the unlimited default
  (`AppConstants.maxConcurrentLiveSessions: Int? = nil`; the product manager is built with
  `maxSessions: nil`) is an **owner decision**. Do not reintroduce a cap without asking the owner;
  the injectable cap exists so tests can prove the mechanism.
- **The queued start lane** (`ProductRealStartCoordinator`: `isStartLaneBusy`, the private in-flight
  tracking, the drain points) — direct-PID starts must not run in parallel with a helper probe, and
  the lane may only drain when it physically frees. Read `docs/DECISIONS.md` first.
- **`ProductRealStartSettleGate` / `ProductRealCoreAudioLifecycleGate`** (P179 / P181) — they keep
  Product Real Core Audio create/destroy spaced and serialized; do not bypass them.

---

## Most Important Files

| File | Why |
|---|---|
| `MacMiniMixer/App/MacMiniMixerApp.swift` | Entry point, all DI wiring |
| `MacMiniMixer/Features/Mixer/MixerViewModel.swift` | Cross-subsystem router and lifecycle/UI orchestration: app list/preview rows, product-vs-Advanced stop router, shared stop display/status, output-change and sleep/termination fan-out, busy gating |
| `MacMiniMixer/Features/Mixer/ProductRealControlCoordinator.swift` | Product Real **facade** — the only Product Real type the view model knows; constructs, wires, forwards |
| `MacMiniMixer/Features/Mixer/ProductRealControlStateStore.swift` | Single source of `ProductRealControlState` + `onWillChange` |
| `MacMiniMixer/Features/Mixer/ProductRealControlState.swift` | Sessions, start-request tokens, pending operations, queued starts; also the stop→start settle gate |
| `MacMiniMixer/Features/Mixer/ProductRealStartCoordinator.swift` | Resolution, start preflight, async start body, queued start lane, diagnostics focus, starvation attribution log |
| `MacMiniMixer/Features/Mixer/ProductRealStopCoordinator.swift` | Per-app stop, Stop All, engine stop callback, app-exit cleanup, hard-teardown state reset |
| `MacMiniMixer/Features/Mixer/ProductRealControlSideEffects.swift` | Narrow seam (side effects + read context) between the Product Real coordinators and the view model |
| `MacMiniMixer/Features/Mixer/AdvancedHelperDiscoveryCoordinator.swift` | Advanced helper scan, probe, auto-detect, and Advanced helper target |
| `MacMiniMixer/Features/Mixer/SystemOutputCoordinator.swift` | System volume/device state and pure volume/device operations |
| `MacMiniMixer/Features/Mixer/AdvancedProcessTapDiagnosticsCoordinator.swift` | Advanced Process Tap Test, Mute Probe, and Replay Probe |
| `MacMiniMixer/Features/Mixer/AdvancedLiveControlCoordinator.swift` | Manual Advanced Live start/stop orchestration |
| `MacMiniMixer/Features/Mixer/TwoAppReadinessCoordinator.swift` | Advanced Two-App Readiness selection, target options, start/stop, snapshot/result state |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLiveSessionManager.swift` | Multi-session engine (`maxSessions: Int?`) + Core Audio lifecycle gate |
| `MacMiniMixer/Services/Audio/ProcessTap/CoreAudioProcessTapLiveController.swift` | Live Control implementation (one controller per session) |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLifecycle.swift` | Core Audio resource management |
| `MacMiniMixer/Services/Audio/ProcessTap/AppAudioTargetResolving.swift` | Helper resolution + cache |
| `MacMiniMixer/Services/Audio/ProcessTap/HelperProcessCandidateDiscovery.swift` | Process tree scanning |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapOutputBufferCopier.swift` | Shared sample copy (unit tested) |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapDiagnosticsAccumulator.swift` | Shared peak/RMS accumulator (unit tested) |
| `MacMiniMixer/Services/Audio/PreviewAudioStateController.swift` | Production `AudioControlling`: in-memory preview slider/mute state, **not** an audio path |
| `MacMiniMixer/Support/AppConstants.swift` | All timing and buffer constants, `maxConcurrentLiveSessions` |
| `MacMiniMixer/Support/AppLogger.swift` | `os.Logger` categories |
| `scripts/package-app.sh` | Release build → ad-hoc signed zip + `.sha256` (used by CI; see `docs/RELEASING.md`) |

---

## Safest Next Technical Steps

1. **Real-hardware N-session characterization** (Release build, e.g. 5–8 Real apps): CPU,
   Drops/Fail/Starv, output-device change, Stop All, quitting one app, sleep/wake — see
   `docs/MANUAL_TEST_CHECKLIST.md` §19. This is the first gate; record only measured numbers.
2. **Then route engine self-stops through the lifecycle/settle gates** (output change / app exit /
   timeout detected inside a session) — audio-adjacent, so small test-first steps plus a hardware
   retest.
3. **Harden helper PID-change handling** and document behavior across browser reloads,
   navigation, and helper restarts.
4. **Add more lifecycle/status characterization tests** before moving more of
   `MixerViewModel` (optionally after a read-only reassessment of its remaining responsibilities).
5. **Release only when the owner asks** — the packaging pipeline is ready (`docs/RELEASING.md`), but
   no tag or version bump without an explicit request.

---

## Manual Test Essentials After Any Code Change

After touching the audio path or MixerViewModel, at minimum verify:

- System volume slider moves real system volume.
- Mute/unmute restores previous volume.
- Output device switching works and refreshes volume.
- Spotify/Music direct Product Real Control starts, gain applies, per-app stop and Stop All work.
- Several rows started quickly queue (pending badge) and then start one after another.
- Product Real stops on output device change; Advanced manual Live Control also stops on its 60s
  timeout.
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
- **No app-count cap in the product (owner decision).** Do not add one back without asking. Every
  Real app costs its own tap + aggregate + IOProc + AudioQueue, so judge changes with Release
  measurements, and do not claim many-session stability without real-hardware evidence.
- **Product starts stay serialized** through the queued start lane, and product create/destroy stays
  behind the settle and lifecycle gates.
- **Advanced tools stay in Advanced.** Process Tap Test, Replay Probe, Two-App Readiness,
  and Helper Discovery must remain in the collapsed Advanced section, not exposed in the
  main mixer UI.
- **Helper mappings are not persisted.** Cache is in-memory, validation-first, and
  invalidated on PID change. Do not add disk persistence without careful design.
- **Real control is opt-in.** The global "Real app control" toggle defaults to OFF.
  No capture starts automatically when an app appears in the list.
- **No release, tag, or `MARKETING_VERSION` bump** unless the owner explicitly asks.

---

## Longer Reference Docs

- [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) — full system architecture with file references
- [`docs/ROADMAP.md`](ROADMAP.md) — prioritized technical roadmap with risk and file notes
- [`docs/DECISIONS.md`](DECISIONS.md) — why key design choices were made
- [`docs/MANUAL_TEST_CHECKLIST.md`](MANUAL_TEST_CHECKLIST.md) — full manual test checklist
- [`docs/HANDOFF.md`](HANDOFF.md) — current state, guardrails, recent commits, next direction
- [`docs/PLAN_MULTI_APP.md`](PLAN_MULTI_APP.md) — multi-app plan and its remaining hardware gates
- [`docs/RELEASING.md`](RELEASING.md) — packaging and draft-release process
