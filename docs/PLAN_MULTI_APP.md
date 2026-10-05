# Plan: Toward a Full Multi-App Mixer

This is the implementation plan for MacMiniMixer's north-star goal (see `ROADMAP.md`):
simultaneous, independent per-app volume control for every app in the audio list. It is
deliberately incremental and evidence-gated. The first concrete milestone is **sustained
two-app live control**.

> **Status (current):** Phases 0–5 are **done in code**. The product went from one session to two,
> then three, and then — by **owner decision** (`08d49bc`) — to **no app-count limit**
> (`maxConcurrentLiveSessions = nil`, manager `maxSessions: nil`). Gap B (resolution queue) is closed
> by the queued start lane (`774268a`); the shared-diagnostics part of gap D is mitigated by
> publishing only the focused session while Advanced is visible (`5a78656`); per-app exit and
> cached-helper retry were fixed for many sessions (`da2b06e`, `c57bf37`). **What is left is
> evidence and hardening, not code to lift a limit:** real-hardware characterization with more than
> three sessions (none has been done), then the deferred many-session items listed under Phase 5.
> The sections below are kept as the historical plan; where they say "maxSessions = 1", "cap 2", or
> "N > 3 deferred", that describes the state at the time.

## Feasibility verdict

**Feasible, and the right next step.** Half the infrastructure already exists. The work is
not writing a new audio engine — it is lifting the *product layer* from a single-session
assumption to multi-session, and proving stability under sustained (not 10-second) use.

## What already exists

- **Multi-session engine**: `ProcessTapLiveSessionManager` already supports N sessions via
  `init(maxSessions:controllerFactory:)`, with per-session diagnostics/stop callbacks,
  `activeSessions`, `stopAll`, and `updateGain(sessionID:)`. The product currently uses the
  single-session compatibility shim `init(controller:)` (`maxSessions = 1`). *(At the time of
  writing; the product now uses `init(maxSessions: nil, controllerFactory:)`.)*
- **Two-session evidence**: Two-App Readiness
  (`CoreAudioProcessTapTwoAppReadinessTester`) already runs two simultaneous sessions for a
  10s diagnostic with per-session callbacks/peak/RMS/queued/drops, observed at 0 drops.
- **Per-row UI scaffolding**: rows already render a per-app "Real" badge driven by
  `isExperimentalControlActive(for:)`.

## The real gaps

| # | Gap | Required change | Risk |
|---|-----|-----------------|------|
| A | Product state is singular — `ProductRealControlState.activeSession`, `isProcessTapLiveControlActive: Bool`, `activeLiveControlAppName: String?` model exactly one session | Convert to a collection keyed by visible app id | **High** — touches the ~142-reference central arbiter in `MixerViewModel` |
| B | Resolution is single-lane — `HelperAudioTargetResolver` rejects a second concurrent resolution (`beginResolution`), and probing uses one shared probe | Queue resolution requests; surface a per-row "queued" state | Medium — **done in code (`774268a`)**: a single start lane covers a resolution *or* a product start; further requests queue FIFO with the pending badge and re-preflight at drain |
| C | Mutual-exclusion guards block a second product session ("Stop the active live control first") | Relax for live sessions while keeping resolution serialized | Medium |
| D | Diagnostics-display coupling — product drives the single `advancedProcessTapDiagnostics` result/progress surface | Give product its own per-row state instead of the shared Advanced surface | Medium (the coupling flagged in the coordinator reassessment) — **mitigated (`5a78656`)**: only the focused session publishes, only while Advanced is visible; per-row state still not built |
| E | Lifecycle is not per-session — output change / app exit / termination tear down *the* session | Map an exited app id to its session; selective stop (the manager has `stopAll`, needs selective product use) | Medium |
| F | App wiring uses `init(controller:)` (maxSessions=1) | Switch to `init(maxSessions: 2, controllerFactory:)` | Low (one line, but triggers A–E) |
| G | Resource reality — N× independent tap + private aggregate device + IOProc (the direct output engine; the AudioQueue path is now a legacy fallback); **short-run** two- and three-session Release CPU is now measured (2 direct ~12–14%, 3-session ~19%; see Phase 5 note), but sustained (hours) and N>3 CPU/latency remain unmeasured | Characterization evidence | **Met for three sessions (short-run + normal-use long-run); still open for more than three — now the main remaining gate since the cap is gone** |

## Phased plan (each phase gated by evidence)

