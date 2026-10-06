# MacMiniMixer Roadmap

Current repository state: **v0.14 is released (2026-10-06)**. It contains the **Product Real
stability checkpoint** (the P177–P182 teardown/starvation hardening baseline, Advanced diagnostics,
fake-backed tests, and the Product Real facade/store/start/stop split) and the work on top of it:
**Product Real App Control has no app-count limit** (owner decision), starts are serialized
through a **queued start lane**, live diagnostics are published only for the focused session while
the Advanced section is visible, the system-output "Read-only" badge is probed proactively,
accessibility coverage is complete, and release packaging (ad-hoc zip, CI artifact, draft-release
workflow) exists. Since the last docs refresh (`222b652`) an app's audio processes are tapped
together and attributed by resource coalition, and live output now goes through a **direct aggregate
output engine** (one IOProc on one clock, no `AudioQueue`) that removed the random crackle on the
owner's Mac (48 kHz and 44.1 kHz, up to six sessions, a second output device); the old `AudioQueue`
path is a legacy fallback scheduled for removal. What is **not** done is real-hardware resource
evidence (CPU, memory, Stop All, sleep) beyond three concurrent sessions, and wider device coverage
of the direct engine.
`MARKETING_VERSION` is `0.14` (ad-hoc signed, not notarized, published as a GitHub pre-release). See
`CHANGELOG.md` (`[v0.14] - 2026-10-06`).

This roadmap separates stable foundation, near-term low-risk work, later research, and
explicitly deferred large-scope ideas. It is intentionally conservative: MacMiniMixer is
not yet a finished Windows Volume Mixer replacement.

---

## Completed / Stable Foundation

- System output volume and mute controls.
- Output device listing and switching.
- Application discovery via the current app-listing path.
- Simplified menu bar mixer UI: header with a `⋯` menu (`Show all apps`, `Quit`), compact one-line
  active banner, System Output, Applications list; Advanced is built only in developer mode
  (`MacMiniMixerDeveloperMode`).
- Product Real App Control always on (owner decision; no toggle — a row becomes Real only after the
  user interacts with it).
- Direct visible-PID Product Real Control for eligible apps such as Music/Spotify.
- Browser/helper-PID resolution for Safari/YouTube-style rows after the user
  interacts with a row.
- Validation-first in-memory helper cache and early-accept fast path.
- Persistent Product Real App Control sessions while healthy.
- Product Real App Control for any number of apps at once (no app-count limit, owner decision),
  with a queued start lane, per-app stop / Stop All, and per-app exit handling. Real-hardware
  resource evidence covers up to three sessions.
- Direct aggregate output engine as the default live output (one aggregate IOProc: output device +
  tap, on one clock; in-engine sample-rate conversion with passthrough detection; legacy `AudioQueue`
  fallback; two `defaults write` switches). Crackle-free on the owner's Mac at 48 kHz and 44.1 kHz with
  up to six sessions, and on a second output device at 48 kHz.
- Per-app audio process discovery through the HAL process-object list, one multi-process tap per app,
  and attribution by resource coalition (Safari vs Safari web apps, Chrome vs PWAs/Canary) with a
  bundle-id fallback.
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
  - `ProductRealControlCoordinator` (the Product Real **thin facade**, ~180 lines, no start/stop
    implementation — composes three internal sub-objects: `ProductRealControlStateStore`,
    `ProductRealStartCoordinator`, `ProductRealStopCoordinator`; the cross-subsystem router, lifecycle
    entry points, and multi-subsystem fan-out intentionally remain in `MixerViewModel`)
  - `ProductRealControlStateStore` (single source of `ProductRealControlState` + `onWillChange`
    notification storage, shared by reference among the facade and both sub-coordinators)
  - `ProductRealStartCoordinator` (product-only start + resolution path behind the facade — app-audio
    resolution + task ownership/`deinit`, start preflight, both `startExperimentalControl` overloads,
    async start body, cached-helper retry, stale-start rejection/cleanup, settle-gate start ordering,
    and since the `[Unreleased]` work the queued start lane, `requestAutomaticStart`, live-diagnostics
    focus, and per-session starvation attribution logging)
  - `ProductRealStopCoordinator` (product-only stop path behind the facade — per-app stop, Stop All,
    stop callback, app-exit cleanup, hard-teardown reset, active-name helper)
