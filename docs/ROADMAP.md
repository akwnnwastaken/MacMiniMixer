# MacMiniMixer Roadmap

Current repository state: the internal **v0.14 Product Real stability checkpoint** is complete —
Product Real App Control (cap=3), the P177–P182 teardown/starvation hardening baseline, Advanced
diagnostics, fake-backed tests, and incremental coordinator extraction are all in place. This is an
unreleased internal checkpoint, **not** a public v0.14 release: `MARKETING_VERSION` is unchanged, no
tag is cut, and the README may still describe the earlier v0.12/one-session state. See
`CHANGELOG.md` (`[v0.14] - Unreleased`) for the checkpoint notes.

This roadmap separates stable foundation, near-term low-risk work, later research, and
explicitly deferred large-scope ideas. It is intentionally conservative: MacMiniMixer is
not yet a finished Windows Volume Mixer replacement.

---

## Completed / Stable Foundation

- System output volume and mute controls.
- Output device listing and switching.
- Application discovery via the current app-listing path.
- Simplified menu bar mixer UI.
- Global Product Real App Control opt-in.
- Direct visible-PID Product Real Control for eligible apps such as Music/Spotify.
- Browser/helper-PID resolution for Safari/YouTube-style rows when global Real App
  Control is enabled and the user interacts with a row.
- Validation-first in-memory helper cache and early-accept fast path.
- Persistent Product Real App Control sessions while healthy.
- One-active-real-session Product limitation.
- Product Real Control lifecycle characterization tests.
- Product Real Control state/model helper extraction.
- Advanced Helper Process Discovery, manual helper Probe, Find audio helper, and
  Advanced helper target selection.
- Advanced Process Tap Test, Mute Probe, Replay Probe, manual Advanced Live Control,
  and Two-App Readiness.
- XCTest target with fake-backed coverage for helper discovery, helper resolver/cache,
  permission messaging, live session management, Product/Advanced live behavior,
  coordinators, Two-App Readiness, diagnostics accumulation, and output buffer copying.
- GitHub Actions build/test CI.
- MIT License.
- Shared `ProcessTapDiagnosticsAccumulator`.
- Shared `ProcessTapOutputBufferCopier`.
- Extracted coordinators:
  - `AdvancedHelperDiscoveryCoordinator`
  - `SystemOutputCoordinator`
  - `AdvancedProcessTapDiagnosticsCoordinator`
  - `AdvancedLiveControlCoordinator`
  - `TwoAppReadinessCoordinator`
  - `ProductRealControlCoordinator` (owns the Product Real **start** path — see below; stop/lifecycle
    still in `MixerViewModel`)
- Extracted `MixerViewModel` helpers: `RealControlBannerPresenter`, `MixerVisibleAppsFilter`,
  `MixerStatusMessageController`.
- `CHANGELOG.md` with milestone history.
- Persistent read-only output-volume indicator for devices without a writable volume API.
- Accessibility labels/values/hints for app rows, system output controls, and output-device
  selection.
- Consolidated output-device-change teardown in `MixerViewModel`
  (`stopActiveAudioWorkForOutputDeviceChange`).
- System sleep/wake lifecycle handling: app-lifetime observers in `MixerViewModel`
  synchronously tear down all active/pending Process Tap work on sleep (typed `.systemSleep`
  stop reason) and do refresh-only reconciliation on wake, with no automatic session restart.

---

## Current Architecture and Hardening Status

- `MixerViewModel` remains the central traffic controller for app list/mock row state,
  cross-feature coordination, lifecycle cleanup, and status messages.
- Product Real Control is now **split across a coordinator and the view model**:
  - `ProductRealControlCoordinator` owns `ProductRealControlState`, the app-audio resolution
    task/handling, stale-start cleanup, and the async Product Real **start** path (preflight +
    resolved/async start body). It talks to the view model only through the
    `ProductRealControlSideEffects` / `ProductRealControlContext` seam.
  - `MixerViewModel` still owns the row `toggleExperimentalControl` entry point,
    `stopExperimentalControl` / `stopProductLiveSessions` (Stop All),
    `handleProductLiveControlStopped`, and lifecycle / sleep / wake / termination /
    output-device-change teardown. Moving the **stop/lifecycle** path is future work.
  - Rationale for the staged extraction is in `docs/DECISIONS.md`.
