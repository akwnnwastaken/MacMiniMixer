# MacMiniMixer — Architecture Decision Log

Concise record of significant architecture decisions: why the current approach was
chosen, what was ruled out, and what conditions would change the decision.

---

## Why no HAL driver / kernel extension

**Decision**: The app uses only user-space public APIs (Core Audio, AudioToolbox,
AppKit). No HAL plug-in, no system extension, no kernel extension is installed.

**Reasoning**:
- HAL plug-ins require installer/uninstaller work and elevated privileges.
- A persistent virtual audio device would survive app crashes or force-quits, leaving
  the user's audio routing broken without a way to recover unless they know to reinstall.
- The Process Tap API (macOS 14.2+) allows capturing per-process audio in user space
  without any driver. This is simpler to reason about and to clean up.
- Development, debugging, and open-source distribution are all easier without a driver.

**Would revisit if**: Process Tap proves fundamentally insufficient for the use case —
specifically if low-latency multi-app mixing requires tighter timing guarantees than
independent `AudioQueue` instances can provide. Background Music's architecture would
be studied before implementing this.

---

## Why no persistent virtual audio device

**Decision**: `ProcessTapResourceContext` creates a private aggregate device
(`kAudioAggregateDeviceIsPrivateKey: true`) that exists only for the duration of one
session and is destroyed in `cleanup()`.

**Reasoning**:
- A persistent virtual device would appear in Audio MIDI Setup and could confuse users.
- If the app crashes before cleanup, a persistent device would remain and affect the
  system's audio routing.
- Private temporary devices are invisible to other apps and the system audio device list.
- The current architecture has a clean invariant: when the app is not running, no audio
  devices or resources exist that it created.

**Would revisit if**: A HAL plug-in approach is adopted for the centralized mixer path.

---

## Why no private APIs

**Decision**: Only public Core Audio, AudioToolbox, AppKit, and AVFoundation APIs are used.

**Reasoning**:
- Private APIs can change or disappear in any macOS update without notice.
- Using them would require reverse engineering, increasing maintenance burden.
- The public `AudioHardwareCreateProcessTap` / `CATapDescription` API, introduced in
  macOS 14.2, is sufficient for all current use cases.
- An open-source project built on private APIs would be fragile and harder to maintain.

**Grey area (per-app process attribution, `6d1d265`)**: to tell Safari's processes from a Safari web
app's (and Chrome's from Chrome PWAs'/Canary's), the app reads each process's resource coalition id
with the public libproc function `proc_pidinfo` and the flavor `PROC_PIDCOALITIONINFO` (20). The
function is public, but the flavor number and the `proc_pidcoalitioninfo` struct (and
`COALITION_TYPE_RESOURCE`) are defined only in XNU's private headers
(`bsd/sys/proc_info_private.h`, `osfmk/mach/coalition.h`), so the SDK does not expose them and the raw
values are mirrored in `SystemProcessLister` (checked against the XNU sources, not against Apple
documentation). It is accepted because it is read-only, needs no entitlement, and degrades safely: a
failed or short read, or id 0, means "unknown", and `AppAudioProcessMatcher` then falls back to its
bundle-id rules (less precise: they cannot separate sibling apps as reliably). If the flavor ever stops
working, attribution gets worse; nothing breaks. **Would revisit if**: Apple documents a public way
to ask which app a helper process belongs to, or the flavor changes.

---

## Why helper discovery is user-triggered

**Decision**: No background scanning for helper processes happens automatically. The user
must click "Scan" in Advanced Helper Process Discovery, or interact with a browser row
while global Real App Control is ON.

**Reasoning**:
- Scanning running processes and probing them with short audio taps has a measurable
  effect: it creates and destroys Core Audio resources, briefly suppresses audio on
  the probed process if the mute-behavior probe is used (diagnostics use unmuted probes).
- Automatic background scanning would be surprising and potentially disruptive.
- Helper PIDs are not stable — scanning once and caching the result without validation
  would lead to stale data. The current validation-first cache is an acceptable middle
  ground: reuse the cached mapping if the PID is still alive and tap-eligible.
- Explicitly user-triggered discovery makes the app's behavior predictable and auditable.

**Would revisit if**: A reliable heuristic for "is this browser tab currently playing
audio" can be built without intrusive probing, allowing the app to lazily refresh helper
mappings only when needed.

---

## Why main product remains one active session

> **Superseded:** Product Real now has no app-count limit — see "Why there is no Product Real
> app-count limit (owner decision)" below.

> **Update (Phase 3):** Superseded — the product cap was raised to two. After Phase 0
> sustained characterization (two simultaneous sessions for 5 minutes at 0 drops, 0 failures,
> stable CPU) and the incremental Phase 1–3 refactor, `maxConcurrentLiveSessions` is now 2 and
> two-app control is manually validated on real hardware. The original single-session
> reasoning below is kept for history. Growth beyond two (Phase 5) remains evidence-gated.

**Decision**: `ProcessTapLiveSessionManager` for the main product path has `maxSessions = 1`.

**Reasoning**:
- Two-App Readiness (10s diagnostic, `maxSessions = 2`) has shown that two simultaneous
  Process Tap sessions can run without drops in controlled conditions (e.g., Spotify +
  YouTube helper at 50% gain, ~928–932 callbacks, 0 drops).
- However, "works in a 10-second diagnostic" is not the same as "stable for indefinite
  production use". CPU impact, latency accumulation, and buffer timing across independent
  `AudioQueue` instances under real-world conditions have not been characterized.
- Limiting to one active session keeps the main product behavior simple and well-understood.
- Multi-app control can be added incrementally once the one-app path is thoroughly validated.

**Would revisit if**: Two-App Readiness tests consistently show zero drops and stable
latency across a range of app combinations and macOS versions.

---

## Why the session cap is 3 (and N>3 is deferred)

> **Superseded:** the cap was removed by owner decision (`maxConcurrentLiveSessions = nil`) — see
> "Why there is no Product Real app-count limit (owner decision)" below. The measurements here are
> still the only real-hardware multi-session evidence.

> **Update (Phase 5a):** the cap was raised from 2 to 3 after a three-session real-hardware
> smoke passed (see below). The original cap=2 reasoning and measurements are kept for history;
> the same deferral logic now applies to N>3 rather than N>2.

**Decision**: `maxConcurrentLiveSessions` is 3. Release CPU profiling cleared CPU as a blocker
for two and then three simultaneous sessions, but raising the cap beyond 3 (`N > 3`) remains
deferred to a dedicated plan.

**What was measured — cap=2 gate** (Instruments Time Profiler + Activity Monitor, one real Mac,
M4 Pro, Release, short 1–3 min runs):
- Idle ≈ 0% CPU; one direct session ≈ 7.1%; two direct ≈ 12.2%; direct + helper ≈ 13.6%.
- Two-session ≈ 1.7× the single-session cost (below 2× — no scaling red flag).
- Memory ~54–58 MB and 13–16 threads were stable; CPU returns to ~0% within ~6–7 s after stop;
  no drops/failures/cleanup warnings; thermal nominal. `%100` ≈ one full core, so ~12–14% is a
  small fraction of one core.