- Extracted `MixerViewModel` helpers: `RealControlBannerPresenter`, `MixerVisibleAppsFilter`,
  `MixerStatusMessageController`.
- `CHANGELOG.md` with milestone history.
- Persistent read-only output-volume indicator for devices without a writable volume API, probed
  proactively at launch / device change / successful selection.
- Accessibility labels/values/hints across the whole menu bar UI (app rows, system output, device
  list, panel toggles/disclosure/status banner, and every Advanced diagnostic view).
- Release packaging scaffolding: `scripts/package-app.sh` (ad-hoc signed zip + sha256), the `Build`
  workflow's `package` artifact, and a tag-triggered draft-release workflow (`docs/RELEASING.md`).
- `PreviewAudioStateController` (renamed from `MockAudioController`); unused production mocks removed.
- Consolidated output-device-change teardown in `MixerViewModel`
  (`stopActiveAudioWorkForOutputDeviceChange`).
- System sleep/wake lifecycle handling: app-lifetime observers in `MixerViewModel`
  synchronously tear down all active/pending Process Tap work on sleep (typed `.systemSleep`
  stop reason) and do refresh-only reconciliation on wake, with no automatic session restart.

---

## Current Architecture and Hardening Status

- `MixerViewModel` remains the central traffic controller for app list/preview row state,
  cross-feature coordination, lifecycle cleanup, and status messages.
- Product Real Control is now **split across a coordinator (a facade with internal sub-objects) and
  the view model**:
  - `ProductRealControlCoordinator` is the **thin facade** `MixerViewModel` knows (~180 lines, no
    start/stop implementation; later commits added two forwards for the start lane and a defaulted
    `maxConcurrentSessions` initializer parameter for the cap removal, so the view model's call site
    is unchanged). It owns one shared
    state store and composes three internal sub-objects, constructs + wires them, and forwards:
    - `ProductRealControlStateStore` — the **single** production source of `ProductRealControlState`
      and `onWillChange` storage (one instance, shared by reference; a write notifies exactly once
      before applying, a read never notifies).
    - `ProductRealStartCoordinator` — the full Product Real **start + resolution** path (app-audio
      resolution + `appAudioResolutionTask` ownership/`deinit`, `productSessionStartBlockReason`
      preflight, both `startExperimentalControl` overloads, the async start body, diagnostics-callback
      acceptance, cached-helper retry, stale-start rejection/cleanup, settle-gate start ordering),
      plus the queued start lane, `requestAutomaticStart`, and the live-diagnostics focus.
    - `ProductRealStopCoordinator` — the full Product Real **stop** path: per-app stop
      (`stopExperimentalControl`), Stop All core (`stopProductLiveSessions`), the engine stop callback
      (`handleProductLiveControlStopped`), the app-exit slice (`stopRealControlForExitedTargetApps`),
      the hard-teardown state reset (`tearDownProductStateForHardStop`), and the shared active-name
      helper.
    - The three cross-edges (start `onStopped` → stop callback; start active-name refresh → stop
      helper; stop app-exit → resolution cancel) are **narrow `[weak self]` closures** wired by the
      facade — no direct Start↔Stop sibling ownership, no retain cycle.
    - The sub-coordinators talk to the view model only through the `ProductRealControlSideEffects` /
      `ProductRealControlContext` seam (held weakly).
  - `MixerViewModel` remains the **cross-subsystem router and lifecycle/UI orchestration layer**:
    the row `toggleExperimentalControl` entry point, the `stopProcessTapLiveControl` product-vs-
    advanced-manual router, the **shared** `applyLiveControlStoppedDisplay` cleanup (used by both
    product and advanced-manual stops, reached through the seam), advanced-manual stop, the
    `tearDownAllProcessTapWork` global teardown fan-out (only its Product Real state-reset sub-block
    delegates to the coordinator; resolution-task cancel stays in place to preserve ordering), the
    output-device-change fan-out, and all sleep / wake / termination entry points. These are
    genuinely cross-subsystem and intentionally stay in the view model.
  - Rationale for the staged extraction (both start and stop paths) is in `docs/DECISIONS.md`.
