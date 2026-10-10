# MacMiniMixer — Project Handoff

A self-contained snapshot of the project so a fresh Claude/Codex chat can continue without prior
context. This file is committed to the repo and should be kept current when the project state
changes. It is **not** a public release document — v2.3.5 is the release for 2026-10-10 (see
`CHANGELOG.md`).

> Always verify the live state before trusting this file — run the commands in
> [§9 Verification commands](#9-verification-commands) first. Commit hashes and test counts below
> reflect the state at the last update and may have moved.

---

## 1. Repo identity

- Local path: `/Users/ahmed/MacMiniMixer` on the maintainer's Mac. The path may differ by machine
  (other clones, agent worktrees, cloud sessions); adjust the `cd` in §9 accordingly.
- Branch: `main`
- GitHub: `akwnnwastaken/MacMiniMixer`
- macOS **Swift + SwiftUI menu bar** app (Windows-Volume-Mixer-inspired).
- Purpose: output device selection, real system output volume, running-app list, and **Product
  Real Control** (per-app audio via Core Audio Process Tap).
- Constraints: **public Core Audio APIs only** — no private APIs, no third-party dependencies, no
  HAL driver / virtual audio device.
- Process Tap features require **macOS 14.2+**; deployment target stays **macOS 13.0** (Process Tap
  paths are availability-guarded).

## 2. User workflow / preferences

- The user speaks **Turkish**; prompts written for Claude/Codex should be in **English**.
- Prompts should be **numbered** and give **explicit, step-by-step terminal commands**.
- Typical loop: we write a numbered prompt → the user pastes it into Claude → Claude edits code and
  returns a report → the report is reviewed (ChatGPT/user) → decide to commit / ask for tests /
  write the next prompt.
- Do **not** commit, push, or tag on the user's behalf unless explicitly asked; hand over commands.

## 3. Critical guardrails

- **No release or tag** unless explicitly requested.
- **v2.3.5 release (2026-10-10):** adds Launch at Login in the header `⋯` menu using
  `SMAppService.mainApp`. `MARKETING_VERSION` is **`2.3.5`** and `CURRENT_PROJECT_VERSION`
  is `4` (all 4 build configurations). The version number was explicitly selected by the owner;
  per-app audio remains experimental. Do not bump the version again until the owner asks.
  Automatic launch after a real logout/login has not been verified.
- **Do not reintroduce** the unsafe default-output Core Audio property listener / output-device
  observer. A prior one caused silent system audio that survived app quit and required
  `sudo killall coreaudiod`.
- Polling → HAL property-listener migration is **research-only** for now (same danger as above).
- **Product Real has no app-count limit — owner decision.** `AppConstants.maxConcurrentLiveSessions`
  is `Int? = nil` (unlimited). The cap mechanism stays injectable for tests
  (`ProcessTapLiveSessionManager(maxSessions:)`, `maxConcurrentSessions` on the start coordinator /
  facade). **Do not reintroduce a cap without asking the owner.** The remaining gates for many
  sessions are **real-hardware evidence** (CPU, Drops/Fail/Starv, output change, Stop All, sleep/quit
  with e.g. 5–8 apps) and the deferred engine-self-stop gating (§7), not a config value.
- Real app control is **always on, with no toggle** (owner decision, `4220c46`): `MacMiniMixerApp`
  enables it at launch via `AppConstants.realAppControlEnabledAtLaunch` (the view model's own default
  stays OFF for tests). Only user interaction with a row starts a session.
- The **Advanced section is developer-only** (owner decision, `4220c46`): it is not built unless
  `defaults write com.example.MacMiniMixer MacMiniMixerDeveloperMode -bool YES` was run (read once
  when the panel is created; relaunch). `Show all apps`, `Launch at Login`, and `Quit` live in the header `⋯` menu.
  Rationale: `docs/DECISIONS.md`.
- **Audio callback path:** the direct renderer/IOProc (`ProcessTapDirectOutputRenderer`,
  `ProcessTapDirectOutputCopier`, `ProcessTapDirectOutputResampler`) is now the live audio path; the
  legacy `AudioQueue` output is a frozen fallback scheduled for removal. Don't change either without
  manual listening tests on real hardware, and **never change the user's output-device sample rate
  automatically** (owner decision).
- **One disclosed private-API grey area:** per-app attribution calls the public `proc_pidinfo` with the
  undocumented `PROC_PIDCOALITIONINFO` flavor (XNU private header, mirrored by value). Keep the
  bundle-id fallback that applies when it fails; do not add further private or undocumented calls.
- **Never block on CI** (it may be out of macOS minutes): re-run an infra failure at most once, then
  report CI as unavailable and run `xcodebuild test` locally (§9).
- **No broad `MixerViewModel` refactor** without a dedicated prompt.
- Avoid `*.xcodeproj` / `*.pbxproj` edits unless truly necessary.
- If a local `MacMiniMixer.xcscheme` Release-profiling change appears unexpectedly, **do not stage
  or commit it**.
- Don't add heavy work to the audio callback. In tests: no real sleeps — use injected
  clocks/releasers and deterministic observable waits.

## 4. Current Product Real state

- **Code layout — the internal Product Real split is COMPLETE (Prompts 223–228).**
  `ProductRealControlCoordinator` is a **thin facade (~180 lines) with no start/stop implementation
  logic**: it owns exactly one `ProductRealControlStateStore` and two sub-coordinators, constructs and
  wires them, and forwards its public API (unchanged by the split; `requestAutomaticStart` and
  `clearQueuedStarts` were added later with the start lane). `MixerViewModel` knows **only** the
  facade (never the store or either sub-coordinator).
  - **`ProductRealControlStateStore`** (`ProductRealControlStateStore.swift`, Prompt 223) — the
    **single** production source of `ProductRealControlState` plus the `onWillChange` callback
    storage. Its get/set `productRealControlState` fires `onWillChange` **before** applying a write
    (willSet-style timing); a read never notifies. **Exactly one** production instance exists: the
    facade constructs it and passes it **by reference** to both sub-coordinators, so all three mutate
    one shared source (single source of truth).
  - **`ProductRealStartCoordinator`** (`ProductRealStartCoordinator.swift`, Prompt 227) — owns the
    product-only START + resolution path: app-audio resolution (`startResolvedExperimentalControl`,
    `handleAppAudioTargetResolution`, `cancelAppAudioTargetResolution`, `cancelResolutionTask`) and the
    `appAudioResolutionTask` **ownership + `deinit` cancellation**; `productSessionStartBlockReason`
    (mutual-exclusion preflight, plus a count check only when a cap is configured); the slider/mute
    auto-start `requestAutomaticStart(for:)` (moved here from the view model in `774268a`); **both
    `startExperimentalControl` overloads** (sync preflight + async body); the **queued start lane**
    (`isStartLaneBusy`, FIFO drain, `clearQueuedStarts()`); diagnostics-callback acceptance
    (`shouldAcceptCallback`); the **live-diagnostics focus** (`liveDiagnosticsFocusAppID`,
    `shouldPublishLiveDiagnostics(for:)`); per-session starvation attribution logging
    (`ProductRealStarvationAttributionLog`); cached-helper retry; stale-start rejection; stale-orphan
    cleanup (`cleanupStaleProductLiveStart`); and settle-gate start ordering (`waitForReadyToStart` →
    `startSession` → orphan `registerStop`). Deps: the **shared** state store, the live-session
    manager, the settle gate, the app-audio resolver, the ProcessTap eligibility closure, an optional
    `maxConcurrentSessions: Int?` (default `AppConstants.maxConcurrentLiveSessions` = nil), weak
    `sideEffects`/`context`, and two narrow callbacks (`onEngineStopped`, `refreshActiveName`). It holds
    **no** reference to the stop side.
  - **`ProductRealStopCoordinator`** (`ProductRealStopCoordinator.swift`, Prompt 224) — owns the
    product-only STOP path: `stopExperimentalControl(for:reason:)` (per-app stop leaf),
    `stopProductLiveSessions(reason:)` (Stop All core), `handleProductLiveControlStopped(sessionID:result:diagnostics:)`
    (engine stop callback), `stopRealControlForExitedTargetApps()` (app-exit slice; also drops queued
    starts of apps that exited),
    `tearDownProductStateForHardStop()` (hard-teardown state-reset sub-block), and the shared
    `updateActiveLiveControlAppNameAfterProductChange()`. Deps: the **shared** state store, the
    live-session manager, the settle gate, the app-audio resolver (only for app-exit cached-target
    invalidation), weak `sideEffects`/`context`, and a narrow `cancelResolution` closure. It holds
    **no** reference to the start/resolution side.
  - **Facade (`ProductRealControlCoordinator.swift`, slimmed in Prompt 228)** — constructs the store +
    both sub-coordinators (threading the injected engine/settle/resolver deps and weak seam straight
    through; it stores **none** of them itself), wires the three cross-edges, and forwards
    `productRealControlState` / `setOnWillChange` to the store and the public start/stop methods
    (including `requestAutomaticStart` and `clearQueuedStarts`) to the sub-coordinators. Its
    initializer only gained a **defaulted** `maxConcurrentSessions: Int?` parameter in `08d49bc`, so
    the view model's call site is unchanged, and it has no redundant stored dependencies (only
    `stateStore`, `startCoordinator`, `stopCoordinator`).
  - **Cross-edges — all three are facade-wired `[weak self]` closures; no direct Start↔Stop sibling
    ownership, no retain cycle:**
    - **Start `onStopped` → Stop:** `startCoordinator.setOnEngineStopped { [weak self] sid, res, diag in
      self?.stopCoordinator.handleProductLiveControlStopped(...) }`.
    - **Start active-name refresh → Stop:** `startCoordinator.setRefreshActiveName { [weak self] in
      self?.stopCoordinator.updateActiveLiveControlAppNameAfterProductChange() }` (algorithm not duplicated).
    - **Stop app-exit → resolution cancel:** `stopCoordinator.setCancelResolution { [weak self] reason in
      self?.startCoordinator.cancelAppAudioTargetResolution(reason: reason) }` (all installed via
      post-init setters after both sub-coordinators exist).