- The **relative** cost centre is the Main Thread / SwiftUI / AppKit (diagnostics publication +
  UI), not the audio callback path (per-sample peak/RMS, buffer copy, AudioQueue), which
  measured low. Earlier Debug (`-Onone`) figures (~50–80%) were **not** representative.

**What was measured — cap=3 smoke** (one real Mac, M4 Pro, Release; two direct + one helper,
panel mostly closed):
- Measured CPU was approximately 19% in Release profile — within the expected ~17–25% PASS band
  for three sessions, and a reasonable scale-up from cap=2. Memory ≈ 59 MB, ~16 threads, thermal
  nominal. Instruments still showed Main/SwiftUI/AppKit as the relative cost centre and the audio
  path (IOThread/AQConverter) low — not a red flag.
- The banner correctly summarised three apps (first two names + "+1 more", "Stop All").
- Per-app stop left the other two sessions running with no audio disruption; Stop All, repeated
  start/stop, and an output-device change all torn down cleanly with no drops/failures/cleanup
  warnings and CPU returning to ~0%.

**Reasoning**:
- The cap=3 *performance* gate is considered passed for the current scope, so the audio path
  does not need a large refactor (e.g. vDSP) right now.
- If optimization is ever pursued, Release profiling points at reducing MainActor/SwiftUI
  publication **before** any audio-buffer/vDSP work. (Update: the "10 Hz" figure is stale. The
  controller's diagnostics *timer* still ticks at 10 Hz, but since `e95bcd0` a per-session
  `ProcessTapDiagnosticsPublishGate` limits each session's publishes to ~4 Hz, and since `5a78656`
  only the focused session publishes, and only while the Advanced section is visible — see the
  entry on live diagnostics below.)
- N > 3 is **not** a configuration change: each extra session is another tap + private
  aggregate device + `AudioQueue`, and needs the still-single-lane resolver promoted to a real
  queue (multi-helper UX), N-session Core Audio resource-scale evidence, N-row UI/banner
  behaviour, repeated-teardown safety at scale, the still-open real-hardware orphan-tap repro,
  AudioQueue underrun/jitter measurement (the `drops==0` counter does not cover
  starvation/jitter), and sustained long-run characterization.

**Caveat**: measured on one machine, short smoke runs. It is not a proof for all hardware,
hours-long runs, or N > 3.

**Would revisit if**: a dedicated plan establishes the resource/UI/cleanup story above and
repeated long-run characterization stays clean — then the cap can rise past 3 incrementally.

---

## Why callback jitter / output starvation are diagnostic-only and Late > 0 is not a failure

**Decision**: The Phase 6c callback-jitter (`maxCallbackGapMilliseconds`, `lateCallbackCount`)
and output-starvation (`outputStarvationCount`) signals are **diagnostic-only**: they appear in
the Advanced live diagnostics card and the stop-result detail, never on the normal user banner,
and they do **not** change cap, session, stop, or cleanup behaviour. A non-zero `Late` or a
70–133 ms `maxGap` is **not** automatically a failure.

**Reasoning**:
- These counters exist to close a measurement gap: `drops == 0` only means the output buffer
  pool was never empty; it does not see callback scheduling jitter or the AudioQueue draining.
  They are a *signal to investigate*, not a verdict.
- The "late" threshold (50 ms) is a deliberately coarse absolute bound, not derived from the
  exact per-callback frame interval, so a single late callback or a short gap spike is expected
  noise — it can come from a brief scheduling stall, the panel being open, the moment around
  stop, or a helper input pause (which also drains the queue). The pass/fail gate is **audible
  glitch and clean stop**, not the raw counter values. A three-session smoke with `Starv 0`,
  `Drops 0`, `Fail 0`, `Late 1`, `maxGap` ~70–133 ms and no audible glitch is a PASS.
- Output starvation has a known false-positive: a genuine input pause drains the queue too, so
  `Starv > 0` means "the queue ran dry; check for an audible glitch", not "definite underrun".

**Why panel-open CPU does not invalidate the panel-closed Release numbers**: with the panel open
the live Advanced diagnostics view redraws continuously (panel closed ≈ 25%, panel open /
Advanced closed ≈ 39%, panel open / Advanced open ≈ 55% in Release for three sessions). The
product's steady state is **panel closed**, so the cap=3 performance gate is judged on the
panel-closed number; the panel-open cost is a UI rendering cost, not an audio-path cost.

**Why a UI publication throttle is future work, not a blocker**: the relative cost centre is
Main Thread / SwiftUI / AppKit, so the right optimization is reducing diagnostics publication —
**before** any audio-buffer work. CPU was low enough at cap=3 that this was not required.
(Update: the "10 Hz" wording is stale. The controller's diagnostics timer still ticks at 10 Hz,
but since `e95bcd0` a per-session publish gate limits each session's publishes to ~4 Hz. With the
cap removed, `5a78656` added the remaining gating: only the focused session publishes, and only
while the Advanced section is visible. The panel-open CPU numbers above predate both changes and
have not been re-measured.)

**Would revisit if**: real-hardware runs show `Starv`/`Late` rising *together with* an audible
glitch (then the counters have found a real defect and the audio path needs work), or if
panel-open CPU becomes a usability problem (then the publication throttle is promoted from
future work to a task).

---

## Why Product Real teardown and starvation are hardened the way they are (P177–P182)

**Decision**: The Product Real teardown/starvation path was hardened by a sequence of small,
targeted changes (commit `88bbed5`) rather than a broad audio-path rewrite. Each addresses a
specific real-hardware failure mode while leaving the audio callback effectively untouched and
the session cap at 3.

**Reasoning** (one line per change):
- **Retry + fault-report process-tap destruction (P177)**: live taps carry `.mutedWhenTapped`, so
  a destroy that silently fails leaves the tapped apps muted inside coreaudiod until the app or
  coreaudiod restarts. A transient destroy failure during route settling must be retried, and a
  persistent one surfaced as a fault — never swallowed as a clean stop.
- **Dispose the output queue after IOProc stop/destroy (P178)**: disposing the queue while the
  IOProc can still enqueue produces self-inflicted Drops/Fail during teardown. Ordering the
  dispose after the producer is gone removes that spike. (This applies to the legacy `AudioQueue`
  path; the default direct output path has no queue and instead waits, bounded, for the IOProc to
  render its fade-out before stopping IO.)