- Product sessions use an indefinite timeout policy while healthy. Manual Advanced Live
  and diagnostic/readiness paths remain limited/short-lived.
- Helper mappings are validation-first, in-memory only, and not persisted across
  launches.
- No background helper scanning runs just because an app appears.
- Helper PID/process names stay hidden from the main mixer UI.
- Process Tap features are guarded for macOS 14.2+ while deployment target remains
  macOS 13.0.
- System sleep tears down all active/pending Product, Advanced manual, Two-App Readiness, and
  diagnostic work (no resurrection of stale starts); system wake only refreshes
  device/volume/app state and never auto-restarts sessions. Rationale in `docs/DECISIONS.md`.
- Safety constraints remain:
  - Public APIs only.
  - No HAL driver.
  - No persistent virtual audio device.
  - No private APIs.
  - No third-party dependencies.
  - No disk audio saving.
  - Product sessions remain one active real session at a time for now.

---

## Next Recommended Low-Risk Work

### Extract Product Real Control coordinator — start path done; stop/lifecycle future

**Priority**: High | **Risk**: Medium | **Status**: Start path extracted (staged); stop/lifecycle remaining

The initial reassessment deferred the coordinator (the cluster was the central arbiter with ~142
references and four shared `@Published` properties). That was later superseded: the **start** path
was extracted into `ProductRealControlCoordinator` in small, independently-tested steps
(seam → pure decision helpers → state ownership → stale cleanup → resolution slice → async start
body). The coordinator owns `ProductRealControlState`, resolution, stale-start cleanup, and the
async start path, talking to the view model through the `ProductRealControlSideEffects` /
`ProductRealControlContext` seam. Each step stayed behind the unchanged `MixerViewModelLiveControlTests`
plus new coordinator tests; the full suite is green (371 passed / 0 failed / 0 skipped).

**Remaining (future work)**: move the Product Real **stop / toggle / lifecycle** path out of
`MixerViewModel` — `toggleExperimentalControl`, `stopExperimentalControl`,
`stopProductLiveSessions` (Stop All), `handleProductLiveControlStopped`, and the sleep / wake /
termination / output-device-change teardown. Full staged rationale in `docs/DECISIONS.md`.

---

### Non-writable output-volume UX — done (follow-up optional)

**Priority**: High | **Risk**: Low | **Status**: Implemented

`SystemOutputCoordinator` now tracks per-device writability
(`isSystemOutputVolumeWritable`) and `MixerPanelView` shows a compact persistent
"Read-only" badge plus tooltip when the selected device rejects volume writes. Writability
resets when the selected device changes.

**Optional follow-up**: probe writability proactively on device refresh (instead of only
after a rejected write) so the badge appears before the user first drags the slider.

---

### Accessibility labels — done

**Priority**: Medium | **Risk**: Low | **Status**: Implemented

Explicit labels/values/hints added for app rows (volume slider, mute, Real/Resolving
state), the system output slider and mute button, and output-device selection rows.

**Optional follow-up**: SwiftUI accessibility/snapshot tests once a view-test harness
exists (see "UI-layer test coverage" below).

---

### System Settings permission affordance — done (follow-up optional)

**Priority**: Medium | **Risk**: Low | **Status**: Implemented

A compact "Open System Settings" button now appears in the Advanced Process Tap result line
when the outcome is `.permissionDenied`, opening the Privacy & Security pane via
`NSWorkspace`. It is deliberately not shown for `.missingUsageDescription` (a build-config
problem, not a user-fixable setting). The settings URL targets the Privacy & Security root
rather than a version-specific anchor for robustness across macOS versions.

**Done**: the affordance is also surfaced on the main transient status banner.
`MixerStatusMessage` now carries an optional `Action`; permission-denied start failures
(both the Advanced manual path and the Real App Control toggle path) attach an
`openSystemAudioRecordingSettings` action rendered as an inline "Open Settings" button.

---

### CHANGELOG and release-readiness cleanup — partially done

**Priority**: Low | **Risk**: Low | **Status**: `CHANGELOG.md` added

`CHANGELOG.md` now exists with milestone history and an `[Unreleased]` section. Remaining
work: keep it synchronized with each change and prepare conservative release notes without
implying production-grade multi-app mixer support.