- **Still in `MixerViewModel` (cross-subsystem router + lifecycle/UI orchestration — intentional):**
  - `toggleExperimentalControl` (row entry point) — delegates to `coordinator.startExperimentalControl`
    on start and `coordinator.stopExperimentalControl` on stop. `setAppVolume` / `setMuted` (slider /
    mute entry points) forward to `coordinator.requestAutomaticStart(for:)`; the former
    `startAutomaticRealControlIfNeeded` body now lives in the start coordinator.
  - `stopProcessTapLiveControl` (router: product vs advanced-manual) — its product branch delegates
    to `coordinator.stopProductLiveSessions`; `handleAdvancedManualLiveControlStopped` (advanced-manual stop).
    The public no-argument `stopProcessTapLiveControl()` (banner Stop / Stop All) also calls
    `coordinator.cancelAppAudioTargetResolution(reason: .userStopped)` since `774268a`.
  - `stopTwoAppReadinessForPanelClose` (panel `onDisappear`) — calls `coordinator.clearQueuedStarts()`
    **before** cancelling the in-flight resolution, so queued starts never drain into background
    helper probing after the panel closes.
  - `isLiveDiagnosticsDisplayVisible` — a plain stored property (**not** `@Published`, hidden by
    default) plus `setLiveDiagnosticsDisplayVisible(_:)`; `MixerPanelView` sets it on appear (current
    Advanced state), clears it on disappear, and sets it from the Advanced disclosure action (no
    `onChange`, macOS 13 compatible).
  - `refreshProcessTapSelectionAfterAppRefresh` — when the Advanced-selected app vanishes it stops
    **only Advanced manual control** (guarded on `advancedManualLiveControlActive`, `da2b06e`); product
    sessions of exited apps are stopped per app by `stopRealControlForExitedTargetApps`.
  - `applyLiveControlStoppedDisplay` + `showLiveControlWarningIfNeeded` (**shared** display cleanup
    used by both product and advanced-manual stops — reached from the coordinator through the seam's
    `applyLiveControlStoppedDisplay` callback; do **not** move into the product coordinator).
  - `setExperimentalRealAppControlEnabled` (global Real-off command; no longer reachable from the UI), `stopActiveAudioWorkForOutputDeviceChange`
    (5-subsystem output-change fan-out), `tearDownAllProcessTapWork` (global sleep/termination teardown
    fan-out — delegates **only** its Product Real state-reset sub-block to
    `coordinator.tearDownProductStateForHardStop()`; the engine hard stop, resolver/helper/diagnostics
    cleanup, advanced-manual reset, and the earlier-positioned `cancelResolutionTask()` all stay in place
    to preserve exact ordering), `handleSystemWillSleep` / `handleSystemDidWake` /
    `stopProcessTapLiveControlForTermination`.
  - `refreshApplications` / running-app list orchestration (delegates **only** the app-exit product
    slice to `coordinator.stopRealControlForExitedTargetApps()`).