**Phase 0 — Sustained characterization (do first).** Add a longer-running mode to Two-App
Readiness (minutes, not 10s) measuring CPU, latency accumulation, drops, and sleep/wake.
Everything downstream is gated on whether two sustained sessions stay stable. *Code: tester
+ view, low risk.*

**Phase 1 — De-risk the state model.** Convert `ProductRealControlState` from a singular
`activeSession` to a collection `[visibleAppID: ActiveSession]` **without enabling multi
yet** (keep `maxSessions = 1`, enforce one at the orchestration level). Pure refactor plus
characterization tests. This is exactly the work the coordinator reassessment said to revisit
"if the shared state can be reduced" — multi-app is now the driver. **Highest code risk**
(protected by the existing characterization tests).

**Phase 2 — Serialize resolution.** Queue resolution so app B shows "queued" while app A
resolves, instead of being rejected. *Status: done in code (`774268a`) as a single **start
lane**: it turned out there were two single lanes (the resolver, and every product start holding
the shared Advanced "running" flag), so the lane covers a resolution **or** a product start, and
direct-PID starts queue too (the helper probe creates its own tap + aggregate outside the
lifecycle/settle gates). Queued rows show the pending badge; entries re-run their full preflight
at drain; per-app stop, Stop All, Real off, output change, sleep, termination, panel close, and app
exit drop them. See `DECISIONS.md` "Why Product Real starts are queued behind a single start lane".*

**Phase 3 — Flip to maxSessions = 2.** Wire `init(maxSessions: 2, controllerFactory:)`,
relax the mutual-exclusion guard to allow a second product session, route per-app gain via
session ids. **Two only, first.**

**Phase 4 — Per-session lifecycle.** Tear down app-exit / output-change / termination per
session rather than globally. *Status: per-session teardown done; system sleep/wake lifecycle
added — sleep synchronously tears down all active/pending work with a typed `.systemSleep`
reason, wake is refresh-only (device/volume/app state) with no auto-restart (see
`DECISIONS.md`). Auto-restart/recovery and longer-duration sleep/wake characterization remain
open.*

**Phase 5 — N apps.** Raise the cap as evidence allows, toward the full mixer.

*Status: **done in code — no app-count limit** (owner decision, `08d49bc`).*
- `AppConstants.maxConcurrentLiveSessions: Int? = nil`; the product manager is
  `ProcessTapLiveSessionManager(maxSessions: nil, controllerFactory:)`; the start coordinator /
  facade keep an injectable `maxConcurrentSessions: Int?` so tests can still prove a configured cap.
- Follow-ups for many sessions: per-app exit no longer stops every session when the
  Advanced-selected app quits (`da2b06e`); the cached-helper retry runs alongside other sessions
  (`c57bf37`); live diagnostics publish only for the focused session while Advanced is visible
  (`5a78656`); the queued start lane (`774268a`, Phase 2 above). The banner already summarizes any N
  (originally "first two +N more"; since `4220c46` the one-line "N apps controlled").
- Fake-backed coverage: real manager + fake controllers end to end with 7 apps, facade with 6, an
  unlimited manager with 8 sessions, a 7-app banner test.

*Remaining gates (need real hardware; nothing above has been measured with more than three
sessions):*
1. **N-session characterization** — Release build, e.g. 5–8 Real apps: CPU, memory/threads,
   Drops/Fail/Starv/Gap, audible glitches; per-app stop, Stop All, output-device change, quitting one
   app, sleep/wake (`MANUAL_TEST_CHECKLIST.md` §19).
2. **Engine self-stops bypass the gates** — stops a controller initiates itself (output change / app
   exit seen by its diagnostics timer, timeout) go around the lifecycle (P181) and settle (P179)
   gates, so many sessions can tear down concurrently.
3. **Hard teardown blocks the main thread** at sleep/quit — estimated from the code path at roughly
   0.4–3.4 s with many sessions (not measured).
4. **Stop All is sequential** (N × fade + destroy).
5. The menu bar label / scene still observes the whole view model.
6. Still open from before: sustained (hours) long-run with many sessions, the real-hardware
   orphan-tap repro, AudioQueue underrun/jitter at scale.

