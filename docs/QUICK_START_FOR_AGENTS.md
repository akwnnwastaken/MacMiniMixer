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
- Live audio now plays through a **direct aggregate output engine** (default; one IOProc reads the
  tap and writes the output device on one clock, no `AudioQueue`), which removed the random crackle.
  The old `AudioQueue` path is a legacy fallback (override `MacMiniMixerLiveOutputMode=audioQueue`,
  output device with input streams, or a failed direct setup), scheduled for removal. An app's audio
  processes are tapped together and attributed by resource coalition.
- Real-hardware **resource** evidence (CPU, teardown timing) covers **up to three** concurrent
  sessions only. The direct engine was additionally listened to with up to six sessions at 48 kHz and
  44.1 kHz and on a second output device (no crackle); beyond that, sessions have only been exercised
  by fake-backed tests.
- Real app control is always on (owner decision; no toggle in the panel — `MacMiniMixerApp` enables it
  at launch). App rows are preview/UI-state until the user interacts with an eligible row.
- The Advanced section is developer-only (owner decision): it is not built unless
  `defaults write com.example.MacMiniMixer MacMiniMixerDeveloperMode -bool YES` was run (relaunch).
  `Show all apps` and `Quit` live in the panel header's `⋯` menu.

---

## What Works Reliably Now

- Menu bar app, mixer panel, liquid/glass UI.
- Real output device list, switching, live refresh, external default-output sync.
- Real system volume read, set, mute-to-zero/restore, live sync.
- Real running app discovery via NSWorkspace, with audio-relevance filtering.
- Process Tap Test and Replay Probe (user-triggered, Advanced section, developer mode only).
- Product Real Control for several apps at once (a three-session long-run smoke passed on one Mac),
  indefinite while healthy, with per-app stop and Stop All.
- Advanced manual one-app Live Control with Start/Stop, gain, fade-in/out, 60s timeout.
- Browser/helper row resolution after explicit row interaction.
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
  all macOS versions. The direct engine is crackle-free on the owner's Mac (built-in speakers at 48
  and 44.1 kHz, a second output device at 48 kHz) but not verified on other devices, sample rates or
  macOS versions; devices with input streams still use the legacy `AudioQueue` path, and the
  `path=converting` resampler branch has not been seen on real hardware (the HAL passes through).
- Per-app process attribution: relies on an undocumented `proc_pidinfo` coalition flavor with a
  bundle-id fallback; rows that share one coalition contend for the same helpers.
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
- **The direct output renderer and its IOProc** (`ProcessTapDirectOutputRenderer` in
  `CoreAudioProcessTapLiveController.swift`, `ProcessTapDirectOutputCopier` /
  `ProcessTapDirectOutputResampler` in `ProcessTapOutputBufferCopier.swift`) — the default live audio
  path (one aggregate IOProc: tap in, gained audio out, one clock). Real-time rules: no allocation,
  blocking lock, logging or array growth in the callback; control reaches it through a try-lock only.
  Any change risks audible regression (crackle). Manual listening tests on real hardware required
  (`docs/MANUAL_TEST_CHECKLIST.md` §21). Never change the user's output-device sample rate
  automatically (owner decision). The legacy `ProcessTapLiveOutputQueue` (now in
  `ProcessTapLegacyAudioQueueOutput.swift`) and `ProcessTapReplayOutputQueue` are frozen: the live
  queue is a fallback scheduled for removal, so don't extend or "unify" it (see `docs/DECISIONS.md`,
  "Why live output renders straight to the device through one aggregate IOProc").