- **The seam** (`MacMiniMixer/Features/Mixer/ProductRealControlSideEffects.swift`):
  - `ProductRealControlSideEffects` (write/callback side, coordinator → VM): `showProductRealStatus`,
    `setActiveLiveControlAppName`, `setProcessTapLiveDiagnostics`, `setLiveControlDiagnosticResult` /
    `Progress` / `Running`, and `applyLiveControlStoppedDisplay` (routes the coordinator's stop
    handling into the VM's **shared** display-cleanup helper, which advanced-manual stop also uses).
    The former `handleProductLiveControlStopped` seam member was **removed** when that handler moved
    into the coordinator (Prompt 216) — the engine `onStopped` now calls the coordinator's own
    handler directly.
  - `ProductRealControlContext` (read side, VM → coordinator): `apps`,
    `isExperimentalRealAppControlEnabled`, `advancedManualLiveControlActive`,
    `isTwoAppReadinessRunning`, `isProcessTapTesting`, `isHelperBusy`, `isAppAudioTargetResolving`,
    `isProcessTapLiveControlActive`, `processTapLiveDiagnostics` (added Prompt 216 for the Stop All
    no-active-session display path), and `isLiveDiagnosticsDisplayVisible` (added in `5a78656`; gates
    only the per-callback product diagnostics publish). The unused `selectedProcessTapAppID`
    requirement was **removed** in Prompt 221 (the coordinator never read it; the VM keeps its own
    property for the row filter).
  - `MixerViewModel` conforms to both; the coordinator holds them **weakly** (the VM owns the
    coordinator, so a strong back-reference would be a retain cycle).
- **Coordinator init / IUO note:** `MixerViewModel` stores the coordinator as an implicitly-unwrapped
  `ProductRealControlCoordinator!`, assigned at the **end of `init`** once `self` (the seam) is fully
  initialized. This is deliberate and load-bearing: eager assignment guarantees `setOnWillChange` is
  wired before any state mutation. Nothing reads the state during `init`, so the IUO is never accessed
  while nil. Do **not** convert it to `lazy` (a lazy coordinator could be created on first state
  access before the change handler is installed, dropping a UI update).
- **Why `ProductRealControlState` change notifications still work:** the state moved out of the VM's
  `@Published`. Since Prompt 223 the **`ProductRealControlStateStore`** owns it and exposes the get/set
  `productRealControlState` property that fires `onWillChange` **before every write**; the facade's own
  `productRealControlState` and `setOnWillChange` forward to the store (as do the start and stop
  sub-coordinators' private state accessors). The VM wires `coordinator.setOnWillChange { objectWillChange.send() }` in
  `init` (unchanged), so a mutating call still emits exactly one `objectWillChange` (matching the old
  `@Published willSet`). The VM keeps a forwarding computed `productRealControlState` so all its
  existing call sites are unchanged.
- Uses Core Audio **Process Tap + `.mutedWhenTapped`** with gain applied in the audio callback. Each
  session owns its own tap / private aggregate device / IOProc (plus a replay `AudioQueue` only on the
  legacy fallback path), so CPU and Core Audio load grow per active app.
- **Direct aggregate output engine (default live output, `377f1a8` + `da6ed70`).** One private
  aggregate = the default output device (main/clock sub-device) + the tap (drift compensated); one
  IOProc reads the tap from `inInputData` and writes the faded/gained samples to `outOutputData`. No
  `AudioQueue`, no cross-thread hand-off. Why: the old live path ran two clocks (tap IOProc → thread
  hand-off → `AudioQueue` on the output clock), so underruns were inevitable = the random crackle.
  Code: `ProcessTapLiveOutputMode` (`ProcessTapLiveControlling.swift`), `attemptDirectOutputStart` /
  `ProcessTapDirectOutputRenderer` (`CoreAudioProcessTapLiveController.swift`),
  `ProcessTapDirectOutputCopier` / `…FrameFIFO` / `…Resampler` (`ProcessTapOutputBufferCopier.swift`),
  `ProcessTapResourceContext.createPrivateOutputAggregateDevice`. Falls back to the **legacy
  `AudioQueue` path** (`ProcessTapLegacyAudioQueueOutput.swift`, scheduled for removal) when
  `MacMiniMixerLiveOutputMode=audioQueue`, when the output device has **input streams** (the tap
  stream's position in the aggregate's input list is not documented), or when any direct setup step
  fails (warning log with the reason). Differing tap/output rates are converted in the IOProc, but the
  resampler measures the first cycles and passes frames straight through when the HAL already
  delivers one tap frame per output frame (`path=passthrough` — what real hardware does); the device's
  sample rate is never changed. Switches (read per controller): `defaults write <bundle id>
  MacMiniMixerLiveOutputMode audioQueue` and `MacMiniMixerDirectResample off`. In direct mode the
  Advanced card shows `Queued 0`. Rationale: `docs/DECISIONS.md`.
- **Per-app audio processes (`5a498c2`, `6d1d265`).** A row's audio processes come from the HAL's
  process-object list (`AudioProcessObjectListing`), are matched by the pure `AppAudioProcessMatcher`
  and tapped together in one multi-process tap (`ProcessTapTarget.additionalProcessIdentifiers`).
  Attribution is by **resource coalition** (`proc_pidinfo` flavor `PROC_PIDCOALITIONINFO`, 20) when
  both ids are known, so Safari vs a Safari web app and Chrome vs a PWA/Canary stay apart; with an
  unknown coalition it falls back to bundle-id rules (exact id or allow-listed helper). **Grey area:**
  that flavor is defined only in XNU's private header (mirrored by value, not Apple-documented) — keep
  the fallback, and see `docs/DECISIONS.md` ("Why no private APIs"). Known limit: rows whose apps
  share one coalition contend for the same helpers (first starter wins).
- **No app-count limit (owner decision, `08d49bc`):** any number of Product Real sessions can run at
  once (`maxConcurrentLiveSessions = nil`; the product manager is built with `maxSessions: nil`). The
  active banner summarizes many apps (full list in the accessibility label) with "Stop All"; since
  `4220c46` its one-line text reads "N apps controlled" for two or more apps. Fake-backed tests cover 6–8 concurrent sessions; **real-hardware resource
  characterization only goes up to 3** (up to 6 were listened to for crackle with the direct engine;
  see §6/§7/§10).
- **Queued start lane (`774268a`):** at most one Product Real helper resolution or product start is
  *physically* in flight. A start requested meanwhile (slider/mute → `requestAutomaticStart`, or the
  row toggle; direct-PID or helper) is queued FIFO in `ProductRealControlState.queuedStarts`. Queued
  apps report `isOperationPending` (pending badge + dedupe) and stay visible in the row filter.
  Ordering: dedupe → hard blocks reject immediately (Real off, two-app test, ineligible app, helper
  probe busy) → lane busy ⇒ enqueue → `productSessionStartBlockReason` only once the lane is free.
  The lane drains only when it physically frees: at the end of a start's post-await block (after a
  cached-helper retry has taken the lane; in the stale branch only after the orphan teardown is
  registered with the settle gate) and when a resolution task finishes (a *cancel* does not drain).
  Each drained entry re-runs its full preflight against current `context.apps` (gain = slider at
  drain time). The in-flight tracking (`inFlightStartRequestIDs`, `inFlightResolutionTaskCount`) is
  private to the start coordinator, **not** in the shared state, so global resets cannot free the
  lane while a cancelled start/probe is still running. Queued entries are dropped by per-app stop
  (`clearStartRequest`), Stop All / Real off / output change (`clearAllStartRequests` /
  `clearAllOperations`), sleep / termination (hard-teardown reset), panel close
  (`clearQueuedStarts`), and app exit (`removeQueuedStarts(notIn:)`).
- **Live diagnostics focus / visibility (`5a78656`):** only the focused session publishes to the
  shared Advanced surface (`setProcessTapLiveDiagnostics` / `setLiveControlDiagnosticProgress`). The
  newest start takes the focus; if the focused app no longer has a session, the next accepted
  callback from a surviving session adopts it (no stop-side bookkeeping); stale callbacks are
  rejected before they can touch the focus. Per-callback publishing also requires
  `isLiveDiagnosticsDisplayVisible` (Advanced section on screen). Not gated: start / failure / stop
  display writes, the Advanced manual path, `recordDiagnostics`, the controller's ~4 Hz publish gate,
  and the per-session starvation attribution log (`617b7f2`), which runs for every accepted callback.
- **Multi-session fixes:** quitting the Advanced-selected app stops only Advanced manual control
  (`da2b06e`); the cached-helper retry runs alongside other product sessions and is suppressed only
  by Advanced manual control (`c57bf37`); Stop All also cancels an in-flight helper resolution
  (`774268a`).
- Normal per-app row sliders/mute are **UI-state/preview only** when Real Control is not active for
  that row — they do not change any app's real per-app audio. When Real Control **is** active for a
  row, that row's slider/gain drives the **real** Process Tap gain.
- **System output volume is real Core Audio** (via `SystemVolumeControlling`). Writability is probed
  proactively (`isCurrentOutputVolumeSettable()`, `3c2f4e8`) at init, on output-device change, and
  after a successful selection, so the "Read-only" badge shows before the first drag.
- `PreviewAudioStateController` (renamed from `MockAudioController` in `54d351b`; the production
  `AudioControlling`) is an in-memory store for preview slider values and the system-volume display —
  it does **not** mean the app's real audio paths are fake.
- **Normal-use 3-session long-run smoke PASSED (with caveat)** on one real Mac (Drops/Fail/Starv 0,
  CPU ~20–35% depending on panel state, no `coreaudiod` restart; measured on the older `AudioQueue`
  live path). Resource use (CPU, memory, Stop All, sleep) has not been measured with more than 3
  sessions, nor re-measured on the direct engine. Audio quality with the direct engine was listened
  to with up to **6** sessions (no crackle, `underruns=0`), see §6.
- **Rapid manual Real on/off toggle spam** is guarded (Prompt 194): a per-app pending-operation flag
  in `ProductRealControlState` makes toggle / slider-auto-start attempts for a row no-ops while its
  start/stop is in flight (or its start is queued), and the row shows a non-interactive "working"
  spinner badge. This is layered **above** the settle (P179) and lifecycle-serialization (P181)
  gates; the audio callback is untouched. Deliberate consequence: a toggle can no longer cancel an
  in-flight start mid-flight — the start finishes first.
- **Real-device stress testing should continue** (the guard's real-world effect is not yet
  hardware-verified). See `docs/MANUAL_TEST_CHECKLIST.md` §18 and the many-app section §19.
- **Release packaging:** `scripts/package-app.sh`, the `Build` workflow's `package` job
  (`MacMiniMixer-app` artifact), `release.yml` (draft release on `v*` tags, notes from
  `scripts/release-notes.sh`), and the manual release steps for when CI is unavailable — see
  `docs/RELEASING.md` (`e0a60b4`). v0.14 was cut from here; `MARKETING_VERSION` is `0.14`.
  `scripts/package-app.sh` builds into its own `./.DerivedData-release` with coverage explicitly off,
  because a Release build made after `xcodebuild test` in the shared derived data folder had been
  compiled with code-coverage instrumentation (including the audio IOProc) (`c6a1338`).
- **CI is spent sparingly and may be unavailable (`fde8ceb`).** `build.yml` skips docs/`.md`/`.claude`
  only changes, has a 30-minute timeout and `workflow_dispatch`, and runs the `package` job only for
  `main` pushes and manual runs. Jobs had started failing within seconds with no runner assigned
  (likely out of macOS minutes or a spending limit — not confirmed). **Rule: never block on CI** —
  re-run an infra failure at most once, then report CI as unavailable and hand over the local
  `xcodebuild test` command (§9). Delegated agents never push, trigger or poll CI.
- **Delegation tooling (`0c0e724`).** `.claude/skills/delegate-subagents` (skill + shared
  `project-brief.md`) and typed agents in `.claude/agents` pick the cheapest model that can do the
  job: `code-scout` (haiku, read-only), `docs-writer` and `swift-editor` (sonnet), `swift-implementer`
  (opus, only for Product Real lane/concurrency and Core Audio work). Prompts point at the brief
  instead of repeating it; the brief holds the cloud-session constraints (no Swift toolchain, no CI
  waiting) and guardrails.

## 5. Recent key commits

Newest first (**direct output engine, per-app audio processes, tooling** — after the docs refresh
`222b652`; every commit message is detailed, read them before touching these areas):

```
da6ed70 Convert tap sample rate inside the direct output engine
c6a1338 Keep code-coverage instrumentation out of packaged Release builds (tag checkpoint-direct-engine-48k)
377f1a8 Render live control straight to the output device via one aggregate IOProc
6d1d265 Attribute an app's audio processes by resource coalition
fde8ceb Don't block on unavailable CI; spend fewer macOS runner minutes
0c0e724 Add subagent delegation skill and typed agents with cost-tiered models
5a498c2 Tap all of an app's audio processes for Product Real Control
```

(Two docs-only checkpoint commits sit between these and record the real-hardware results.)

Preceding (**multi-app / no-limit work, release scaffolding, cleanups** — after the split):

```
774268a Queue Product Real starts behind a single start lane instead of rejecting them
5a78656 Publish Product Real live diagnostics for one session, only while visible
c57bf37 Let the cached-helper retry run alongside other Product Real sessions
da2b06e Stop only Advanced manual control when the Advanced-selected app quits
08d49bc Remove the Product Real Control app-count limit (cap 3 -> unlimited)
e0a60b4 Add release packaging: ad-hoc signed zip script, CI artifact, draft-release workflow
3a84483 Complete accessibility coverage of the menu bar UI
3c2f4e8 Probe system output volume writability proactively on device changes
1469eb2 Fill NSHumanReadableCopyright in Info.plist
f94a5cd Remove unused production mock types
54d351b Rename MockAudioController to PreviewAudioStateController
617b7f2 Add per-session starvation attribution logging
040c5db Update docs after completing the internal Product Real coordinator split   (docs)
```

The docs refresh describing these commits lands right after `774268a`. Every commit message in
`git log 617b7f2^..774268a` is detailed (rationale, exact scope, tests) — read them before touching
the multi-session code.

- **`08d49bc`** is the owner decision (no app-count limit); the cap mechanism stays testable.
- **`da2b06e`, `c57bf37`, `5a78656`, `774268a`** are the follow-ups that make many concurrent
  sessions behave: per-app exit handling, cached-helper retry, diagnostics focus/visibility, and the
  queued start lane. The design notes behind them are summarized in `docs/DECISIONS.md` (three new
  entries) and `docs/PLAN_MULTI_APP.md`.
- **`e0a60b4`** adds packaging only — no release, no tag, no version bump.
- **`54d351b`, `f94a5cd`, `1469eb2`, `3c2f4e8`, `3a84483`** close the earlier §7 candidates
  (mock rename/removal, copyright, proactive writability + `SystemOutputCoordinator` failure-path
  tests, accessibility).

Preceding (the **internal Product Real split — COMPLETE**):

```
bc533d6 Slim ProductRealControlCoordinator into a true facade            (Prompt 228)
0b42b7c Extract ProductRealStartCoordinator behind the unchanged facade  (Prompt 227)
98a0a52 Update docs after Product Real state-store and stop-coordinator extraction (Prompt 225, docs)
7af8b2f Extract Product Real state store and stop coordinator            (Prompts 223 + 224, combined)
b9fdffc Fix stale Product Real comments and remove dead context requirement (Prompt 221)
```

> **Note:** `7af8b2f` intentionally **combines Prompt 223 (state store) and Prompt 224 (stop
> coordinator)** in one commit. Prompt 223 was never committed before Prompt 224 began, so the
> coordinator and `project.pbxproj` diffs interleaved both changes; they were committed together
> rather than split with history rewriting, `git add -p`, or artificial patches. Prompt 222 was
> analysis-only (design of the internal split); Prompts 220 and 226 were read-only boundary
> reassessments (whole-facade, then the Start-extraction boundary).

Preceding (the staged `ProductRealControlCoordinator` **stop-path** extraction, Prompts 215–218):

```
d212fdf Move Product Real hard-teardown state cleanup into coordinator   (Prompt 218)
ce803a9 Move Product Real app-exit stop slice into coordinator           (Prompt 217)
55e37d6 Move Product Real stop-all core into coordinator                 (stop-all + stop callback, Prompt 216)
9867f78 Move per-app Product Real stop leaf into coordinator             (Prompt 215)
253b4a9 Refresh handoff before Product Real stop extraction              (docs)
```

Preceding (the staged `ProductRealControlCoordinator` **start-path** extraction, Prompts 205–214):

```
c12aa73 Update docs for Product Real start-path coordinator extraction   (Prompt 213)
92a82c3 Move Product Real start path into coordinator          (async start body, Prompt 212)
73a4132 Move Product Real resolution slice into coordinator    (Prompt 210)
b0a4ff2 Move Product Real state ownership into coordinator      (Prompt 209)
39983ad Move stale-start cleanup into Product Real coordinator  (Prompt 208)
e7b38df Add Product Real coordinator shell                      (Prompt 206)
09397ba Route Product Real async-start side effects through seam (Prompt 205)
53fa050 Move Product Real decision helpers into state           (Prompt 204)
f24d14e Introduce Product Real side-effect and context seam     (Prompt 203)
1323b32 Extract MixerStatusMessageController from MixerViewModel (Prompt 201)
81f69b8 Add SystemOutputCoordinator branch coverage             (Prompt 200)
bf2bf40 Extract MixerVisibleAppsFilter from MixerViewModel      (Prompt 199)
34c3408 Extract RealControlBannerPresenter from MixerViewModel  (Prompt 198)
3cefcf7 Add UI-level guard for rapid Product Real toggles       (Prompt 194)
88bbed5 Harden Product Real teardown and starvation handling    (P177–P182 bundle)
```

**Milestone summary (Prompts 198–214), all behavior-preserving, each its own reviewed commit:**

- 198–201 — extracted pure `MixerViewModel` helpers: `RealControlBannerPresenter`,
  `MixerVisibleAppsFilter`, `MixerStatusMessageController`; filled `SystemOutputCoordinator` test gaps.
- 203 — introduced the `ProductRealControlSideEffects` / `ProductRealControlContext` seam (no logic moved).
- 204 — moved pure decision helpers (`shouldAcceptCallback`, `wouldExceedConcurrentSessionCap`) onto
  `ProductRealControlState`.
- 205 — routed the remaining async-start side-effect writes through the seam.
- 206 — added the inert `ProductRealControlCoordinator` shell (dependency container).
- 208 — moved the stale-start cleanup leaf into the coordinator.
- 209 — moved `ProductRealControlState` ownership into the coordinator (with `onWillChange` forwarding).
- 210 — moved the app-audio resolution slice into the coordinator.
- 212 — moved both `startExperimentalControl` overloads (async start body) into the coordinator.
- 213 — docs refresh.
- **214 — ANALYSIS-ONLY** (no code): planned the stop/lifecycle migration and recommended the next
  smallest step.

**Stop-path milestone (Prompts 215–218), all behavior-preserving, each its own reviewed commit:**

- **215** — moved the per-app stop leaf `stopExperimentalControl(for:reason:)` into the coordinator.
- **216** — moved the Stop All core `stopProductLiveSessions(reason:)` **and** the engine stop
  callback `handleProductLiveControlStopped(...)`; replaced the removed
  `handleProductLiveControlStopped` seam member with a narrow `applyLiveControlStoppedDisplay`
  callback (shared display cleanup stays in the VM) and added the `processTapLiveDiagnostics`
  context read.
- **217** — moved the app-exit slice `stopRealControlForExitedTargetApps()`; `refreshApplications`
  delegates only that slice.
- **218** — moved only the Product Real **state-reset sub-block** of `tearDownAllProcessTapWork`
  into `tearDownProductStateForHardStop()`; the engine hard stop, resolver/helper/diagnostics
  cleanup, advanced-manual reset, and the earlier `cancelResolutionTask()` stay in the VM at their
  existing positions (exact teardown ordering preserved).

**Internal split milestone (Prompts 220–228) — COMPLETE:**

- **220** — read-only reassessment (also corrected a stale finding: the `ProductRealControlContext`
  member removed in 221 was `selectedProcessTapAppID`, not `isHelperBusy`, which is live).
- **222** — analysis-only design of the internal split; concluded Resolution must stay with Start
  (bidirectional coupling), recommended a shared state store first, and closure-broken cross-edges.
- **223** — extracted `ProductRealControlStateStore` (single state source + `onWillChange` storage)
  behind the unchanged facade; MixerViewModel unchanged.
- **224** — extracted `ProductRealStopCoordinator` (the six stop methods) behind the unchanged facade;
  wired the app-exit resolution-cancel as a `cancelResolution` closure (no Start↔Stop cycle), routed
  start `onStopped` and active-name refresh to the stop coordinator, and moved the stop unit tests
  into `ProductRealStopCoordinatorTests` while keeping facade forwarding/integration tests. 223 + 224
  landed as the single combined commit `7af8b2f`.
- **226** — read-only reassessment of the Start-extraction boundary against the post-Stop architecture.
- **227** — extracted `ProductRealStartCoordinator` (the whole start + resolution unit, incl. the
  `appAudioResolutionTask` + its `deinit` cancel) behind the unchanged facade; replaced the async
  body's direct stop calls with injected `onEngineStopped` / `refreshActiveName` closures; moved the
  start/resolution tests into `ProductRealStartCoordinatorTests` and kept facade forwarding + two
  cross-edge integration tests.
- **228** — slimmed `ProductRealControlCoordinator` to a true facade (~170 lines): removed the six
  now-write-only stored deps (they thread straight through init into the sub-coordinators) and the
  unused `import AppKit`; initializer signature and public API unchanged.

The Product Real internal split is **finished**: facade + state store + start coordinator + stop
coordinator, one shared state source, three `[weak self]` facade-wired cross-edges, and MixerViewModel
byte-for-byte unchanged throughout. Full suite **414 passed / 0 failed / 0 skipped**.

**Hardening bundle `88bbed5` = P177–P182:**

- **P177** — process-tap destroy retry + fault reporting (a leaked `.mutedWhenTapped` tap can
  otherwise leave apps muted inside coreaudiod).
- **P178** — dispose the output queue **after** IOProc stop/destroy (removes self-inflicted
  Drops/Fail during teardown/device transitions).
- **P179** — stop→start settle gate (a new start waits for recent teardown + a short settle before
  creating new Core Audio objects).
- **P180** — gate output-starvation counting on observed real input; silent apps show a neutral
  "Waiting for app audio" / "No app audio detected" state instead of false Starv.
- **P181** — global Core Audio lifecycle serialization (session create/destroy never overlap →
  less shared-route churn during app combination changes).
- **P182** — output-queue startup-warmup gate (a fresh queue's first-cadence transient is not
  reported as a real underrun).

`c0f8ad4` fixed Swift 6 async `NSLock` → scoped `withLock` in tests; `0f5652a` made live-control
test waits deadline-bounded instead of a fixed `Task.yield()` budget (removed a full-suite flake).

## 6. Test & CI state (as of last update)

- **Last recorded full run (CI, macos-15):** **515 passed / 0 failed / 0 skipped** (code state =
  `774268a`). The later commits (direct output engine, coalition attribution, multi-process taps)
  added tests, but no full run or test count has been recorded since — run the suite locally and take
  the count from the result bundle. History: 414 after the split (`bc533d6`), 431 after the attribution logging
  (`617b7f2`); the commits since then added, among others, 20 `SystemOutputCoordinatorTests`, the
  unlimited-session tests (6–8 sessions at manager / facade / VM level), the diagnostics focus /
  visibility tests, and `ProductRealStartLaneTests`.
- **CI:** the GitHub Actions `Build` workflow (`build` job with tests, then the `package` job that
  uploads the `MacMiniMixer-app` zip) was green at `774268a`. **Since then CI has been unreliable:**
  jobs started failing within seconds with no runner assigned (likely out of macOS minutes or a
  spending limit; not confirmed), so recent commits have not been verified by CI (the owner built
  and ran them locally on real hardware). `build.yml` now skips
  docs/`.md`/`.claude`-only changes, has a 30-minute timeout and `workflow_dispatch`, and runs
  `package` only for `main` pushes and manual runs (`fde8ceb`). Don't wait on CI; verify locally with
  the `xcodebuild test` command in §9. The `Release` workflow has not run against a tag (no tag has
  been pushed).
- An earlier README-only commit had a one-off CI failure that **passed on rerun** (a flake).
- **Test scope:** XCTest coverage focuses on pure logic, fake-backed coordinators, and synthetic
  buffers, not real Process Tap or device integration; no test captures real audio.
- `xcodebuild test` exits `0` on pass, `65` on any test failure. Get exact counts from the newest
  result bundle:
  `xcrun xcresulttool get test-results summary --path "$(ls -td ./.DerivedData/Logs/Test/*.xcresult | head -1)"`

- **Real-hardware checkpoint 2 (`da6ed70`, tag `checkpoint-direct-engine-44k`):** direct engine on
  built-in speakers at the default **44.1 kHz**: HAL delivers the tap at the aggregate rate
  (`path=passthrough`, measured ratio 1.0), up to **6 concurrent sessions**, `underruns=0`, no crackle
  heard. Remaining `AudioQueue` users: output devices with input streams (some headsets/interfaces)
  and the Replay Probe.
- **Second output device (after checkpoint 2, one Mac):** crackle-free at 48 kHz with Firefox, Safari,
  Spotify, Music and YouTube. The owner's log shows every start on that device logged `output=direct rate=48000 resample=false` (device ID 227),
  i.e. that device has no input streams and used the direct engine. CPU/latency were not measured.
- **Real-hardware checkpoint (`c6a1338`, tag `checkpoint-direct-engine-48k`):** direct aggregate
  output engine crackle-free with **5 concurrent sessions** (Netflix/YouTube Safari web apps, Safari,
  Spotify, Music) on built-in speakers **at 48 kHz**; at 44.1 kHz the tap reports 48 kHz and the engine
  falls back to the crackly AudioQueue path. Next: in-engine resampling (do **not** change the user's
  device sample rate automatically — owner decision; that is only the fallback plan).
  *(Superseded by checkpoint 2 above: `da6ed70` handles 44.1 kHz inside the engine, no fallback.)*

## 7. Known deferred / candidate items

**Open with many sessions (needs real hardware; deliberately not changed yet — audio-adjacent):**

- **No real-hardware resource characterization for more than 3 sessions.** CPU, memory/threads,
  Drops/Fail/Starv, output-device change, Stop All, quit-one-app, and sleep/wake with e.g. 5–8 Real
  apps have **not** been measured (only crackle/underruns were listened to and logged with up to 6
  sessions on the direct engine, §6), and the 3-session CPU numbers predate the direct engine. This is
  the first gate (§10).
- **Remove the legacy `AudioQueue` live output** (`ProcessTapLegacyAudioQueueOutput.swift`) once the
  direct engine covers more devices. Open owner question: output devices **with input streams**
  (headsets/interfaces with a microphone) still need it — either support them directly (needs a
  reliable way to find the tap stream in the aggregate's input list) or accept no live control
  there. Also unverified: the `path=converting` branch on real hardware (every tested device
  passed through), other output devices/sample rates/macOS versions, and which path the second
  output device used (§6).
- **Coalition attribution caveats:** it relies on an undocumented `proc_pidinfo` flavor (fallback to
  bundle-id rules when unknown); rows whose apps share one coalition (launched from Terminal, game
  launchers) contend for the same helpers; the matcher's bundle-id allow-list is hand-maintained.
  Real-hardware evidence is recorded for Safari vs Safari web apps; none is recorded for Chrome vs
  Chrome PWAs/Canary (unit tests only).
- **Engine self-stops bypass the gates.** Stops the live controller initiates itself (output-device
  change or target-app exit detected by its diagnostics timer, timeout) go around the Core Audio
  lifecycle gate (P181) and the stop→start settle gate (P179), so many sessions can tear down
  concurrently.
- **Hard teardown blocks the main thread** at sleep/quit (`stopLiveControlNow`, synchronous, per
  session fade + destroy): estimated from the code path at roughly 0.4–3.4 s with many sessions — not
  measured.
- **Stop All is sequential:** `stopProductLiveSessions` stops sessions one after another (N × fade +
  destroy), registered as one settle-gate task.
- **The menu bar label / scene still observes the whole view model**, so any `objectWillChange`
  re-evaluates it (diagnostics are now gated, but other state changes are not).
- Smaller items from the multi-app plan: the shared active-name display uses dictionary order
  (`activeSessions.first`, not deterministic); slider moves during a start's optimistic window are
  dropped (no `liveSessionID` yet) until the next move after confirmation; optionally register a
  settle after a `.discoveredHelper` resolution so the first helper start also waits after the
  probe's aggregate destroy.

**Other deferred items:**

- **Next `MARKETING_VERSION` bump / tag / release** — only when the owner asks (v0.14 is released,
  2026-10-06). Packaging is in place (`docs/RELEASING.md`); Developer ID signing + notarization is
  documented only.
- **Core Audio property-listener (polling → HAL) migration** — deferred / research-only.
- **Broad `MixerViewModel` / `ProductRealControlCoordinator` extraction** — deferred.
- Candidates, not urgent: **localization**; **keyboard navigation**; **view/snapshot** and
  **integration** tests; a real bundle identifier before any Developer ID distribution (still
  `com.example.MacMiniMixer`).

## 8. Environment notes

- In-editor SourceKit "Cannot find type …" errors are known **cross-file noise** — `xcodebuild` is
  authoritative.
- `grep`-piped shell commands sometimes error in this environment; prefer `git grep`, pathspecs,
  writing output to a file, and reading files directly.
- `MacMiniMixer.xcodeproj/project.pbxproj` uses **explicit file references** (no synchronized folder
  groups), so **every new `.swift` file needs manual pbxproj registration** — 4 entries per file
  (`PBXBuildFile`, `PBXFileReference`, `PBXGroup` membership, `PBXSourcesBuildPhase` membership) in
  the correct target. The project's UUIDs follow the `9B7D1BXX2C8F4A9A8B2D0101` pattern; pick unused
  suffixes and add only the required entries (no reordering/reformatting).

## 9. Verification commands

Run these first in any new chat to confirm the live state:

```bash
cd /Users/ahmed/MacMiniMixer
git status --short
git log -12 --oneline
git diff --name-only
git diff --name-only -- '*.xcodeproj' '*.pbxproj'
git grep -n "maxConcurrentLiveSessions" -- MacMiniMixer          # expect `Int? = nil` (unlimited)
git grep -n "MARKETING_VERSION = 0.14.1" -- '*.pbxproj'          # expect 4 matches (v0.14.1 released)
git tag --list 'v*'                                              # expect v0.14 once the owner has tagged it
```

Full test + Release build (when code changes):

```bash
xcodebuild test  -project MacMiniMixer.xcodeproj -scheme MacMiniMixer \
  -destination 'platform=macOS' -derivedDataPath ./.DerivedData CODE_SIGNING_ALLOWED=NO
xcodebuild build -project MacMiniMixer.xcodeproj -scheme MacMiniMixer -configuration Release \
  -destination 'platform=macOS' -derivedDataPath ./.DerivedData CODE_SIGNING_ALLOWED=NO
```

## 10. Current state & recommended next direction

### Where things stand

The internal Product Real coordinator split is **done** (Prompts 223–228): `ProductRealControlCoordinator`
is a **thin facade with no start/stop implementation** composing one `ProductRealControlStateStore` +
`ProductRealStartCoordinator` + `ProductRealStopCoordinator` (exact ownership in §4), with one shared
state source and three `[weak self]` facade-wired cross-edges (no sibling ownership, no retain cycle).
`MixerViewModel` stayed byte-for-byte unchanged during the split; the later behavior commits
(`da2b06e`, `5a78656`, `774268a`) changed it deliberately and narrowly (§4). There is **no further
Product Real structural refactor pending**.

On top of that, the owner removed the app-count limit (`08d49bc`) and the multi-session follow-ups
landed (per-app exit handling, cached-helper retry, diagnostics focus/visibility, queued start lane).
Since the last docs refresh (`222b652`) the live audio path changed too: an app's audio processes are
tapped together and attributed by resource coalition (`5a498c2`, `6d1d265`), and the default live
output is the **direct aggregate output engine** (`377f1a8`, `da6ed70`) — the fix for the random
crackle (two clocks joined by an `AudioQueue` hand-off) — with the old `AudioQueue` path kept only as
a legacy fallback. On the owner's Mac it is crackle-free at 48 kHz and 44.1 kHz with up to six
concurrent sessions and on a second output device (§6). What is still missing is **resource
evidence**, not code: CPU/memory/Stop All/sleep have not been measured on real hardware with more than
three sessions, nor re-measured on the direct engine. First re-verify live state (§9) — **do not
trust the line numbers in this file; inspect the repo.**

### What remains in `MixerViewModel` (intentional — cross-subsystem, NOT Product Real)

The view model remains the **cross-subsystem router and lifecycle/UI orchestration layer**. These
responsibilities are deliberately *not* in any Product Real coordinator — they are not product-only, so
moving them into a product-scoped type would *increase* coupling:

- `toggleExperimentalControl` — the row entry point (delegates start/stop to the facade);
  `setAppVolume` / `setMuted` forward to `requestAutomaticStart`.
- `stopProcessTapLiveControl` — the **product-vs-advanced-manual router** (product branch delegates
  to `coordinator.stopProductLiveSessions`); `handleAdvancedManualLiveControlStopped`.
- `applyLiveControlStoppedDisplay` + `showLiveControlWarningIfNeeded` — **shared** display/status
  cleanup used by both product and advanced-manual stops (reached from the coordinator through the seam).
- `tearDownAllProcessTapWork` — the global sleep/termination teardown **fan-out** (engine hard stop,
  two-app readiness, helper/probe, resolver invalidation, diagnostics/replay, advanced-manual reset,
  `cancelResolutionTask()`); only its Product Real state-reset sub-block delegates to
  `coordinator.tearDownProductStateForHardStop()`.
- `stopActiveAudioWorkForOutputDeviceChange` — the 5-subsystem output-device-change fan-out.
- `setExperimentalRealAppControlEnabled`, `handleSystemWillSleep` / `handleSystemDidWake` /
  `stopProcessTapLiveControlForTermination`, `stopTwoAppReadinessForPanelClose` (also clears queued
  starts), `setLiveDiagnosticsDisplayVisible`, and `refreshApplications` / running-app orchestration
  (delegates only the app-exit product slice).
- Advanced diagnostics, helper discovery/probe, and Two-App Readiness orchestration.

### Recommended next engineering direction (conservative)

1. **Real-hardware N-session characterization first** (procedure: `docs/MANUAL_TEST_CHECKLIST.md`
   §19; confirm each session logs `output=direct`, see `docs/MANUAL_TEST_CHECKLIST.md` §21 for the
   direct-engine check). Release build, one real Mac, e.g. **5–8** Real apps (mix of direct apps and a browser/helper
   row): start them quickly via sliders (rows should queue, then start one by one); record panel-closed
   CPU, memory, threads, and the Advanced card's Drops/Fail/Starv/Gap for the focused session; then
   per-app stop, Stop All (time until audio is back and CPU ~0%), an output-device change with all
   sessions active, quitting one controlled app, and sleep/wake. Watch for orphaned mutes (an app
   silent until MacMiniMixer quits) and for `sudo killall coreaudiod` being needed. Record results as
   `> Reference (…)` blocks; **do not invent numbers** — if it was not measured, say so.
2. **Then the deferred engine-self-stop gating** (§7): route controller-initiated stops (output
   change / app exit / timeout) through the lifecycle (P181) and settle (P179) gates so N sessions do
   not tear down at once. This is audio-adjacent: small, test-first steps, and a real-hardware retest.
3. After that, guided by the measurements: Stop All parallelism/latency, the main-thread hard
   teardown at sleep/quit, and narrowing what the menu bar label observes.
   In parallel and independent of the above (no code needed first): **widen real-hardware coverage of
   the direct output engine** (more output devices and sample rates, a device with input streams,
   record `output=` / `path=` log lines each time — checklist §21), then decide the legacy
   `AudioQueue` removal (§7 open question about devices with input streams).
4. Optional: a **read-only reassessment of the remaining `MixerViewModel` responsibilities** —
   (1) lifecycle / global teardown, (2) app-refresh orchestration (`refreshApplications` + its
   selection-refresh helpers), (3) shared display/status handling. **Do not force cross-subsystem
   responsibilities into a Product Real coordinator**; extract only if a clean, self-contained
   boundary emerges.

Whatever the next step: do **not** release/tag or bump `MARKETING_VERSION` again unless asked; do **not** reintroduce an
app-count cap without the owner's say-so; keep Real control starting only on explicit row interaction.