*History (kept): cap=3 done. `maxConcurrentLiveSessions` was raised from 2 to 3 (Phase 5a/5b) and a three-session smoke
passed on one real Mac (Release; two direct + one helper) — measured CPU ≈ 19% (within the
~17–25% PASS band), memory ≈ 59 MB, ~16 threads, thermal nominal; per-app stop, Stop All, output
change, and repeated start/stop all clean, no drops/failures/cleanup warnings; CI green (see
`ROADMAP.md` and `DECISIONS.md`). N > 3 remains **deferred** — not a config bump: it needs the
single-lane resolver promoted to a real queue (multi-helper UX), N-session Core Audio
resource-scale evidence, larger-N UI/banner behaviour, repeated-teardown safety at scale, the
real-hardware orphan-tap repro, AudioQueue underrun/jitter measurement (drops==0 does not cover
it), and sustained long-run characterization. Go/no-go for N > 3 is a separate decision; do not
raise the cap past 3 before it. — That go/no-go was taken by the owner (no limit); the
resolver-queue, UI/banner, and per-app teardown items were done in code, and the evidence items
moved to the remaining gates above.*

## Recommended order

*Historical:* start with **Phase 0** (sustained characterization): low risk, produces the gating
evidence, unblocks the rest. In parallel, a read-only boundary plan for **Phase 1** can be drafted
since it is the highest-risk refactor.

*Now:* the real-hardware N-session characterization (Phase 5 remaining gate 1) comes first; then
the engine-self-stop gating (gate 2), then whatever the measurements show is most urgent among
gates 3–5.

## Biggest risk

Phase 1's singular→collection conversion touches the central arbiter (wide blast radius).
Mitigation: the existing characterization tests, plus incremental behavior-neutral steps.

---

## Phase 1 boundary plan (read-only analysis)

Goal: convert the single-active-session model to a per-app collection **without enabling
multi yet** — keep `maxSessions = 1` and all mutual-exclusion guards, so behavior is
identical and all existing tests stay green. This de-risks the largest refactor so Phase 3
only has to flip the cap and relax guards, not re-plumb state.

### Where "single session" lives today (three layers)

1. **State model — `ProductRealControlState`**
   - `activeSession: ProcessTapRealControlActiveSession?` — the singular piece.
   - `resolutionStateByAppID: [appID: AppAudioResolutionState]` — *already* a dict, but
     `beginResolution` does `resolutionStateByAppID = [appID: .resolving]` (replaces the
     whole dict), so resolution is dict-shaped yet single-enforced.
2. **View-model `@Published` mirrors (in `MixerViewModel`)**
   - `isProcessTapLiveControlActive: Bool`
   - `activeLiveControlAppName: String?`
   - `processTapLiveDiagnostics: ProcessTapLiveDiagnostics?`
3. **Engine** — `processTapLiveController` is `ProcessTapLiveSessionManager(controller:)`
   (`maxSessions = 1`) used through the single-session `ProcessTapLiveControlling` shim.
   Already N-capable underneath; not the bottleneck.

### Critical hazard: `isProcessTapLiveControlActive` is shared by two features

It is set both by **Product Real Control** (per-app rows) *and* by **Advanced manual live
control** (`startProcessTapLiveControl` via `AdvancedLiveControlCoordinator`). So it does NOT
mean "product sessions are active" — it means "the single shared live engine is busy (by
either feature)." Today the two are mutually exclusive by guard. **Phase 1 must not naively
derive this flag from the product session collection alone** — Advanced manual control also
owns it. This is gap D from the table and the main subtlety of the refactor.

### Target shape after Phase 1 (still ≤1 enforced)

- `ProductRealControlState.activeSessionsByAppID: [MixerAppItem.ID: ActiveSession]` replaces
  `activeSession`. Keep `activeSession` / `activeVisibleAppID` as computed "first entry"
  conveniences during the transition.
- New/changed queries: `activeVisibleAppIDs: [ID]`, `isActive(appID:)`,
  `clearSession(for: appID)` (alongside `clearActiveSession` = clear all).
- `beginResolution` stops replacing the dict and instead inserts the one app (still ≤1 by
  orchestration), so Phase 2 can allow a queue without a model change.

### Concrete, behavior-neutral sub-steps (each independently test-green)

**Status: Phase 1 complete.** Sub-steps 1 and 2 are implemented and behavior-neutral
(`ProductRealControlState` collection + `MixerViewModel` iteration); sub-step 3 is folded
into Phase 3 (see below); sub-step 4 is documentation only (no code). The product path still
enforces one active session.