**Likely files**: `CHANGELOG.md`, `README.md`, `docs/*`.

---

### Continue `MixerViewModel` cleanup

**Priority**: Medium | **Risk**: Low

`MixerViewModel` is still the largest file (~1.1k lines). The output-device-change teardown
was consolidated into `stopActiveAudioWorkForOutputDeviceChange`; continue collapsing other
repeated cross-feature cleanup patterns (app-refresh handling, termination teardown) into
named helpers before deciding on any further coordinator extraction. This is distinct from
the Product Real Control coordinator decision above — it is pure local simplification with
no behavior change, verified by the existing characterization tests.

**Likely files**: `MixerViewModel.swift`.

**Note**: The duplicated `beginSession` call in `startExperimentalControl` is intentional
(early optimistic set + post-`await` re-assertion) and is now documented inline. Do not
"simplify" it away without re-checking the suspension-point behavior.

---

### Diagnostic tooling inventory and sunset decision — done

**Priority**: Medium | **Risk**: Low | **Status**: Classified; retain all

Each Advanced tool has been classified in `docs/DECISIONS.md`. **Outcome: retain everything
for now** — the maintainer's goal is a full Windows-style mixer (simultaneous per-app
control for every listed app), so every diagnostic is on the critical path to that goal,
either as evidence (Two-App Readiness) or as a building-block diagnostic. Sunset triggers
are recorded: after multi-app ships and is validated, Replay Probe and Mute Probe are the
first removal candidates, and the manual Helper Discovery UI can be debug-gated (its engine
stays, since the product depends on it).

---

### UI-layer test coverage

**Priority**: Low | **Risk**: Low

All 164 tests target view models, coordinators, and services. SwiftUI views
(`MixerPanelView`, `ProcessTapTestView`, etc.) have no automated coverage. Investigate a
lightweight accessibility/snapshot harness so view regressions (including the new
accessibility labels) are caught.

**Likely files**: new test target/helpers, `MacMiniMixerTests/*`.

---

## Later Research / Experimental Work

### Helper PID-change hardening

**Priority**: High | **Risk**: Medium

Helper PIDs can change after browser navigation, tab close/reopen, helper restart, or app
updates. Current cache validation and failure cleanup are conservative, but active-session
recovery is still manual/user-triggered.

**Research questions**:
- Should a stopped helper session offer a fresh resolution retry?
- Can PID changes be detected without background probing?
- How should the UI explain browser/helper instability without exposing helper names?

---

### Two-App Readiness repeatability and latency characterization

**Priority**: Medium | **Risk**: Medium

Continue measuring callbacks, peak/RMS, queued buffers, drops, failures, cleanup behavior,
and latency across more eligible app combinations and repeated runs.

**Goal**: Use this only as Advanced diagnostic evidence, not as a shortcut to main UI
multi-app control.

---

### Experimental per-app volume boost

**Priority**: Low | **Risk**: High | **Status**: Later research / experimental

Product Real App Control may eventually allow an eligible selected app to be amplified
above its original audio level, with a research target of up to 200%.

**User value**: Mute, reduce, or experimentally boost applications that provide no
built-in volume controls.

Constraints:
- Off by default.
- Separate explicit opt-in from normal 0-100% control.
- Public Process Tap/Core Audio APIs only.
- No HAL driver, persistent virtual audio device, private APIs, third-party dependencies,
  or disk audio saving.
- Preserve the one-active-real-session limitation initially.
- Affect only the selected application.
- Do not boost system output volume.
- Do not affect unrelated applications.
- Test direct visible-PID and browser/helper-PID paths separately.
- Warn users before enabling gain above 100%, especially with headphones.

Before implementation, require a read-only assessment of current gain mapping, headroom,
clipping, distortion, hard clipping versus limiter or soft-clipping options, CPU, latency,
long-session resources, repeated gain updates, sleep/wake behavior, output changes,
app/helper exit cleanup, and Core Audio failure recovery.

Treat 200% as a research target, not a promise of clean output. Start later with
characterization tests and a narrowly scoped experimental mode.

---

### Sleep/wake and long-running resource characterization

**Priority**: Medium | **Risk**: Medium | **Status**: Explicit lifecycle handling done;
deeper characterization still open

