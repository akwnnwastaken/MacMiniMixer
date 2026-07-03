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
  publication (e.g. throttling the 10 Hz diagnostics update, or gating publication while the
  panel is closed) **before** any audio-buffer/vDSP work. This is the likely future direction,
  not a current requirement.
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
Main Thread / SwiftUI / AppKit, so the right (future) optimization is throttling the 10 Hz
diagnostics publication or gating it while the panel is closed — **before** any audio-buffer
work. CPU is low enough at cap=3 that this is not required now.

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
  dispose after the producer is gone removes that spike.
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
cases came back clean with no `coreaudiod` restart required (see ROADMAP "Product Real
teardown/starvation hardening" and checklist §17).

**Would revisit if**: a real underrun is ever masked (an audible glitch with `Starv 0` after the
warmup window — then the warmup threshold `processTapReplayStartupWarmupBufferCount` is too high),
or the 30–60 min three-session long-run reveals accumulating starvation or leaks.

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
interface.

---

## Why a `ProductRealControlCoordinator` is deferred (post-extraction reassessment)

**Decision**: After extracting the pure `ProductRealControlState` state/model helpers, a
read-only reassessment was done to decide whether the remaining Product Real Control
orchestration should move into its own coordinator (mirroring the other five). The decision
is **not yet** — keep the orchestration in `MixerViewModel` for now.

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
north-star goal, not a deferred curiosity. The current one-active-session limit remains the
*incremental* path toward it (see "Why main product remains one active session").

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