1. **State model collection (do first, lowest risk).** Add `activeSessionsByAppID`; make
   `activeSession`/`activeVisibleAppID` computed from it; `beginSession` inserts,
   `clearActiveSession` clears all, add `clearSession(for:)`. Extend
   `ProductRealControlStateTests`.
2. **VM consumers loop over all active app ids.** `stopRealControlForExitedTargetApps` and
   the exit/teardown checks iterate `activeVisibleAppIDs` instead of the single
   `activeVisibleAppID`. Still ≤1, so identical behavior; positions the code for N.
3. **Per-app diagnostics scaffolding — folded into Phase 3 (not done in Phase 1).** On
   inspection, the single `processTapLiveDiagnostics` is written by *both* the product path
   and the Advanced manual path (which has no product app id). Introducing a per-app keyed
   store now would either be dead code (nothing renders per-app meters yet) or break the
   Advanced manual display (no app-id key). This is gap D — it only pays off when per-row
   live meters consume it, so it moves to Phase 3 alongside the display decoupling. Avoid
   adding state nothing reads.
4. **Leave the shared flag intact.** Keep `isProcessTapLiveControlActive` and
   `activeLiveControlAppName` as-is (single). Document that in Phase 3 the flag becomes
   `productSessionsActive || advancedManualActive`, and the name becomes a summary when
   count > 1. Do not change their semantics in Phase 1.

### Explicitly out of scope for Phase 1

- Resolution serialization / queue (Phase 2).
- `maxSessions` flip and guard relaxation (Phase 3).
- Decoupling product control from the shared `AdvancedProcessTapDiagnosticsCoordinator`
  display surface (Phase 3, gap D).
- Banner / menu-bar icon reflecting N active apps (Phase 3).

### Risk and mitigation

- Blast radius is the ~142-reference arbiter, but every sub-step is behavior-neutral with
  `maxSessions = 1`, so the full existing suite must stay green unchanged; new tests cover
  only the new collection shape.
- The shared-flag hazard above is the one place a naive change would regress Advanced manual
  control — call it out in review.

---

## Phase 3 detail plan (read-only analysis)

Goal: allow **two** product real-control sessions at once — lift `maxSessions` to 2, relax
the one-session guard, and route per-app start/stop/gain by session id. This is the first
**behavior-changing** phase and the first point a real two-app manual test is possible.

### The core shift: from the compat shim to the per-session API

Today `MixerViewModel` holds `processTapLiveController: ProcessTapLiveControlling` and uses
the **single-session compat API** (`startLiveControl` / `stopLiveControl` /
`updateLiveControlGain`), which internally tracks one `compatibilityActiveSessionID`. To
control two apps independently the product path must use
`ProcessTapLiveSessionManaging` instead: `startSession(...)` returns a
`ProcessTapLiveSessionID`, and `stopSession(id:)` / `updateGain(sessionID:)` act per session.
`ProcessTapLiveSessionManager` already conforms to both protocols, so this is a consumer-side
change, not an engine rewrite.

### Concrete changes

- **A. Wiring (`MacMiniMixerApp`).** `ProcessTapLiveSessionManager(controller:)` →
  `ProcessTapLiveSessionManager(maxSessions: 2, controllerFactory: { CoreAudioProcessTapLiveController() })`.
  The factory init is mandatory: the single-`controller` init shares one controller instance,
  which cannot run two independent taps. Each session needs its own controller.
- **B. VM uses the session-managing API for the product path.** Hold
  `ProcessTapLiveSessionManaging` for product start/stop/gain. The Advanced manual path keeps
  the `ProcessTapLiveControlling` compat API (one session) — but both share the same manager
  instance and its two slots (see hazards).
- **C. `ProductRealControlActiveSession` gains `liveSessionID`.** Store the id returned by
  `startSession` so the VM can stop/update the correct app's session.
- **D. Start path (`startExperimentalControl`).** Replace the compat `startLiveControl` with
  `startSession`, capture the `sessionID`, store it in the per-app session. The
  `onDiagnostics` / `onStopped` callbacks now carry the `sessionID` → map back to the app id.
- **E. Stop / gain per session.** Add `stopExperimentalControl(for appID:)` →
  `stopSession(id: session.liveSessionID)`. `updateExperimentalGainIfActive` →
  `updateGain(sessionID:gain:)` for that app, not the single compat gain.
- **F. `handleLiveControlStopped` keyed by session.** Identify which app's session stopped
  via the sessionID→appID map; clear only that app's session and invalidate only its cache.
