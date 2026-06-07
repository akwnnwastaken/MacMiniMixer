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
</content>