- Product sessions use an indefinite timeout policy while healthy. Manual Advanced Live
  and diagnostic/readiness paths remain limited/short-lived.
- Product sessions have **no app-count limit** (`maxConcurrentLiveSessions = nil`, owner decision).
  Product starts are serialized through the **queued start lane** (one helper resolution or start
  in flight, the rest FIFO with the pending badge, re-preflighted at drain). Live diagnostics are
  published only for the focused (newest) session and only while the Advanced section is visible.
  Rationale for all three in `docs/DECISIONS.md`.
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
  - Real control starts only on interaction (always on, no toggle; owner decision).

---

## Next Recommended Low-Risk Work

> **First priority now:** the real-hardware N-session characterization (measurement only — see
> "Real-hardware N-session characterization — next gate" under Later Research), then the deferred
> many-session hardening it informs. Most items in this section are done.

### Extract Product Real Control coordinator — DONE (facade + 3 sub-objects)

**Priority**: High | **Risk**: Medium | **Status**: **Complete** — the internal Product Real split is
finished; `ProductRealControlCoordinator` is a thin facade over a state store + start + stop coordinators

The initial reassessment deferred the coordinator (the cluster was the central arbiter with ~142
references and four shared `@Published` properties). That was later superseded: both the **start**
and the **stop** paths were extracted into `ProductRealControlCoordinator` in small,
independently-tested steps, and the coordinator was then **split internally into cohesive sub-objects
behind the unchanged facade**. Each step stayed behind the unchanged `MixerViewModelLiveControlTests`
plus focused new tests; the full suite was green at the end of the split (**414 passed / 0 failed
/ 0 skipped**; it has grown since — see `docs/HANDOFF.md` §6).

**Internal split — completed (Prompts 223–228):**
- `ProductRealControlStateStore` — the single `ProductRealControlState` source + `onWillChange`
  notification storage (one shared instance; one notification before each write, none on reads).
- `ProductRealStopCoordinator` — the full product stop path (per-app stop, Stop All core, stop
  callback, app-exit slice, hard-teardown reset, active-name helper) behind the facade.
- `ProductRealStartCoordinator` — the full product start + resolution path (app-audio resolution +
  `appAudioResolutionTask` ownership/`deinit`, start preflight, both `startExperimentalControl`
  overloads, async body, diagnostics-callback acceptance, cached-helper retry, stale-start
  rejection/cleanup, settle-gate ordering) behind the facade.
- `ProductRealControlCoordinator` **slimmed to a true facade** (~170 lines, no start/stop
  implementation, no redundant stored deps) — constructs the three sub-objects, wires the three
  `[weak self]` cross-edges, and forwards the public API.
- The **facade public API and initializer signature are unchanged** and **`MixerViewModel` is
  byte-for-byte unchanged**; one shared state source; no Start↔Stop sibling ownership / retain cycle.
- **Test redistribution done:** `ProductRealControlStateStoreTests`, `ProductRealStopCoordinatorTests`,
  and `ProductRealStartCoordinatorTests` hold the unit coverage; `ProductRealControlCoordinatorTests`
  keeps facade forwarding + cross-edge integration; `MixerViewModelLiveControlTests` unchanged.

**No further Product Real structural refactor is pending.**