- **G. Guard relaxation.** Allow starting a second product session while one is active;
  keep blocking when Advanced manual / Two-App Readiness / Process Tap testing / resolution
  is busy. Cap product sessions at 2 for now ("Two apps max for now" on a third attempt).
- **H. `@Published` mirrors.** `isProcessTapLiveControlActive` becomes derived
  (`productSessionsActive || advancedManualActive`) — mind the shared-flag hazard;
  `activeLiveControlAppName` becomes a summary when count > 1; the banner lists/counts active
  apps.
- **I. Per-app diagnostics (folded sub-step 3, gap D).** Product sessions stop driving the
  single `advancedProcessTapDiagnostics` surface; introduce `processTapLiveDiagnosticsByAppID`
  for per-row state. Minimal first cut: product rows show only the existing "Real" badge and
  do not write the Advanced surface; per-row meters can come later.
- **J. Resolution serialization (folded Phase 2).** Starting app B's helper resolution while
  app A resolves is rejected by the single-lane resolver. First cut: surface B as "queued" /
  retry; the clean version is a real queue.

### Hazards / decisions

1. **Shared slots between product and Advanced manual.** Both draw on the same
   `maxSessions = 2` manager. Simplest rule: product cap = 2, and Advanced manual stays
   mutually exclusive with product (keep that guard). Alternative: separate managers.
2. **Factory vs shared controller** — must use the factory init (per-session controller).
3. **Shared-flag hazard (gap D)** — derive `isProcessTapLiveControlActive` from both sources.
4. **Resolution single-lane** — queue or sequential UX.
5. **Resource reality** — two independent taps + private aggregate devices; already shown
   stable for 5 minutes by Phase 0, so this is the green light to proceed.

### Entanglement found while starting 3a (refines the above)

The product **stop** path is more shared than first assumed. Product start calls
`processTapLiveController.startLiveControl` directly, but product **stop**
(`MixerViewModel.stopProcessTapLiveControl`) routes through
`AdvancedLiveControlCoordinator.stopLiveControl` → `liveController.stopLiveControl(reason:)`
— the **compat single-session** stop, which is also the Advanced manual stop. So per-app
stop must give the product its own stop that calls `stopSession(id:)` directly, decoupling it
from the shared compat stop. The protocol also needs a timeout-aware `startSession` (the
manager has a non-private `startSession(...timeoutPolicy:)` but it is not on
`ProcessTapLiveSessionManaging`), because the product requires `.indefinite`, not `.standard`.

3b therefore changes start, stop, and gain together (they share the session id) and touches
two test fakes (`FakeLiveControlController`, `FakeTwoAppLiveController`) plus the product
tests. It cannot be meaningfully split smaller while staying behavior-correct.

### 3b-main detail: routing the shared stop (plan)

`stopProcessTapLiveControl` is shared by the product banner, the Advanced manual UI, and the
global stops (output-device change, termination, disabling real control). Today product and
Advanced manual are **mutually exclusive** (≤1 total active), so "stop the one active" works.

3b-main switches the **product** path to the per-session API while leaving Advanced manual
on the compat path, by routing inside the existing stop based on which kind is active:

- **`ProductRealControlActiveSession` gains `liveSessionID: ProcessTapLiveSessionID?`** —
  nil during the brief optimistic window, set to the real id on success.
- **`startExperimentalControl`** uses `startSession(timeoutPolicy: .indefinite, ...)`, wires
  the per-session `onDiagnostics`/`onStopped` (by session id) to the existing handlers, and
  stores the returned id via `beginSession(..., liveSessionID:)`.
- **New `stopProductLiveSessions(reason:)`** iterates `productRealControlState.activeSessions`
  and calls `stopSession(id:)`; each session's wired `onStopped` drives
  `handleLiveControlStopped`.
- **`stopProcessTapLiveControl(reason:)` routes:** if a product session is active →
  `stopProductLiveSessions`; else (Advanced manual) → the existing
  `advancedLiveControl.stopLiveControl` compat path. Behavior-neutral with ≤1.
- **`updateExperimentalGainIfActive`** uses `updateGain(sessionID: session.liveSessionID, …)`.

Why behavior-neutral with ≤1: the route stops whichever single control is active, exactly as
before; start/gain hit the same engine via a different method. The test fakes already record
`startSession`/`stopSession`/`updateGain` into the same arrays, and `emitStopped` fires the
per-session handler, so product-path assertions hold.