- **Serialize Product Real Core Audio lifecycle operations (P181)**: each session owns a private
  aggregate device wrapping a tap; creating/destroying one churns the shared coreaudiod route.
  Overlapping a teardown with another session's setup compounded the churn and starved a
  still-active session (audible clicks on combination change). Serializing create/destroy makes
  coreaudiod see one route change at a time. This is not an audio-callback lock.
- **Gate Starv on observed real input (P180) and on startup warmup (P182)**: output starvation is
  an underrun *proxy* (queue fully drained). A queue draining before any real audio is the
  "waiting for app audio" idle state, and a fresh queue can drain once or twice while establishing
  cadence (seen after a per-app Real restart). Counting either would be a misleading false alarm,
  so both are excluded; a neutral status ("Waiting for app audio" / "Starting audio…") is shown
  instead, and steady-state starvation still counts.
- **Keep the settle gate before new starts (P179)**: a short stop→start settle lets coreaudiod
  release the previous session before a new tap/aggregate is created, avoiding nondeterministic
  startup starvation.

**Explicitly not done**: the session cap stays **3** (no N > 3), and the previously-tried
default-output-device observer was **not** reintroduced — it had caused system audio to stay
silent (surviving app quit, requiring `sudo killall coreaudiod`). Output-device-change teardown
stays on the existing consolidated path.

**Validated by**: a real-hardware retest (one Mac) — the combination-change and per-app-restart
cases came back clean with no `coreaudiod` restart required — and a **30–60 min three-session
long-run smoke that PASSED for normal use** (`Drops`/`Fail`/`Starv` 0, CPU ~20–35% depending on
panel state, no `coreaudiod` restart, output usable throughout). See ROADMAP "Product Real
teardown/starvation hardening" and checklist §16.5 / §17.