**Intentionally NOT extracted (stays in `MixerViewModel`)**: the global cross-subsystem router
(`stopProcessTapLiveControl`), the shared display cleanup (`applyLiveControlStoppedDisplay`), the
lifecycle / sleep / wake / termination entry points, the output-device-change fan-out, and the
`tearDownAllProcessTapWork` multi-subsystem teardown fan-out. These are not product-only, so keeping
them in the view model is deliberate — moving them into a product coordinator would increase
coupling. (The app-count limit was later removed by owner decision — see "N-app Product Real
Control" below.) Full staged rationale in `docs/DECISIONS.md`.

**Optional future decomposition (outside Product Real, only if a clean boundary emerges):** a
read-only reassessment of the remaining `MixerViewModel` responsibilities — lifecycle / global
teardown, `refreshApplications` app-refresh orchestration, and shared display/status handling — as
candidate *independent* extractions. Do **not** force any of these into a Product Real coordinator.
Resume feature or real-hardware stability work if no clean boundary emerges.

---

### Non-writable output-volume UX — done (incl. proactive probe)

**Priority**: High | **Risk**: Low | **Status**: Implemented

`SystemOutputCoordinator` now tracks per-device writability
(`isSystemOutputVolumeWritable`) and `MixerPanelView` shows a compact persistent
"Read-only" badge plus tooltip when the selected device rejects volume writes. Writability
resets when the selected device changes.

**Follow-up — done (`3c2f4e8`)**: writability is probed proactively with the read-only
`SystemVolumeControlling.isCurrentOutputVolumeSettable()` (`AudioObjectIsPropertySettable` on
the same addresses the write path uses) at init, on an output-device change, and after a
successful device selection, so the badge appears before the first slider drag. An unknown result
assumes writable; rejected/successful writes still flip the flag. 20 new
`SystemOutputCoordinatorTests` cover the probe and the coordinator failure paths.

---

### Accessibility labels — done

**Priority**: Medium | **Risk**: Low | **Status**: Implemented

Explicit labels/values/hints added for app rows (volume slider, mute, Real/Resolving
state), the system output slider and mute button, and output-device selection rows.

**Follow-up — done (`3a84483`)**: the rest of the UI is covered too — panel header/section
captions, the Output devices button, the "Real app control" / "Show all" toggles (since then the
former was removed and the latter moved to the header `⋯` menu), the Advanced disclosure, the
severity-prefixed status banner, the read-only badge, the device list, and the Advanced Process Tap
test, helper discovery, and Two-App Readiness views (macOS 13-compatible modifiers only, no layout
change).

**Still optional**: SwiftUI accessibility/snapshot tests once a view-test harness exists (see
"UI-layer test coverage" below).

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
(both the Advanced manual path and the Real App Control row-interaction path) attach an
`openSystemAudioRecordingSettings` action rendered as an inline "Open Settings" button.

---

### CHANGELOG and release-readiness cleanup — mostly done

**Priority**: Low | **Risk**: Low | **Status**: `CHANGELOG.md`, packaging, and `docs/RELEASING.md`
in place; no release cut

`CHANGELOG.md` exists with milestone history and an `[Unreleased]` section, `Info.plist` carries
`NSHumanReadableCopyright`, and the release path is scripted (see "Release packaging and
distribution" below). Remaining work: keep the changelog synchronized with each change and, when
the owner decides to release, prepare conservative release notes without implying production-grade
multi-app mixer support (real-hardware resource evidence stops at three sessions).

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

**Note**: The duplicated `beginSession` call in `startExperimentalControl` (now in
`ProductRealStartCoordinator`) is intentional (early optimistic set + post-`await`
re-assertion) and is documented inline. Do not "simplify" it away without re-checking the
suspension-point behavior.

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

All tests target view models, coordinators, and services. SwiftUI views
(`MixerPanelView`, `ProcessTapTestView`, etc.) have no automated coverage. Investigate a
lightweight accessibility/snapshot harness so view regressions (including the new
accessibility labels) are caught.

**Likely files**: new test target/helpers, `MacMiniMixerTests/*`.

---

## Later Research / Experimental Work

### Real-hardware N-session characterization — next gate

**Priority**: High | **Risk**: Low (measurement only) | **Status**: Not started (resource
measurements); crackle/underrun listening tests with the direct engine covered up to six sessions

The app-count limit is gone, but no CPU, memory, Stop All or sleep numbers exist for more than three
concurrent sessions, and the three-session numbers predate the direct output engine. (With the
direct engine the owner listened to up to six sessions at 48 kHz and 44.1 kHz — no crackle,
`underruns=0` — which says nothing about resource use.) Before claiming anything about many-app
control, run a Release build on a
real Mac with e.g. **5–8** Real apps (direct apps plus at least one browser/helper row) and record
panel-closed CPU, memory, threads, Drops/Fail/Starv/Gap, and audible glitches; then per-app stop,
Stop All (time until audio is normal and CPU ~0%), an output-device change with all sessions
active, quitting one controlled app, and sleep/wake. Watch for orphaned mutes and for
`sudo killall coreaudiod` being needed. Procedure: `docs/MANUAL_TEST_CHECKLIST.md` §19. Record
only measured values; the results decide what in the next section is urgent.

---

### Many-session hardening — deferred (audio-adjacent, needs hardware evidence)

**Priority**: High | **Risk**: Medium | **Status**: Known, deliberately not changed yet

Found while planning the multi-app work; each touches the teardown path, so each should follow the
characterization above and get its own small, test-first change plus a hardware retest:

- **Engine self-stops bypass the gates.** Stops a live controller initiates itself (output-device
  change or target-app exit detected by its diagnostics timer, timeout) go around the Core Audio
  lifecycle gate (P181) and the stop→start settle gate (P179), so N sessions can tear down
  concurrently — exactly the route churn those gates exist to prevent.
- **Hard teardown blocks the main thread at sleep/quit.** `stopLiveControlNow` runs synchronously,
  one fade + destroy per session; estimated from the code path at roughly 0.4–3.4 s with many
  sessions (not measured).
- **Stop All is sequential** (N × fade + destroy in one settle-gate task).
- **The menu bar label / scene observes the whole view model**, so every `objectWillChange`
  re-evaluates it.
- Smaller: the shared active-name display picks `activeSessions.first` in dictionary order (not
  deterministic); slider moves during a start's optimistic window are dropped until the next move
  after confirmation; optionally add a settle after a `.discoveredHelper` resolution.

---

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

**Goal**: Use this only as Advanced diagnostic evidence. Main-UI multi-app control now goes
through Product Real Control itself.

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
- Start with one boosted app at a time, even though normal control has no app-count limit.
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
helper-PID-replacement combinations; behavior with many (more than three) sessions; and the broader long-idle
/ app-exit / helper-exit / Core Audio failure resource characterization. Short-run Release CPU
for one and two sessions has now been profiled (see below), but sustained (hours-long)
CPU/latency/resource behavior is still unmeasured.

**v0.14 stability evidence (next gate)**: a three-session sleep/wake smoke is the next evidence
gate (procedure in `docs/MANUAL_TEST_CHECKLIST.md` §14.6). The existing sleep/wake code is
collection-based and is expected to be N-safe, but three sessions needed one real-hardware
confirmation. Alongside a 30–60 min three-session long-run and callback-jitter/output-starvation
measurement, these formed the v0.14 "stability polish" track. With the app-count limit removed,
sleep/wake with many sessions is part of the N-session characterization above (the synchronous
hard teardown is the known risk).

**Three-session jitter/starvation short smoke — passed (one real Mac).** The Phase 6c
diagnostic-only counters (callback jitter / output starvation) are now visible in the live
Advanced diagnostics card ("Gap … · Late … · Starv …") and at the start of the stop-result
detail. A ~6–7 min three-session smoke (Music + Spotify + a helper) observed `Starv 0`,
`Drops 0`, `Fail 0`, `Late 1`, `maxGap` ~70–133 ms, with **no audible glitch or audio loss** —
treated as PASS. A single late callback / a 70–133 ms max gap is not on its own a failure (a
brief spike, panel open, around stop, or a helper input pause can produce it); the gate is "no
audible glitch and clean stop". Panel-open Advanced diagnostics is a known CPU-heavy view
(panel closed ≈ 25%, panel open / Advanced closed ≈ 39%, panel open / Advanced open ≈ 55% in
Release) — a diagnostics/UI publication cost, **not** a release blocker and not an audio-path red
flag. (Since then, `e95bcd0` limited each session's diagnostics publishes to ~4 Hz, and
`5a78656` publishes only the focused session and only while the Advanced section is visible. The
panel numbers above predate both changes and have not been re-measured.) The 30–60 min three-session long-run has since
passed (see below).

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

**Scope guardrails (at the time)**: the cap stayed **3** (`maxConcurrentLiveSessions = 3`; later
removed by owner decision, see "N-app Product Real Control"); the unsafe default-output observer
was **not** reintroduced (still true). Decision rationale is in
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
cannot queue create/destroy churn faster than coreaudiod settles. It does **not** change the
audio callback or the teardown gates. Since the queued start lane (`774268a`), a row whose start
is queued also counts as pending. Rationale in `docs/DECISIONS.md`; manual smoke in
`docs/MANUAL_TEST_CHECKLIST.md` §18.

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

### Three-app cap (cap=3) enabled — done (real-hardware smoke passed; cap later removed)

**Priority**: High | **Risk**: Low | **Status**: Historical — `maxConcurrentLiveSessions` was 3
here; three-session smoke passed on one real Mac. Superseded by "N-app Product Real Control"
below (no app-count limit). The measurements stay the only real-hardware multi-session evidence.

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
more than three sessions.

---

### N-app Product Real Control (app-count limit removed) — done in code; hardware evidence pending

**Priority**: High | **Risk**: Medium | **Status**: Implemented (`08d49bc`, `da2b06e`, `c57bf37`,
`5a78656`, `774268a`); real-hardware characterization beyond three sessions **not done**

Owner decision: like the Windows Volume Mixer, every app the user interacts with can be
Real at the same time (real app control is now always on, no toggle). What landed:

- **Cap removed**: `AppConstants.maxConcurrentLiveSessions: Int? = nil`,
  `ProcessTapLiveSessionManager(maxSessions: Int?)`, injectable `maxConcurrentSessions` on the
  start coordinator / facade so tests still prove the cap mechanism. Fake-backed tests cover 6–8
  concurrent sessions (real manager + fake controllers end to end, facade, banner).
- **Queued start lane** (resolves "gap B"): one helper resolution or product start in flight;
  further slider/mute/toggle starts queue FIFO with the pending badge and re-preflight at drain;
  cleared by per-app stop, Stop All, Real off, output change, sleep, termination, panel close, app
  exit. Stop All also cancels an in-flight helper resolution.
- **Diagnostics focus/visibility**: only the newest session publishes to the shared Advanced card,
  and only while the Advanced section is visible; attribution logging stays per session.
- **Multi-session fixes**: quitting the Advanced-selected app no longer stops every product
  session; the cached-helper retry runs alongside other product sessions.

**Remaining gates**: the real-hardware N-session characterization and the deferred many-session
hardening (both in "Later Research / Experimental Work" above). Real control starts only on
interaction.

---

### Direct aggregate output engine and per-app audio processes — done; device coverage pending

**Priority**: High | **Risk**: Medium (audio path) | **Status**: Implemented (`5a498c2`, `6d1d265`,
`377f1a8`, `da6ed70`); crackle-free on one Mac; legacy `AudioQueue` removal and wider device coverage
**not done**

What landed (rationale in `docs/DECISIONS.md`, "Why live output renders straight to the device
through one aggregate IOProc"):

- **Direct output.** Random crackle came from two clocks (tap-only aggregate IOProc → cross-thread
  hand-off → `AudioQueue` on the output clock). The default live path is now one private aggregate =
  default output device (main/clock sub-device) + tap with one IOProc writing straight to the device,
  with the existing fade-in/out and gain, and a fallback to the legacy `AudioQueue` path for devices
  with input streams, unsupported formats or any setup failure.
- **Sample rates.** The tap stream reports 48 kHz while built-in speakers default to 44.1 kHz. The
  engine converts inside the IOProc but first measures the cycles; real hardware passes through
  (`path=passthrough`, the HAL already delivers the aggregate's rate). The device's sample rate is
  never changed (owner decision). Switches: `MacMiniMixerLiveOutputMode=audioQueue`,
  `MacMiniMixerDirectResample=off`.
- **Per-app audio processes.** All of an app's HAL audio processes are tapped together, attributed by
  resource coalition (undocumented `proc_pidinfo` flavor, bundle-id fallback), so Safari and Safari web
  apps, Chrome and PWAs/Canary can each be Real.
- **Evidence** (owner's Mac): crackle-free at 48 kHz (5 sessions) and 44.1 kHz (up to 6), and on a
  second output device at 48 kHz (Firefox, Safari, Spotify, Music, YouTube). Not measured: CPU,
  memory, latency.

**Next steps (none started)**:
- Verify the direct engine on more output devices, sample rates and macOS versions; record the
  `output=` / `resample report … path=` log lines each time (`docs/MANUAL_TEST_CHECKLIST.md` §21).
  Includes confirming which path the second output device used.
- Re-measure Release CPU with the direct engine (the 1/2/3-session numbers predate it) as part of the
  N-session characterization.
- **Remove the legacy `AudioQueue` live output** (`ProcessTapLegacyAudioQueueOutput.swift`) and the
  `MacMiniMixerLiveOutputMode` override. Blocker/open owner question: output devices with input
  streams (headsets/interfaces with a microphone) still depend on it; either support them directly
  (needs a reliable way to find the tap stream in the aggregate's input list) or accept no live
  control there.
- Evaluate whether the Replay Probe's own `AudioQueue` should be unified or dropped afterwards.
- Coalition caveats to keep in view: undocumented flavor (fallback exists), rows sharing one coalition
  contend for helpers, no real-hardware evidence yet for Chrome vs PWAs/Canary.

---

### Release packaging and distribution — scaffolding done; notarization future

**Priority**: Medium | **Risk**: Low-Medium | **Status**: Ad-hoc packaging implemented
(`e0a60b4`); no release cut

- `scripts/package-app.sh`: Release build, ad-hoc signed staged copy (required to launch arm64
  code; not notarized), `dist/MacMiniMixer-<version>[-<label>].zip` + `.sha256`.
- `Build` workflow `package` job: uploads the zip as the `MacMiniMixer-app` artifact (14 days).
- `release.yml`: on `v*` tags runs tests → package → checks the tag equals `v` + `MARKETING_VERSION`
  → creates a **draft** GitHub Release; manual dispatch produces the artifact only.
- `docs/RELEASING.md`: maintainer checklist, Gatekeeper instructions for ad-hoc builds (incl. the
  macOS 15 "Open Anyway" flow), and the documented-only Developer ID + notarization steps.

**Future**: Developer ID signing + notarization (needs an Apple Developer membership, a real
bundle identifier instead of `com.example.MacMiniMixer`, and a check that Process Tap capture works
under the hardened runtime). A `.dmg` is optional. Keep this separate from runtime audio behavior.

---

### Unscheduled ideas (carried over from the former README roadmap)

**Priority**: Not set | **Status**: Not started, unscheduled

These items used to be listed in the README's Roadmap section (the README is now a user-facing
document). They are kept here so nothing is lost; none has an owner decision or a plan yet. The other
former README roadmap items already have their own sections above: the N-session characterization,
widening direct-engine device coverage and removing the legacy `AudioQueue` output (including the
Replay Probe's own queue), routing engine-initiated stops through the gates / faster Stop All /
shorter main-thread teardown / narrowing what the menu bar label observes ("Many-session hardening"),
Two-App Readiness with more apps, helper PID changes, long-run CPU / latency / buffer-drop
diagnostics ("Sleep/wake and long-running resource characterization"), the optional read-only
`MixerViewModel` reassessment, independent sessions versus a centralized mixer/renderer, and Developer
ID signing + notarization.

Polish and robustness:
- Better UI polish.
- More robust output device handling.
- Continue simplifying the main UI while keeping diagnostics available in Advanced.
- Add more characterization tests around lifecycle cleanup, app list/preview state, and status
  behavior.
- Refine live session reliability and latency.
- Better app active/inactive state handling.
- Refine automatic audio-relevant app detection, and audio activity detection improvements.

Research and experiments:
- Design a safe architecture for per-app gain/mute experiments.
- Investigate browser/helper process discovery for Safari, YouTube, and similar web audio.
- Refine helper candidate selection, and the confidence/scoring of auto-detected audio helpers.
- Refine browser/helper row mapping behind an explicit experimental mode.
- Investigate routing/replay requirements.
- Decide whether Process Tap alone is enough or whether a virtual device/HAL approach is needed later
  (see "Explicitly Deferred Large-Scope Work").
- Eventual automatic real mixer behavior if it proves stable, and reducing the experimental UI over
  time if stability improves.

Longer-term:
- Installer/uninstaller if needed (see "Explicitly Deferred Large-Scope Work").
- Documentation for known limitations.
- macOS version support notes.

Background Music and BlackHole may be studied architecturally later, but their code is not copied.

---

## North-Star Goal: Full Windows-style Multi-App Mixer

The maintainer's end goal is a true Windows Volume Mixer experience: **simultaneous,
independent per-app volume control for every app shown in the audio list**, changed live and
at the same time. This is the product's north star, not a deferred curiosity.

The work was approached **incrementally** for sound engineering reasons (see
`docs/DECISIONS.md`): one validated session, then two, then three, each with real-hardware
evidence. The diagnostic tooling is retained precisely because it is the evidence base and the
development instrument for this goal.

**Milestones toward it**:
1. Sustained two-app live control — **done** (Phase 0–3).
2. N-app session management in `ProcessTapLiveSessionManager` — **done** (`maxSessions: Int?`,
   unlimited in the product).
3. Per-row real control state in the main UI, any number of rows — **done** (per-app stop, Stop
   All, compact "N apps controlled" banner, queued start lane, per-app exit handling).
4. Resource/latency characterization under many simultaneous sessions — **open** (the next gate).

The app-count limit is gone by **owner decision** (`maxConcurrentLiveSessions = nil`), so the
remaining gap to the north star is **evidence and hardening, not a configuration value**:
real-hardware N-session characterization (e.g. 5–8 apps: CPU, Drops/Fail/Starv, output change,
Stop All, sleep/wake), then the deferred many-session hardening (engine self-stops through the
gates, main-thread hard teardown, sequential Stop All). Real-hardware resource evidence currently
stops at three sessions (see "Three-app cap (cap=3) enabled" above); the direct output engine was
additionally listened to with up to six sessions (no crackle). Control also still requires
interaction with each row (real app control is always on, with no toggle), so "every app in the list,
automatically" is not a goal of the current design.

The phased implementation plan and its status live in [`PLAN_MULTI_APP.md`](PLAN_MULTI_APP.md).

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

The current direction remains: preserve the public-API Process Tap approach (one independent
session per app), gather real-hardware evidence for many simultaneous sessions before claiming
it is stable, validate behavior with tests/manual diagnostics, and avoid broad audio-path
rewrites unless evidence shows they are necessary. A centralized renderer stays deferred unless
the N-session measurements show independent sessions do not scale.