Deferred to 3d (when two product sessions exist): a per-row
`stopExperimentalControl(for appID:)`, keying `handleLiveControlStopped` by session id, and a
`stopAllLiveControl` for the global stops.

### 3d detail: allowing a second product session (plan)

3d is the behavior change. It is decomposed so the risky state/flag work is behavior-neutral
prep, and only the guard relaxation flips behavior (the first two-app manual test).

**Key state distinction.** `isProcessTapLiveControlActive` today is a shared stored flag set
by both product and Advanced manual. For two product sessions it must become derived:
- New stored `advancedManualLiveControlActive` — set only by the Advanced manual path
  (`startProcessTapLiveControl` onStarted/onStopped).
- `isProcessTapLiveControlActive` becomes computed:
  `advancedManualLiveControlActive || !productRealControlState.activeSessions.isEmpty`.
- "Advanced manual is the active one" = `advancedManualLiveControlActive` (product count 0).

**3d-i (behavior-neutral prep).**
- Split the flag as above; route the Advanced manual path to set
  `advancedManualLiveControlActive`; everything reading `isProcessTapLiveControlActive` keeps
  working via the computed value.
- Key teardown by session: `handleLiveControlStopped` takes the stopped `sessionID`, finds
  the app whose `liveSessionID` matches, and clears only that app (`clearSession(for:)`)
  instead of `clearActiveSession()`. Wire the product `onStopped` callback to pass its
  `sessionID`. With ≤1 enforced this is identical behavior. Tests.
- `activeLiveControlAppName` becomes derived (single name when one product session; a count
  summary when more) — still one today.

**3d-ii (behavior flip — FIRST TWO-APP MANUAL TEST).**
- Relax the start guard in `startAutomaticRealControlIfNeeded` / `startExperimentalControl`:
  replace `if isProcessTapLiveControlActive || isProcessTapTesting { block }` with: block if
  `isProcessTapTesting`, block if `advancedManualLiveControlActive`, block if
  `productRealControlState.activeSessions.count >= AppConstants.maxConcurrentLiveSessions`
  ("Two apps max for now"). Allow an additional product session otherwise.
- Add `stopExperimentalControl(for appID:)` → `stopSession(id: that app's liveSessionID)`,
  so the per-row "Real" toggle and per-row stop affect only that app. `toggleExperimentalControl`
  stops just its row; the banner gets per-app or stop-all affordances.
- The global stops (output change, termination, disable real control) keep stopping all via
  `stopProductLiveSessions`.

**3d-iii (UI).** Banner reflects N active apps (count or list); rows already show per-row
"Real". Optional per-row live meters fold in here (the deferred sub-step 3).

**Hazards.** The optimistic early `beginSession` now happens per app while another is active —
ensure the collection keys by app id (it does). `handleLiveControlStopped` must not clear
sibling sessions. Resolution is still single-lane (Phase 2 / 3e) — starting B's resolution
while A resolves is rejected; surface "busy" for now.

**Status: Phase 3 two-app control implemented and manually validated.** 3a–3d-ii are done;
two simultaneous product real-control sessions run with independent per-app volume, confirmed
on real hardware (two apps showing "Real", independent control, per-app stop, and the
2-session cap). Remaining: 3d-iii (banner/UI reflecting N apps, optional per-row meters),
then Phase 4 (per-session lifecycle hardening) and Phase 5 (N > 2).

### Suggested sub-order (each builds; behavior-neutral until 3d)

- **3a.** Wiring: `maxSessions = 2` + factory. No behavior change yet (guard still blocks a
  second). Build green.
- **3b.** `ActiveSession` gains `liveSessionID`; product start path switches to
  `startSession`, still one at a time (guard intact). Behavior-neutral. Tests. *(Biggest
  plumbing step.)*
- **3c.** Per-app stop & gain by session id. Behavior-neutral (one session). Tests.
- **3d.** Relax the product↔product guard to allow a second session (cap 2). Derive the
  shared flag; banner summary. **← FIRST TWO-APP MANUAL TEST HERE.**
- **3e.** Resolution serialization / queue UX.
- **3f.** Per-row diagnostics (sub-step 3).

### Risk

High — touches the arbiter's start/stop/gain/lifecycle. Mitigation: 3a–3c are
behavior-neutral (guard still enforces ≤1); only 3d flips behavior and is gated by the manual
two-app test; the existing suite plus new per-session tests guard each sub-step.
</content>