- **`AppAudioProcessMatcher` attribution** — resource-coalition matching with a bundle-id fallback.
  It relies on an undocumented `proc_pidinfo` flavor; keep the fallback, and don't add further
  private or undocumented calls.
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
| `MacMiniMixer/Services/Audio/ProcessTap/CoreAudioProcessTapLiveController.swift` | Live Control implementation (one controller per session): direct aggregate output (default) + fallback to the legacy path, direct renderer |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLegacyAudioQueueOutput.swift` | **Legacy** `AudioQueue` live output; fallback only, scheduled for removal |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLiveControlling.swift` | `ProcessTapLiveOutputMode` and `ProcessTapDirectResampleMode` (the two `defaults write` switches) |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapLifecycle.swift` | Core Audio resource management |
| `MacMiniMixer/Services/Audio/ProcessTap/AppAudioTargetResolving.swift` | Helper resolution + cache; `AppAudioProcessMatcher` (HAL process list → app, coalition / bundle fallback) |
| `MacMiniMixer/Services/Processes/SystemProcessLister.swift` | Process list/ancestry, incl. `resourceCoalitionID` (`proc_pidinfo`, undocumented flavor) |
| `MacMiniMixer/Services/Audio/ProcessTap/HelperProcessCandidateDiscovery.swift` | Process tree scanning |
| `MacMiniMixer/Services/Audio/ProcessTap/ProcessTapOutputBufferCopier.swift` | Shared sample copy; direct-output copier, FIFO and sample-rate resampler (unit tested) |
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
- After touching the live audio path: the direct engine check in `docs/MANUAL_TEST_CHECKLIST.md` §21
  (Advanced card, developer mode — `Queued 0`, log `output=direct`, `resample report … path=`, no audible crackle).
- Product Real stops on output device change; Advanced manual Live Control also stops on its 60s
  timeout.
- App quit during live control stops session cleanly (check Console for cleanup logs).
- Two-App Readiness runs 10s with zero drops for Spotify + Music.
- The full XCTest suite passes.

Full checklist: `docs/MANUAL_TEST_CHECKLIST.md`

---

## Safety Rules

- **No private APIs.** Only public Core Audio, AudioToolbox, AppKit APIs. One disclosed grey area:
  `proc_pidinfo` is called with the undocumented `PROC_PIDCOALITIONINFO` flavor for per-app
  attribution (read-only, falls back to bundle-id rules); do not add anything similar.
- **No HAL driver.** No kernel extension, no user-space HAL plug-in, no system extension.
- **No persistent virtual audio device.** The private aggregate device is temporary and
  destroyed in cleanup. Nothing survives an app quit or crash.
- **No audio saving.** No audio is written to disk anywhere in the codebase.
- **No app-count cap in the product (owner decision).** Do not add one back without asking. Every
  Real app costs its own tap + aggregate + IOProc (+ an AudioQueue on the legacy fallback path), so
  judge changes with Release measurements, and do not claim many-session stability without
  real-hardware evidence.
- **Never change the user's output-device sample rate automatically** (owner decision); the direct
  engine converts or passes through inside the IOProc instead.
- **Never block on CI.** GitHub Actions can be out of macOS minutes (jobs fail within seconds with no
  runner). Re-run an infra failure at most once, then report CI as unavailable and hand over the local
  `xcodebuild test` command; delegated agents never push, trigger or poll CI. Docs-only changes skip
  CI anyway.
- **Product starts stay serialized** through the queued start lane, and product create/destroy stays
  behind the settle and lifecycle gates.
- **Advanced tools stay in Advanced.** Process Tap Test, Replay Probe, Two-App Readiness,
  and Helper Discovery must remain in the collapsed, developer-mode-only Advanced section, not exposed in the
  main mixer UI.
- **Helper mappings are not persisted.** Cache is in-memory, validation-first, and
  invalidated on PID change. Do not add disk persistence without careful design.
- **Real control starts only on interaction.** It is always on (no toggle, owner decision), but no
  capture starts automatically when an app appears in the list; keep it that way.
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
- `.claude/skills/delegate-subagents/` (`SKILL.md`, `project-brief.md`) and `.claude/agents/` — how to
  delegate work to cost-tiered subagents (read the brief first; it holds the cloud-session
  constraints and guardrails)
