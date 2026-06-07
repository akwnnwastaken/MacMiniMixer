# Plan: Toward a Full Multi-App Mixer

This is the implementation plan for MacMiniMixer's north-star goal (see `ROADMAP.md`):
simultaneous, independent per-app volume control for every app in the audio list. It is
deliberately incremental and evidence-gated. The first concrete milestone is **sustained
two-app live control**.

## Feasibility verdict

**Feasible, and the right next step.** Half the infrastructure already exists. The work is
not writing a new audio engine — it is lifting the *product layer* from a single-session
assumption to multi-session, and proving stability under sustained (not 10-second) use.

## What already exists

- **Multi-session engine**: `ProcessTapLiveSessionManager` already supports N sessions via
  `init(maxSessions:controllerFactory:)`, with per-session diagnostics/stop callbacks,
  `activeSessions`, `stopAll`, and `updateGain(sessionID:)`. The product currently uses the
  single-session compatibility shim `init(controller:)` (`maxSessions = 1`).
- **Two-session evidence**: Two-App Readiness
  (`CoreAudioProcessTapTwoAppReadinessTester`) already runs two simultaneous sessions for a
  10s diagnostic with per-session callbacks/peak/RMS/queued/drops, observed at 0 drops.
- **Per-row UI scaffolding**: rows already render a per-app "Real" badge driven by
  `isExperimentalControlActive(for:)`.

## The real gaps

| # | Gap | Required change | Risk |
|---|-----|-----------------|------|
| A | Product state is singular — `ProductRealControlState.activeSession`, `isProcessTapLiveControlActive: Bool`, `activeLiveControlAppName: String?` model exactly one session | Convert to a collection keyed by visible app id | **High** — touches the ~142-reference central arbiter in `MixerViewModel` |
| B | Resolution is single-lane — `HelperAudioTargetResolver` rejects a second concurrent resolution (`beginResolution`), and probing uses one shared probe | Queue resolution requests; surface a per-row "queued" state | Medium |
| C | Mutual-exclusion guards block a second product session ("Stop the active live control first") | Relax for live sessions while keeping resolution serialized | Medium |
| D | Diagnostics-display coupling — product drives the single `advancedProcessTapDiagnostics` result/progress surface | Give product its own per-row state instead of the shared Advanced surface | Medium (the coupling flagged in the coordinator reassessment) |
| E | Lifecycle is not per-session — output change / app exit / termination tear down *the* session | Map an exited app id to its session; selective stop (the manager has `stopAll`, needs selective product use) | Medium |
| F | App wiring uses `init(controller:)` (maxSessions=1) | Switch to `init(maxSessions: 2, controllerFactory:)` | Low (one line, but triggers A–E) |
| G | Resource reality — 2× independent `AudioQueue` + aggregate device; sustained (hours), sleep/wake, and N>2 CPU/latency are unmeasured | Characterization evidence | **Gating** |

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
resolves, instead of being rejected.

**Phase 3 — Flip to maxSessions = 2.** Wire `init(maxSessions: 2, controllerFactory:)`,
relax the mutual-exclusion guard to allow a second product session, route per-app gain via
session ids. **Two only, first.**

**Phase 4 — Per-session lifecycle.** Tear down app-exit / output-change / termination per
session rather than globally.

**Phase 5 — N > 2.** Raise the cap as evidence allows, toward the full mixer.

## Recommended order

Start with **Phase 0** (sustained characterization): low risk, produces the gating evidence,
unblocks the rest. In parallel, a read-only boundary plan for **Phase 1** can be drafted
since it is the highest-risk refactor.

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

1. **State model collection (do first, lowest risk).** Add `activeSessionsByAppID`; make
   `activeSession`/`activeVisibleAppID` computed from it; `beginSession` inserts,
   `clearActiveSession` clears all, add `clearSession(for:)`. Extend
   `ProductRealControlStateTests`.
2. **VM consumers loop over all active app ids.** `stopRealControlForExitedTargetApps` and
   the exit/teardown checks iterate `activeVisibleAppIDs` instead of the single
   `activeVisibleAppID`. Still ≤1, so identical behavior; positions the code for N.
3. **Per-app diagnostics scaffolding.** Introduce `processTapLiveDiagnosticsByAppID` backed
   by ≤1 entry; keep the existing single `@Published processTapLiveDiagnostics` as a derived
   "first" so the Advanced display is untouched until Phase 3.
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
</content>