**Done**: System sleep/wake now has explicit, deliberate lifecycle handling — sleep tears
down all active/pending Process Tap work (typed `.systemSleep` reason); wake is refresh-only
(output devices, system volume/mute, visible app list) with **no** automatic session restart.
The rationale (conservative; avoids stale tap, stale helper PID, output-device-change, and
restart-loop risks) is recorded in `docs/DECISIONS.md`. A basic real-hardware sleep/wake
smoke test passed, and the fake-backed suite covers the sleep teardown and wake refresh-only
behavior.

**Still open**: automatic post-wake restart/recovery research (deferred — see DECISIONS);
longer-duration and repeated sleep/wake characterization; varied output-device and
helper-PID-replacement combinations; behavior under N > 2 sessions; and the broader long-idle
/ app-exit / helper-exit / Core Audio failure resource characterization. Short-run Release CPU
for one and two sessions has now been profiled (see below), but sustained (hours-long)
CPU/latency/resource behavior is still unmeasured.

**v0.14 stability evidence (next gate)**: a three-session sleep/wake smoke is the next evidence
gate (procedure in `docs/MANUAL_TEST_CHECKLIST.md` §14.6). The existing sleep/wake code is
collection-based and is expected to be N-safe, but cap=3 needs one real-hardware confirmation.
Passing it does **not** enable N > 3 — it only strengthens cap=3 stability evidence; alongside a
30–60 min three-session long-run and callback-jitter/output-starvation measurement, these form
the v0.14 "stability polish" track.

**Three-session jitter/starvation short smoke — passed (one real Mac).** The Phase 6c
diagnostic-only counters (callback jitter / output starvation) are now visible in the live
Advanced diagnostics card ("Gap … · Late … · Starv …") and at the start of the stop-result
detail. A ~6–7 min three-session smoke (Music + Spotify + a helper) observed `Starv 0`,
`Drops 0`, `Fail 0`, `Late 1`, `maxGap` ~70–133 ms, with **no audible glitch or audio loss** —
treated as PASS. A single late callback / a 70–133 ms max gap is not on its own a failure (a
brief spike, panel open, around stop, or a helper input pause can produce it); the gate is "no
audible glitch and clean stop". Panel-open Advanced diagnostics is a known CPU-heavy view
(panel closed ≈ 25%, panel open / Advanced closed ≈ 39%, panel open / Advanced open ≈ 55% in
Release) — a future diagnostics/UI publication-throttle candidate, **not** a release blocker and
not an audio-path red flag. A 30–60 min three-session long-run remains a future gate; N > 3
stays deferred.

---

### Product Real teardown/starvation hardening (P177–P182) — done (v0.14 stability)

**Priority**: High | **Risk**: Low | **Status**: Landed in commit `88bbed5`; real-hardware
retest passed; **30–60 min three-session long-run smoke PASS (with caveat)** — normal-use v0.14
gate met

A focused hardening pass on the Product Real teardown and starvation-diagnostics path, driven
by real-hardware feedback. The sequence:

- **P177**: process-tap destroy retry with fault reporting (a leaked `.mutedWhenTapped` tap can
  otherwise leave apps muted inside coreaudiod).
- **P178**: dispose the output queue *after* IOProc stop/destroy to avoid self-inflicted Drops
  during teardown.
- **P179**: Product Real stop→start settle gate (a short window before a new start so a fresh
  tap/aggregate is not created while coreaudiod is still releasing the previous one).
- **P180**: gate output-starvation counting on observed real input, with a neutral audio status,
  so a silent/no-audio app does not show alarming Starv.
- **P181**: serialize all Product Real Core Audio lifecycle create/destroy operations so private
  aggregate/tap churn on the shared route no longer overlaps.
- **P182**: output-queue startup-warmup gate so a fresh queue establishing cadence (e.g. after a
  per-app Real restart) does not report transient Starv.