**Known caveat (not a v0.14 blocker)**: *extremely* rapid repeated Real on/off toggling can
eventually overwhelm the settle (P179) and lifecycle-serialization (P181) gates and produce
crackle/`Starv`. The gates space and serialize one create/destroy at a time; a fast enough manual
toggle burst still queues route churn faster than coreaudiod settles. This is deliberately out of
scope for v0.14 because the intended flow is Real Control staying **enabled during use**, not rapid
manual toggling. The fix, if it becomes necessary, is a **UI-level** guard (debounce the toggle /
disable it while a Product Real lifecycle operation is in flight), tracked as a v0.15 candidate — it
would not change cap=3, the audio callback, or these gates, and keeps N > 3 deferred. *(Update: that
guard is implemented — see "Why rapid Product Real toggles are guarded at the UI / view-model
level" below; the cap has since been removed by owner decision.)*

**Would revisit if**: a real underrun is ever masked (an audible glitch with `Starv 0` after the
warmup window — then the warmup threshold `processTapReplayStartupWarmupBufferCount` is too high),
the long-run reveals accumulating starvation or leaks over time, or rapid-toggle crackle starts
affecting normal use (then promote the v0.15 UI debounce/pending-state guard).

---

## Why rapid Product Real toggles are guarded at the UI / view-model level

**Decision**: Rapid Real on/off toggle spam is stopped **before** it reaches Core Audio, by a
per-app pending-operation guard in the view model — not by making every click reach the Process Tap
create/destroy path and relying only on the settle/lifecycle gates to absorb it.

**Reasoning**:
- The settle (P179) and lifecycle-serialization (P181) gates make Core Audio *do one thing at a
  time and settle between them*, but they do **not** limit how many operations a user can *queue*.
  A fast enough on/off/on/off burst still enqueues more create/destroy work than coreaudiod can
  settle, which is what produced the residual crackle/`Starv` under aggressive toggling.
- The cheapest and safest place to cut that off is at the source: `ProductRealControlState` tracks
  which rows have a start/stop transition in flight (`pendingOperationAppIDs`), and `MixerViewModel`
  ignores toggle and slider auto-start attempts for a row while its operation is pending. The row
  shows a non-interactive "working" badge so the state is visible. The flag is cleared in each
  operation's terminal handler (start completion / stop callback) and on every global teardown
  (including the synchronous `stopLiveControlNow` path, which does not fire per-session callbacks).
- This is **layered protection above** the existing gates, not a replacement for them: at most one
  operation per row is ever in flight, so the gates only ever see spaced, non-spammed work.
- The **audio callback is untouched**, cap stays **3**, and `N > 3` stays deferred — this is pure
  UI/orchestration state.
- A deliberate consequence: a toggle can no longer cancel an in-flight start mid-flight (the start
  completes first, then the row can be stopped). This matches the intended flow — Real Control
  stays enabled during use — and is preferable to letting a cancel re-open the churn window.

**Would revisit if**: real-device stress testing shows the guard is insufficient (then add a short
debounce interval on top), or if users need to abort a slow start (then allow a single cancel while
still blocking repeats).

---

## Why system wake is refresh-only (no automatic session restart)

**Decision**: On `NSWorkspace.willSleepNotification` the app synchronously tears down every
active and pending Process Tap audio work item — Product Real Control sessions, Advanced
manual live control, Two-App Readiness, and the related diagnostic/probe/resolver work —
invalidating pending Product start-request tokens and the in-memory helper cache. On
`NSWorkspace.didWakeNotification` it does **refresh-only** reconciliation — re-reads output
devices, the default-device selection, system volume/mute, and the visible app list — and
deliberately does **not** restart any session or re-resolve any helper.

**Reasoning**:
- After sleep, the state the sessions were built on may have moved: the tap can be stale, a
  resolved helper PID may now belong to a different (or dead) process, and the default output
  device may have changed. Restarting blindly would tap the wrong process or fight a
  device-change teardown.
- Tearing everything down at sleep, then only refreshing at wake, keeps a clean invariant:
  after wake nothing is running, so the existing output-device-change and app-refresh paths
  reconcile state without spurious "output changed" warnings or restart loops.
- The pending-start guards already in place (request-token invalidation + session-ID-keyed
  teardown) mean any start that lands mid-sleep is rejected as stale and its orphan engine
  session is torn down by id — no resurrection.
- The global Real App Control opt-in is a user *preference*, not session state, so it is left
  ON across sleep/wake; the sessions are simply not restored. The user re-engages by touching
  a row slider again, which starts a fresh, freshly-resolved session.
- The sleep/wake observers are owned by the app-lifetime `MixerViewModel` (alongside the
  existing termination observer), not the menu-bar panel, so the teardown happens whether or
  not the panel is open during sleep/wake.

**Validated**: a basic real-hardware sleep/wake smoke test passed, and the fake-backed suite
covers both the sleep teardown and the wake refresh-only behavior. Longer-duration, repeated,
and varied output-device / helper-PID-replacement sleep/wake characterization is still open
(see ROADMAP "Sleep/wake and long-running resource characterization").

**Would revisit if**: automatic post-wake restart/recovery is investigated and shown safe —
i.e. a session can be re-validated (tap still eligible, helper PID still the right process,
output device unchanged or re-resolved) before any audio is re-engaged, without restart-loop
risk. That research is deferred; refresh-only is the conservative default until then.

---

## Why Advanced diagnostics are separated from the main UI

**Decision**: Process Tap Test, Replay Probe, Two-App Readiness, and Helper Process
Discovery are in a collapsed "Advanced" section, hidden by default.

**Reasoning**:
- These features are experimental, user-triggered, and carry audio side effects (muting
  the selected app during mute-probe, suppressing and replaying audio during Replay Probe
  and Live Control).
- Casual users who just want to switch output or adjust system volume should not encounter
  these controls.
- Collapsing them reduces the visual complexity of the normal mixer workflow.
- Advanced diagnostics are genuinely useful for evaluating whether per-app control is
  feasible on a given system configuration.

---

## Why helper PID mappings are not persisted across launches

**Decision**: `HelperAudioTargetResolver.cachedHelpersByKey` is an in-memory dictionary,
not persisted to disk.

**Reasoning**:
- Helper PIDs are volatile: they change on browser restart, tab reload, or even
  navigation within the same tab (especially with WebKit's multi-process model).
- A PID stored on one launch may refer to a completely unrelated process on the next
  launch, since macOS reuses PIDs.
- Persisting stale PID mappings and using them without live validation would cause the
  app to tap the wrong process.
- The current validation-first in-memory cache strikes the right balance: reuse within a
  session (with live validation), throw away across sessions.

**Would revisit if**: A stable, app-level (not PID-level) identifier for the audio helper
process is discovered (e.g., bundle ID + consistent process name pattern), enabling
cross-launch caching of the helper process name without relying on PID stability.

---

## Why Replay and Live OutputQueues are not unified yet

**Decision**: `ProcessTapLiveOutputQueue` and `ProcessTapReplayOutputQueue` are separate
structs with duplicated buffer pool + copy logic.

**Reasoning**:
- The live queue has lazy start (waits for `processTapLivePrimingBufferCount` enqueues),
  a gain ramp (fade-in/fade-out), and a `beginFadeOut()` lifecycle step.
- The replay queue starts eagerly and uses a constant gain scalar.
- These behavioral differences are subtle but critical for audio quality. Merging them
  prematurely could introduce a regression in one path while fixing the other.
- The shared logic (`ProcessTapOutputBufferCopier`) has already been extracted and tested.
- A unified queue abstraction would need careful design to preserve both behaviors without
  adding conditional branches in the hot audio callback path.

**Would revisit if**: Both paths have been validated through manual audio regression
testing across multiple macOS versions, and the behavioral delta between them is clearly
understood and can be expressed as a clean configuration struct.

> **Superseded in part (direct output engine, `377f1a8`).** The live `AudioQueue` is no longer the
> default live output: Product Real and Advanced live control now render through one aggregate IOProc
> (see "Why live output renders straight to the device through one aggregate IOProc"). So the
> "`ProcessTapLiveOutputQueue` is the audio callback path, do not change it casually" guidance
> (also in `docs/QUICK_START_FOR_AGENTS.md`) now applies to the **direct renderer and its IOProc**
> (`ProcessTapDirectOutputRenderer`, `ProcessTapDirectOutputCopier`, `ProcessTapDirectOutputResampler`).
> The live queue is a **legacy fallback** (moved to `ProcessTapLegacyAudioQueueOutput.swift`) and is
> scheduled for removal rather than for unification with the Replay queue; the Replay Probe keeps its
> own `AudioQueue`. Until the legacy path is removed, treat it as frozen: fix only what a regression
> in the fallback needs.

---

## Why `MixerViewModel` is being split incrementally

**Decision**: `MixerViewModel` remains the central `@MainActor` traffic controller, but
self-contained subsystems are being extracted one coordinator at a time.

**Reasoning**:
- The initial monolithic model made cross-feature cleanup easy to audit while Process Tap
  behavior was changing quickly.
- Several boundaries are now stable enough to extract safely:
  `AdvancedHelperDiscoveryCoordinator`, `SystemOutputCoordinator`,
  `AdvancedProcessTapDiagnosticsCoordinator`, `AdvancedLiveControlCoordinator`, and
  `TwoAppReadinessCoordinator`.
- Product Real App Control remains intentionally centralized because it combines direct
  visible-PID control, browser/helper resolution, cache invalidation, one-active-session
  rules, row slider/mute behavior, timeout handling, app/helper exit handling, output
  device cleanup, and menu bar/banner state.
- Two-App Readiness orchestration moved into a coordinator after fake-backed
  characterization tests covered target selection, helper-target use, start/stop,
  completion, output-change stop, and selection repair behavior.

**Would revisit**: Continue the split in small steps. Product Real App Control should only
move after a read-only boundary plan and more characterization tests confirm the safest
interface. *(Update: that happened — see the next entry; Product Real now lives behind the
`ProductRealControlCoordinator` facade.)*

---

## `ProductRealControlCoordinator`: deferred, then extracted in stages

**Status**: The original decision here was **defer** (keep orchestration in `MixerViewModel`).
That was later **superseded**: both the **start path** and the **stop path** were extracted into
`ProductRealControlCoordinator` in small, independently-tested steps. The reasoning below is
retained because it explains *why the move had to be staged behind a seam* rather than done as one
refactor, and what is still intentionally left in the view model.

**What moved (staged, one reviewable commit each)**:
1. **Seam first** — introduced the narrow `ProductRealControlSideEffects` (write/callback side) and
   `ProductRealControlContext` (read side) protocols; `MixerViewModel` conforms and routes its
   Product Real status/name/diagnostics writes and guard reads through them. No logic moved.
2. **Pure decision helpers** — `shouldAcceptCallback` (stale-callback acceptance) and
   `wouldExceedConcurrentSessionCap` (the cap decision) moved onto `ProductRealControlState`.
3. **State ownership** — the coordinator now owns `ProductRealControlState`; the view model reaches
   it through a get/set forwarding property, and the coordinator forwards change notifications to
   `objectWillChange` via `setOnWillChange` (replacing the old `@Published`).
4. **Stale-start cleanup leaf** — `cleanupStaleProductLiveStart` moved to the coordinator.
5. **Resolution slice** — the app-audio resolution task, `startResolvedExperimentalControl`,
   `handleAppAudioTargetResolution`, `cancelAppAudioTargetResolution`, and the
   `productSessionStartBlockReason` preflight moved to the coordinator.
6. **Async start body** — both `startExperimentalControl` overloads moved to the coordinator; the
   engine `onStopped` callback was initially routed back to the view model's
   `handleProductLiveControlStopped` through the seam.

**Then the stop path (Prompts 215–218), same one-slice-per-commit discipline:**

7. **Per-app stop leaf** — `stopExperimentalControl(for:reason:)` moved to the coordinator; its two
   VM callers (`toggleExperimentalControl` stop branch, `stopRealControlForExitedTargetApps`)
   delegate. No new seam needed.
8. **Stop All core + engine stop callback** — `stopProductLiveSessions(reason:)` and
   `handleProductLiveControlStopped(...)` moved. The `onStopped` routing member was **replaced**: the
   coordinator now handles `onStopped` locally, and the seam gained a narrow
   `applyLiveControlStoppedDisplay(result:diagnostics:)` callback so the coordinator can trigger the
   **shared** VM display cleanup (used by advanced-manual stop too). A `processTapLiveDiagnostics`
   context read was added for the Stop All no-active-session path. The former
   `handleProductLiveControlStopped` seam member was removed (no dead seam API).
9. **App-exit slice** — `stopRealControlForExitedTargetApps()` moved; `refreshApplications`
   delegates only that slice.
10. **Hard-teardown Product Real state reset** — only the Product Real state-reset **sub-block** of
    `tearDownAllProcessTapWork` moved into `tearDownProductStateForHardStop()`. Exact teardown
    ordering was preserved by moving *only* the contiguous state-reset lines: the engine hard stop,
    two-app readiness, helper/probe, resolver invalidation, diagnostics/replay cleanup,
    advanced-manual reset, and the earlier-positioned `cancelResolutionTask()` all stay in the view
    model at their existing positions (folding `cancelResolutionTask()` into the moved block would
    have reordered it relative to the non-product steps, so it was deliberately left where it is).

**Still in `MixerViewModel` (intentionally — the view model is the cross-subsystem router and
lifecycle/UI orchestration layer, and these responsibilities are not product-only)**: the row
`toggleExperimentalControl` entry point, the `stopProcessTapLiveControl` **product-vs-advanced-manual
router**, `handleAdvancedManualLiveControlStopped`, the **shared** `applyLiveControlStoppedDisplay` /
`showLiveControlWarningIfNeeded` display cleanup (reached from the coordinator through the seam), and
all lifecycle / sleep / wake / termination / output-device-change teardown **fan-out**
(`tearDownAllProcessTapWork`, `stopActiveAudioWorkForOutputDeviceChange`). Moving any of these into a
product-scoped coordinator would pull non-product concerns across the seam and *increase* coupling —
the shared display helper serves advanced-manual stop, the router arbitrates between product and
advanced-manual, and the fan-outs sequence five-plus subsystems — so they stay in the view model by
design.

### Internal split into sub-coordinators (Prompts 222–228) — complete

After the start + stop paths were extracted, `ProductRealControlCoordinator` had grown to ~640 lines.
Prompt 222 designed an **internal** split into cohesive sub-objects **behind the unchanged facade**
(so `MixerViewModel` still knows only `ProductRealControlCoordinator`). It is now **complete**: the
facade composes `ProductRealControlStateStore` + `ProductRealStartCoordinator` +
`ProductRealStopCoordinator`, and is itself down to ~170 lines. Key decisions:

- **Resolution stays inside Start** (not a separate `ProductRealResolutionCoordinator`). Resolution
  and Start are **bidirectionally coupled**: resolution calls the start body to launch, and the start
  body's cached-helper-failure path re-enters resolution (`startResolvedExperimentalControl(...,
  allowsCachedLookup: false)`); they also share the per-app start-request tokens carried in
  `ProductRealControlState`. Splitting them would introduce a hard cycle for little benefit (together
  they are the bulk of the code), so `ProductRealStartCoordinator` keeps both.

- **State moved to a dedicated reference store** (`ProductRealControlStateStore`), chosen over
  "facade owns state + closures" or "one sub-coordinator owns state, siblings call in", and over
  copying the value type. A single shared **reference** store is the only option that preserves one
  source of truth *and* exact `onWillChange`-once-per-write semantics while letting multiple
  sub-coordinators mutate the same state — copies would diverge and resurrect superseded sessions
  (stale-callback acceptance and pending-operation flags both depend on a single shared mutable
  source). There is **exactly one** production instance, constructed by the facade and passed by
  reference.

- **Stop was extracted before Start** (into `ProductRealStopCoordinator`, Prompt 224; Start followed
  in Prompt 227). Stop is the smaller, more self-contained unit (~200 lines: the five stop methods +
  the shared active-name helper), so it isolates cleanly first and de-risks the larger Start
  extraction. The state store (`ProductRealControlStateStore`) was extracted first of all
  (foundational, zero cross-edges, everything else references it).

- **Cross-edges are narrow closures, not sibling ownership.** After the full split there are exactly
  three Start↔Stop edges: start `onStopped` → stop's `handleProductLiveControlStopped`, start's
  active-name refresh → stop's `updateActiveLiveControlAppNameAfterProductChange`, and stop's app-exit
  → start's `cancelAppAudioTargetResolution`. Giving either sub-coordinator a direct reference to the
  other would create a mutual ownership cycle and couple their lifecycles. Instead the facade (which
  owns both) wires **all three** as `@MainActor` `[weak self]` closures via post-init setters
  (`setOnEngineStopped` / `setRefreshActiveName` on Start, `setCancelResolution` on Stop) — installed
  after both sub-coordinators exist, so nothing captures `self` before init completes and the
  facade → sub-coordinator → closure → facade chain stays cycle-free. The active-name algorithm lives
  only on Stop; Start routes to it rather than duplicating it.

- **Prompts 223 and 224 landed as one combined commit (`7af8b2f`).** Prompt 223 (the state store)
  was reviewed but **not committed** before Prompt 224 (the stop coordinator) began, so the
  `ProductRealControlCoordinator.swift` and `project.pbxproj` diffs interleaved both prompts'
  changes. Rather than reconstruct an artificial split with `git add -p`, `reset`/`restore`, temporary
  patches, or history rewriting, they were committed together as one reviewed architectural commit.
  **History was not rewritten or artificially split.**

- **The facade initializer signature was preserved.** The whole split had to keep `MixerViewModel`
  unchanged, and the VM constructs the facade with a fixed argument list. So the facade keeps accepting
  the same six dependencies (`liveSessionManager`, `appAudioTargetResolver`, `startSettleGate`,
  `processTapEligibility`, `sideEffects`, `context`) even though it no longer stores them — it threads
  them straight into the two sub-coordinator constructors. Changing the signature would have forced a
  VM edit, which the plan explicitly forbade.

- **Redundant facade stored dependencies were removed only *after* the extractions** (Prompt 228, the
  facade-slimming step), not during them. While start/stop logic still lived in the facade those
  properties had real runtime reads; only once every start/stop method had moved did they become
  provably write-only (assigned in `init`, never read — the sub-coordinator constructions use the init
  *parameters*, which shadow the properties). Removing them earlier would have broken compilation or
  hidden a real read; removing them as a final, isolated, behavior-preserving cleanup kept each step
  reviewable. The unused `import AppKit` (whose only user, `NSRunningApplication`, moved to Start) was
  dropped in the same step.

- **`MixerViewModel` intentionally stayed byte-for-byte unchanged** through all four code steps
  (state store, Stop, Start, facade slimming). The facade is the single seam the VM depends on;
  keeping its public API and initializer fixed meant the entire internal restructuring was invisible to
  the VM and to the unchanged `MixerViewModelLiveControlTests` — the strongest possible guarantee that
  behavior was preserved.

- **The Product Real structural refactor should now stop.** The facade/store/start/stop boundary is
  cohesive and complete; the facade has no implementation logic left to extract, and the remaining
  `MixerViewModel` responsibilities (router, shared display/status, lifecycle entry points,
  multi-subsystem fan-out) are genuinely cross-subsystem — pulling them into a *product* coordinator
  would increase coupling. Further decomposition, if any, belongs to their *own* focused types and only
  after a separate read-only reassessment; there is no concrete defect that justifies more Product Real
  splitting.

**Why staged instead of one large refactor**: the original reassessment (below) measured ~142
references and four shared `@Published` properties, and concluded a single-shot extraction would
raise coupling. The seam-first, one-slice-per-commit approach neutralized exactly those risks —
each step stayed behind the ~30 `MixerViewModelLiveControlTests` (unchanged, always green) plus
new coordinator-level tests, so a regression would surface at the smallest possible step. The
change-notification concern was solved by `onWillChange`; the Advanced-diagnostics display coupling
was solved by routing those writes through the seam rather than a hard coordinator-to-coordinator
dependency.

### Original deferral rationale (retained for context)

**What was measured**: ~142 references in `MixerViewModel` touch the Product Real Control
cluster (`productRealControlState`, `isProcessTapLiveControlActive`,
`activeLiveControlAppName`, `processTapLiveDiagnostics`, the `advancedProcessTapDiagnostics`
coordinator, `appAudioTargetResolver`, and `showStatus`).

**Reasoning (why it is different from the coordinators already extracted)**:
- The five extracted coordinators each own a *self-contained* slice of state and report back
  through a single `onWillChange` callback. Product Real Control is the opposite: it is the
  central arbiter that mutates four `@Published` properties the SwiftUI panel binds to
  (`isProcessTapLiveControlActive`, `activeLiveControlAppName`, `processTapLiveDiagnostics`,
  and the active session in `productRealControlState`).
- Those same `@Published` properties are read by *other* `MixerViewModel` logic
  (output-device-change teardown, app-refresh teardown). Moving them into a coordinator would
  force either duplication or extra callback threading — likely a net increase in complexity.
- Product Real Control drives the **Advanced diagnostics display** (`setResult`,
  `setProgress`, `setRunning` on `AdvancedProcessTapDiagnosticsCoordinator`). A new
  coordinator would need a hard dependency on another coordinator, a coupling the codebase
  has deliberately minimized.
- Start/guard logic reads the running state of five other subsystems (Two-App Readiness,
  Process Tap testing, helper probe, auto-detect, app-audio resolution) for mutual
  exclusion. A coordinator would need all of them injected or passed per call.

**What was done instead (low-risk simplifications that fell out of the review)**:
- The live-control warning mapping moved to a pure, tested
  `ProcessTapTestResult.liveControlWarningMessage` computed property.
- The app-refresh teardown was split into named helpers
  (`stopRealControlForExitedTargetApps`, `refreshProcessTapSelectionAfterAppRefresh`).
- The output-device-change teardown was consolidated into
  `stopActiveAudioWorkForOutputDeviceChange`.
- The duplicated `beginSession` call (early optimistic set + post-`await` re-assertion) is
  intentional and is now documented inline rather than removed.

**Would revisit if**: the four shared `@Published` properties can be reduced to a single
observable session value, AND the dependency on `AdvancedProcessTapDiagnosticsCoordinator`
for display is broken (e.g. Product control gets its own result/progress surface). At that
point a narrow coordinator owning only the resolution + session lifecycle would be a clean,
low-risk extraction.

---

## Diagnostic tooling classification (sunset decision)

**Context**: The Advanced section carries a large diagnostic surface (Process Tap Test,
Mute Probe, Replay Probe, Two-App Readiness, Helper Discovery + Candidate Probe +
auto-detect). This decision classifies each so future cleanup is principled rather than
ad hoc.

**Stated product goal (from the maintainer)**: a true Windows-Volume-Mixer experience —
*simultaneous, independent per-app volume control for every app shown in the audio list*,
not just one or two at a time. This makes full multi-app Product Real Control the
north-star goal, not a deferred curiosity. The one-active-session limit of the time was the
*incremental* path toward it (see "Why main product remains one active session"); the product has
since gone to two, three, and then no app-count limit (see "Why there is no Product Real
app-count limit (owner decision)").

**Decision**: **Retain all diagnostic tooling for now.** Nothing is removed or debug-gated,
because every tool is on the critical path to the multi-app goal — either as evidence or as
a building-block diagnostic used while developing it. The value of this entry is the
classification and the sunset *triggers*, not removal.

**Classification**:
- **Permanent product engine (never sunset)** — the product depends on these directly:
  `ProcessTapLiveController` (live control), `AppAudioTargetResolver` (browser/helper
  resolution), and the probing it reuses internally (`ProcessTapCandidateAudioProbing`,
  `HelperProcessCandidateDiscovery`, see `AppAudioTargetResolving.swift`).
- **Evidence on the critical path (retain through multi-app development)** —
  **Two-App Readiness** (~1670 LOC across tester/view/coordinator) is the multi-session
  prototype that measures whether simultaneous sessions stay stable. It is the evidence base
  for the headline feature and must not be removed before multi-app ships.
- **Building-block diagnostics (retain; first sunset candidates after multi-app ships)** —
  Process Tap Test, Mute Probe, Replay Probe, and the manual Helper Discovery UI. These are
  the tools used to validate per-app tap-ability, muting, playback gain, and helper
  resolution during development.

**Sunset trigger**: once production multi-app control exists *and* is validated, re-evaluate
this list. Replay Probe and Mute Probe are the most likely to become redundant first (their
questions — "can captured audio be replayed at a gain?" / "does tap-muting work?" — are
answered once full multi live-control is proven). The manual Helper Discovery *UI* can then
be debug-gated while its *engine* stays (the product still needs it).

**Would revisit if**: the multi-app goal is ever abandoned — in that case Two-App Readiness
(~1670 LOC) becomes the single largest removal candidate.

---

## Why there is no Product Real app-count limit (owner decision)

**Decision** (`08d49bc`): Product Real Control has **no app-count limit**.
`AppConstants.maxConcurrentLiveSessions` is `Int? = nil`, the product `ProcessTapLiveSessionManager`
is built with `maxSessions: nil`, and the start preflight never blocks on the session count. This
supersedes "Why the session cap is 3 (and N>3 is deferred)" and "Why main product remains one
active session".

**Reasoning**:
- It is the owner's product decision: like the Windows Volume Mixer, every app the user interacts
  with (global "Real app control" ON) should be controllable at the same time. With a cap of 3, the
  fourth app the user touched simply refused, which contradicts the north-star goal.
- The engine already scaled per session: each session has its own controller, process tap, private
  aggregate device, IOProc, and (at that time; today only on the legacy fallback path) `AudioQueue`,
  and the manager and `ProductRealControlState` track sessions as collections. Nothing in the audio
  path depends on a count.
- Several of the "N > 3 needs…" items from the cap=3 entry were addressed in code around the
  decision: the banner summarizes any N ("first two +N more", full list in the accessibility label),
  quitting one app no longer stops other sessions (`da2b06e`), the cached-helper retry works next to
  other sessions (`c57bf37`), the resolver lane became a real queue (`774268a`), and the shared
  diagnostics surface no longer multiplies by N (`5a78656`).
- A failure for an extra session (for example Core Audio refusing another tap/aggregate) surfaces
  through the normal per-app start-failure path ("Could not start live control for this app"), not
  through a preemptive limit.
- The cap mechanism is kept and testable: `ProcessTapLiveSessionManager(maxSessions:)` still honours
  a non-nil value (clamped to at least 1); the start coordinator and facade take an injectable
  `maxConcurrentSessions: Int?`, and a configured cap still reports "Real app control supports N apps
  at a time". Tests pin both the unlimited default (6–8 sessions) and a configured cap.

**What it does not mean**:
- It is **not** evidence that many sessions are stable. Real-hardware measurements exist only for up
  to three sessions (one, two, and three sessions scaled roughly linearly in Release CPU: ~7%, ~12%,
  ~19%). Every Real app adds its own Core Audio objects and CPU. The remaining gates are hardware
  evidence — N-session characterization (e.g. 5–8 apps) — and the deferred many-session hardening:
  engine self-stops that bypass the lifecycle/settle gates, the main-thread hard teardown at
  sleep/quit, and the sequential Stop All.
- Real control stays opt-in: the global toggle is OFF by default and sessions start only on user
  interaction with a row.

**Would revisit if**: real-hardware N-session runs show resource exhaustion, orphaned mutes, or
audible degradation that cannot be fixed in the teardown/gating path. Then the **owner** decides
whether to reintroduce a (configurable) cap; agents should not reintroduce one on their own.

---

## Why Product Real starts are queued behind a single start lane

**Decision** (`774268a`): At most **one** Product Real helper resolution **or** product start is
physically in flight. A start requested meanwhile (slider/mute auto-start or row toggle, direct-PID
or helper row) is queued FIFO and drained when the lane frees, instead of being rejected.

**Context — there were two single lanes, not one**:
1. **The resolver lane.** Helper resolution handles one request at a time; a slider move on a second
   row during a resolution was rejected with "Finish resolving app audio first".
2. **The start lane.** Every product start set the shared Advanced "running" flag
   (`setLiveControlDiagnosticRunning(true)`) until its post-await block. While it was set,
   `isProcessTapTesting` was true, so `productSessionStartBlockReason` rejected every other product
   start with "Stop active live control first" — even direct-PID ones — and toggles hit "Process Tap
   is already busy".

With the app-count limit gone, moving several sliders in a row became the normal way to hit both. A
queue that only waited for `!isResolving` would immediately have hit the second rejection, so the
lane covers "a resolution **or** a product start".

**Why direct-PID starts queue too** (instead of running next to a resolution):
- The helper probe (`CoreAudioProcessTapCandidateAudioProbe`) creates and destroys its own process
  tap + private aggregate **outside** the Core Audio lifecycle gate (P181) and the stop→start settle
  gate (P179). A direct-PID start building its own tap/aggregate at the same time would bring back
  the overlapping route churn those gates exist to prevent.
- The shared Advanced result/progress/"running" surface assumes one start at a time.
- The cost is start latency for rows queued behind another start — most noticeable behind a helper
  resolution, which probes candidates for ~1.25 s each. That is a one-time cost per app.

**How it works**:
- Order for a request: dedupe (already queued / resolving / pending / active → no-op) → hard blocks
  reject immediately (Real off, Two-App Readiness running, ineligible app, helper probe busy) → lane
  busy ⇒ enqueue → `productSessionStartBlockReason` is evaluated only when the lane is free.
- Queued apps report `isOperationPending`, so the row shows the existing pending badge, repeated
  attempts dedupe, and queued rows stay visible in the row filter.
- The physical in-flight tracking (start request ids + resolution task count) is private to
  `ProductRealStartCoordinator`, **not** in the shared state: global resets (Stop All, Real off,
  sleep) clear the state, but must not "free" the lane while a cancelled start or probe is still
  creating or destroying Core Audio objects.
- **Drain points** are only where the lane physically frees: the end of a start's post-await block —
  after a cached-helper retry has already taken the lane, and in the stale branch only after the
  orphan teardown is registered with the settle gate, so the next start's `waitForReadyToStart` sees
  it — and the end of a resolution task. Cancelling a resolution does **not** drain: the cancelled
  probe keeps running briefly plus its cleanup, so draining immediately would start a resolution that
  collides with it.
- Each drained entry re-enters its original entry point and re-runs the full preflight against
  current `context.apps`, so the gain is the slider value at drain time; a now-blocked entry shows its
  message and is dropped; a vanished app is skipped.
- Queued entries are dropped by per-app stop, Stop All, Real off, output-device change, sleep,
  termination, app exit, and panel close (queued entries must not drain into background helper
  probing after the panel closes). Stop All also cancels an in-flight helper resolution, whose late
  result would otherwise start a session after the user stopped everything.

**Would revisit if**: N-session measurements show that start latency with many rows is a real
usability problem. Then consider letting direct-PID starts bypass the lane while no helper probe is
running — but only after the probe itself is brought under the lifecycle/settle gates.

---

## Why live diagnostics publish only for the focused session and only while Advanced is visible

**Decision** (`5a78656`): Per-callback Product Real live diagnostics are published to the shared
Advanced surface (`processTapLiveDiagnostics` and the Advanced coordinator's progress) only by the
**focused** session, and only while the Advanced section is **visible**.

**Reasoning**:
- The Advanced card is one shared surface. With N sessions, every session's ~4 Hz diagnostics
  callback (already rate-limited by the per-session publish gate) overwrote the same two fields, so
  the card showed interleaved values from different apps — misleading as a diagnostic.
- Each publish fired `objectWillChange` twice on the single `MixerViewModel`, which the menu bar
  scene label and the panel observe. The main thread therefore took ~4N callbacks/s × 2
  notifications, each re-evaluating the scene and re-rendering the panel — even with the Advanced
  section collapsed or the panel closed, when nothing reads those fields (`ProcessTapTestView` is the
  only reader). Release profiling had already shown Main Thread / SwiftUI as the relative cost centre.
- **Focus rule:** the newest start takes the focus, matching its "Starting…/started" result line. If
  the focused app no longer has a session (stopped, failed, superseded), the next accepted callback
  from a surviving session adopts the focus. This lazy adoption needs no stop-side bookkeeping. The
  focus check runs after `shouldAcceptCallback`, so a stale callback can never take the focus.
- **Visibility** is a plain stored property (`isLiveDiagnosticsDisplayVisible`, **not**
  `@Published`): nothing renders from it, so changing it must not fire `objectWillChange` itself.
  `MixerPanelView` sets it on appear, clears it on disappear, and sets it from the Advanced disclosure
  action (no `onChange`, for macOS 13). The focus still moves while the display is hidden.
- Deliberately **not** gated: the start's "Starting…" result / zero progress / cleared diagnostics /
  running flag, the post-await result and failure clears, the stop display (final diagnostics + stop
  result), the Advanced manual path, the manager's `recordDiagnostics`, the controller's publish gate,
  and the per-session starvation attribution log — it still runs for every accepted callback, so a
  spike on a non-focused session stays attributable in the log.

**Would revisit if**: per-row live meters are added (each row then needs its own per-session
diagnostics state instead of the single shared surface — gap D in `PLAN_MULTI_APP.md`), or users need
to choose which session the Advanced card shows.

---

## Why live output renders straight to the device through one aggregate IOProc

**Decision** (`377f1a8`, with in-engine sample-rate handling in `da6ed70`): The default live output
path of Product Real and Advanced live control is the **direct aggregate output engine**: one private
aggregate device whose main/clock sub-device is the default output device and which also contains the
process tap (drift compensated), and **one IOProc** that reads the tap from `inInputData` and writes
the faded/gained samples to `outOutputData`. There is no `AudioQueue` and no cross-thread buffer
hand-off. The old tap-only aggregate + `AudioQueue` path stays as a **legacy fallback** (used when
`MacMiniMixerLiveOutputMode=audioQueue` is set, when the output device has input streams, or when the
direct setup fails) and is scheduled for removal.

**Context — random crackle came from two clocks.** The previous live path ran a tap-only aggregate
whose IOProc (tap clock) copied buffers across threads into a separate `AudioQueue` that runs on the
output device's clock. Two free-running clocks joined by a hand-off will underrun sooner or later, so
Product Real Control crackled at random, typically when a second session started. The earlier
hardening (P177–P182, the toggle guard) addressed teardown/startup transients and made the symptoms
measurable, but could not remove a drift between two clocks that is built into the structure.

**Reasoning**:
- It follows Apple's own structure for tap playback: aggregate = output device (main sub-device, so
  it provides the clock) + tap with drift compensation. Input and output are then delivered in the
  same callback on one clock, so there is no queue depth to tune and nothing to underrun between
  threads.
- Gain and fades stay what they were: the renderer reuses `ProcessTapLiveGainRamp` (fade-in on start,
  fade-out before stop) and receives gain/fade requests through a try-lock only, so the audio thread
  still never blocks, allocates or logs. The copy itself is a pure, real-time-safe function
  (`ProcessTapDirectOutputCopier`) that handles interleaved/non-interleaved layouts, mono/stereo
  mapping, extra channels (zeroed) and short/missing input (silence), and is unit-tested.
- **Fallback instead of failure.** Anything the direct path cannot do safely falls back to the
  legacy path (after tearing down every direct-path resource) rather than failing the start. The
  important case is an output device that also has **input streams** (headsets, interfaces with a
  microphone): the aggregate's input list then holds the device's microphone as well as the tap, the
  order is not documented, and the wrong stream would play the microphone, so only output-only devices
  use the direct path. Unsupported formats/rates and any aggregate/IOProc failure fall back the same
  way, and the reason is logged.
- **Never change the user's device sample rate** (owner decision). At the default 44.1 kHz on
  built-in speakers the aggregate's tap stream *reports* 48 kHz. The first direct version rejected
  that as a "sample rate mismatch" and fell back to the crackly path. The engine now accepts differing
  rates (ratio within 1/8..8) and converts inside the IOProc with `ProcessTapDirectOutputResampler`
  (preallocated FIFO + `AudioConverter`, created and warmed up off the audio thread; underruns render
  silence and are counted). The real-hardware log then showed the HAL already delivers the tap at the
  aggregate's rate — 512 tap frames per 512 output frames every cycle, `measuredRatio=1.00000` — so
  the "mismatch" was a property of the reported format, not of the audio. The resampler therefore
  **measures** the first cycles and passes frames straight through (`path=passthrough`) when it sees
  one tap frame per output frame; it keeps the converter only as a safety net for a HAL that does
  deliver a different rate (assuming the reported rate would otherwise play at the wrong speed).
- **Safety valves without a rebuild:** `defaults write <bundle id> MacMiniMixerLiveOutputMode
  audioQueue` (force the legacy path, for A/B listening) and `MacMiniMixerDirectResample off`
  (restore "rate mismatch → fall back"). Both are read when a controller is created.
- Teardown ordering is unchanged in spirit: the direct path fades out inside the IOProc and waits,
  bounded, for the ramp to render before stopping IO, so the device never stops on a non-zero sample.

**Evidence** (one MacBook Pro, owner's listening tests plus the unified log; **not** CPU or
latency measurements): at 48 kHz, five concurrent sessions (two Safari web apps, Safari, Spotify,
Music) over three rounds, every start `output=direct`, no fallbacks, no Core Audio errors, no crackle;
at the default 44.1 kHz, up to six concurrent sessions with repeated stop/start rounds,
`path=passthrough`, `underruns=0 overflows=0`, no crackle; and crackle-free on a second output device
at 48 kHz with Firefox, Safari, Spotify, Music and YouTube (every start on that device logged `output=direct rate=48000 resample=false`).

**What it does not mean**:
- It is not verified on other Macs, output devices, sample rates or macOS versions, and says nothing
  about CPU, memory, Stop All or sleep timing with more than three sessions — the many-session gates
  in "Why there is no Product Real app-count limit" are unchanged.
- Devices with input streams still use the legacy path, which can still crackle there.
- The converting path (`path=converting`) has unit tests but has not been seen on real hardware,
  because every tested device passed through.

**Would revisit if**: a device or macOS version crackles on the direct path (compare with
`MacMiniMixerLiveOutputMode=audioQueue`, and read the `output=` / `direct resample report` log
lines), or a HAL starts delivering the tap at a different rate (`path=converting` with underruns).
**Open question for the owner before the legacy path is removed:** what happens on devices with input
streams — support them directly (that needs a reliable way to find the tap stream inside the
aggregate's input list) or accept no live control there.