**Real-hardware retest summary** (one real Mac, user's repeated manual retest):
- The previously failing combination-change case improved: YouTube + Spotify clean → stop
  Spotify → start Music while YouTube stays active → YouTube + Music clean.
- Repeated per-app Music stop/start after P182 did not reproduce Starv/clicks.
- Three-session testing was clean in repeated manual retest.
- No `sudo killall coreaudiod` was needed in the final retest.

**Scope guardrails**: cap remains **3** (`maxConcurrentLiveSessions = 3`); no N > 3 support; the
unsafe default-output observer was **not** reintroduced. Decision rationale is in
`docs/DECISIONS.md`; the manual smoke procedure is in `docs/MANUAL_TEST_CHECKLIST.md` §17.

**Long-run smoke result — PASS (with caveat)** (one real Mac, checklist §16.5): three Product
Real sessions ran cleanly during normal use; ordinary per-app stop/start during use was clean;
`Drops`/`Fail`/`Starv` stayed **0** during normal usage; CPU settled roughly in the **20–35%**
range depending on panel / Activity Monitor state; **no `sudo killall coreaudiod`** was needed;
output remained usable throughout. This closes the main remaining normal-use stability gate for
this checkpoint.

**Caveat (not a v0.14 blocker)**: *extremely* rapid repeated Real on/off spam eventually produced
severe crackle and `Starv`. The intended product flow is Real Control staying **enabled during
use**, not rapid manual toggling, so this is out of the normal-use envelope the gate covers. A
UI/view-model **pending-operation guard** now addresses this (see "Rapid Real-toggle protection"
below and `docs/DECISIONS.md`); real-device stress testing remains useful to confirm its effect.

---

### Rapid Real-toggle protection — implemented (UI/view-model guard)

**Priority**: Medium | **Risk**: Low | **Status**: Implemented (Prompt 194); real-device stress
testing still useful

The long-run smoke found that *extremely* rapid repeated Real on/off toggling can eventually
overwhelm the settle/lifecycle gates and produce crackle/`Starv` — a stress case outside the
intended flow (Real stays enabled during use). A **per-app pending-operation guard** now handles
this at the UI/view-model level: `ProductRealControlState` tracks which rows have a start/stop
transition in flight (`pendingOperationAppIDs`), `MixerViewModel` ignores toggle and slider
auto-start attempts for a row while its operation is pending (clearing the flag in each terminal
handler and on global teardown), and the row shows a non-interactive "working" badge. It is
layered **above** the settle (P179) and lifecycle-serialization (P181) gates so a burst of clicks
cannot queue create/destroy churn faster than coreaudiod settles. It does **not** change cap=3,
the audio callback, or the teardown gates, and it keeps N > 3 deferred. Rationale in
`docs/DECISIONS.md`; manual smoke in `docs/MANUAL_TEST_CHECKLIST.md` §18.

**Still useful**: real-device stress testing (aggressive rapid toggling on one and on 2–3
concurrent rows) to confirm the guard removes the crackle/`Starv` in practice — its real-world
effect is not yet hardware-verified. A deliberate consequence is that a toggle can no longer cancel
an in-flight start mid-flight (the start completes first).

---

### Two-app Release CPU/resource profiling — done (cap=2 gate passed)

**Priority**: High | **Risk**: Low | **Status**: Measured on one real Mac; cap=2 performance
gate considered passed for current scope

Release profiling (Instruments Time Profiler + Activity Monitor, one real Mac, M4 Pro)
indicates the two-session Product Real Control path is healthy for the current `maxSessions = 2`
scope:

- Idle ≈ 0% CPU (no idle leak; audio/diagnostics do not run with no active session).
- One direct session ≈ 7.1% CPU; two direct sessions ≈ 12.2%; direct + helper ≈ 13.6%.
- Two-session scales roughly 1.7× the single-session cost — below 2×, no scaling red flag.
- Memory ~54–58 MB and thread counts (13–16) were stable across these runs; CPU returns to
  ~0% within ~6–7 s after stop; no drops/failures/cleanup warnings; thermal nominal.
- `%100` Activity Monitor CPU ≈ one full core, so ~12–14% is a small fraction of one core on
  this machine — not 12–14% of the whole computer.

Release profiling also indicates the **relative** cost centre is the Main Thread /
SwiftUI / AppKit (diagnostics publication + UI) rather than the audio callback path
(`ProcessTapDiagnosticsAccumulator.observe`, `ProcessTapOutputBufferCopier`, AudioQueue),
which measured low. Earlier Debug (`-Onone`) CPU figures (~50–80%) were **not**
representative; performance decisions must use Release measurements.

**Caveat**: measured on a single Mac, short runs (1–3 min). This is the cap=2 gate, not a
proof for all hardware, longer runs, or N > 2.

---

### Three-app cap (cap=3) enabled — done (real-hardware smoke passed)

**Priority**: High | **Risk**: Low | **Status**: `maxConcurrentLiveSessions = 3`; three-session
smoke passed on one real Mac

Cap 3 is enabled for Product Real Control — it now supports up to three apps controlled live at
the same time. A three-session smoke passed on one real Mac (M4 Pro, Release; two direct apps +
one helper, panel mostly closed):

- Measured CPU was approximately 19% in Release profile — within the expected ~17–25% PASS band
  for three sessions and a reasonable scale-up from cap=2; memory ≈ 59 MB, ~16 threads, thermal
  nominal. Main/SwiftUI/AppKit remained the relative cost centre; the audio path measured low
  (not a red flag).
- The banner correctly summarised three apps (first two names + "+1 more", "Stop All").
- Per-app stop left the other two sessions running with no audio disruption; Stop All, repeated
  start/stop, and an output-device change all torn down cleanly — no drops/failures/cleanup
  warnings, CPU returning to ~0%. CI is green.

**Caveat**: one real Mac, short smoke runs. Not a proof for all hardware, hours-long runs, or
N > 3. Raising the cap beyond 3 (`N > 3`) remains deferred (see below and `docs/DECISIONS.md`).

---

### Release packaging and distribution

**Priority**: Medium | **Risk**: Low-Medium

Investigate a direct-distribution package such as a notarized `.zip` or `.dmg`. Keep this
separate from runtime audio behavior.

---

## North-Star Goal: Full Windows-style Multi-App Mixer

The maintainer's end goal is a true Windows Volume Mixer experience: **simultaneous,
independent per-app volume control for every app shown in the audio list**, changed live and
at the same time. This is the product's north star, not a deferred curiosity.

The work is still approached **incrementally** for sound engineering reasons (see
`docs/DECISIONS.md`): one validated active session today, two short-lived sessions measured
via Two-App Readiness, then more — only as evidence shows simultaneous sessions stay stable
on CPU, latency, and buffer timing. The diagnostic tooling is retained precisely because it
is the evidence base and the development instrument for this goal.

**Likely milestones toward it** (each gated by characterization evidence):
1. Sustained two-app live control (promote Two-App Readiness from diagnostic to product).
2. N-app session management in `ProcessTapLiveSessionManager` (raise `maxSessions`).
3. Per-row real control state in the main UI (remove the one-active-session limit).
4. Resource/latency characterization under many simultaneous sessions.

Three-app control (`maxConcurrentLiveSessions = 3`) is implemented and its Release CPU/resource
gate is considered passed for current scope (see "Three-app cap (cap=3) enabled" above).
Raising the cap beyond 3 (`N > 3`) remains **deferred to a dedicated plan** — CPU is no longer a
hard blocker, but N > 3 is not a config bump: it needs resolver serialization / multi-helper UX,
N-session Core Audio resource-scale evidence, larger-N UI/banner behaviour, sustained long-run
characterization, the orphan-tap repro, and AudioQueue underrun/jitter measurement (see
`PLAN_MULTI_APP.md` Phase 5 and `docs/DECISIONS.md`).

The detailed, phased implementation plan lives in [`PLAN_MULTI_APP.md`](PLAN_MULTI_APP.md).
The first concrete step is **Phase 0: sustained characterization** of two simultaneous
sessions.

---

## Explicitly Deferred Large-Scope Work

These are not immediate tasks, and remain deferred even though the multi-app goal above is
active — they are heavier architectural bets to reach for only if the incremental
public-API path proves insufficient.

- Centralized mixer/renderer architecture.
- HAL driver, plug-in, or system extension.
- Persistent virtual audio device.
- Large Core Audio redesign.
- Installer/uninstaller work required by any future persistent system component.

The current direction remains: preserve the public-API Process Tap approach, grow Product
control from one-active-session toward multi-app **incrementally as evidence allows**,
validate behavior with tests/manual diagnostics, and avoid broad audio-path rewrites unless
evidence shows they are necessary.
