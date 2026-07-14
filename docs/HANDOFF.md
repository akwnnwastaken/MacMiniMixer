# MacMiniMixer — Project Handoff

A self-contained snapshot of the project so a fresh Claude/Codex chat can continue without prior
context. This file is committed to the repo and should be kept current when the project state
changes. It is **not** a public release document — v0.14 is an internal, unreleased checkpoint.

> Always verify the live state before trusting this file — run the commands in
> [§9 Verification commands](#9-verification-commands) first. Commit hashes and test counts below
> reflect the state at the last update and may have moved.

---

## 1. Repo identity

- Local path: `/Users/ahmed/MacMiniMixer`
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
- **Do not bump `MARKETING_VERSION`** — it stays **`0.13`** because v0.14 is an internal/unreleased
  checkpoint, not a public release.
- **Do not reintroduce** the unsafe default-output Core Audio property listener / output-device
  observer. A prior one caused silent system audio that survived app quit and required
  `sudo killall coreaudiod`.
- Polling → HAL property-listener migration is **research-only** for now (same danger as above).
- Product Real **cap stays 3** concurrent sessions; **N > 3 is deferred**.
- **No broad `MixerViewModel` refactor** without a dedicated prompt.
- Avoid `*.xcodeproj` / `*.pbxproj` edits unless truly necessary.
- If a local `MacMiniMixer.xcscheme` Release-profiling change appears unexpectedly, **do not stage
  or commit it**.
- Don't add heavy work to the audio callback. In tests: no real sleeps — use injected
  clocks/releasers and deterministic observable waits.

## 4. Current Product Real state

- **Code layout (internal Product Real split, Prompts 223–224) — `ProductRealControlCoordinator` is
  a thin facade that owns the START and STOP paths and composes two internal sub-objects.
  `MixerViewModel` knows **only** the facade (never the store or the stop coordinator), and the
  facade's public API is unchanged:**
  - **`ProductRealControlStateStore`** (`ProductRealControlStateStore.swift`, Prompt 223) — the
    **single** production source of `ProductRealControlState` plus the `onWillChange` callback
    storage. Its get/set `productRealControlState` fires `onWillChange` **before** applying a write
    (willSet-style timing); a read never notifies. **Exactly one** production instance exists: the
    facade constructs it and passes it **by reference** to the stop coordinator, so both mutate one
    shared source (single source of truth).
  - **`ProductRealStopCoordinator`** (`ProductRealStopCoordinator.swift`, Prompt 224) — owns the
    product-only STOP path: `stopExperimentalControl(for:reason:)` (per-app stop leaf),
    `stopProductLiveSessions(reason:)` (Stop All core), `handleProductLiveControlStopped(sessionID:result:diagnostics:)`
    (engine stop callback), `stopRealControlForExitedTargetApps()` (app-exit slice),
    `tearDownProductStateForHardStop()` (hard-teardown state-reset sub-block), and the shared
    `updateActiveLiveControlAppNameAfterProductChange()`. Deps: the **shared** state store, the
    live-session manager, the settle gate, the app-audio resolver (only for app-exit cached-target
    invalidation), weak `sideEffects`/`context`, and a narrow `cancelResolution` closure. It holds
    **no** reference to the start/resolution side.
  - **Facade START + resolution path** (still in `ProductRealControlCoordinator.swift`): state access
    via the store; the app-audio resolution task + handling (`startResolvedExperimentalControl`,
    `handleAppAudioTargetResolution`, `cancelAppAudioTargetResolution`, `cancelResolutionTask`);
    `productSessionStartBlockReason` (cap/mutual-exclusion decision); **both `startExperimentalControl`
    overloads** (sync preflight + async body); cached-helper retry; stale-start cleanup
    (`cleanupStaleProductLiveStart`); and the resolution-task `deinit` cancellation. The facade
    constructs and owns the stop coordinator and forwards the four public stop methods to it.
  - **Cross-edges (no direct Start↔Stop ownership cycle):**
    - **Start `onStopped` → Stop:** the async start body calls
      `stopCoordinator.handleProductLiveControlStopped(...)` directly (both objects owned by the facade).
    - **Start active-name refresh → Stop:** the start body calls
      `stopCoordinator.updateActiveLiveControlAppNameAfterProductChange()` (algorithm not duplicated).
    - **Stop app-exit → resolution cancel:** wired as a narrow closure the facade installs after init —
      `stopCoordinator.setCancelResolution { [weak self] reason in self?.cancelAppAudioTargetResolution(reason: reason) }`
      (post-init setter; `[weak self]` keeps the facade → stopCoordinator → closure chain cycle-free).
- **Still in `MixerViewModel` (cross-subsystem router + lifecycle/UI orchestration — intentional):**
  - `toggleExperimentalControl` (row entry point) — delegates to `coordinator.startExperimentalControl`
    on start and `coordinator.stopExperimentalControl` on stop.
  - `stopProcessTapLiveControl` (router: product vs advanced-manual) — its product branch delegates
    to `coordinator.stopProductLiveSessions`; `handleAdvancedManualLiveControlStopped` (advanced-manual stop).
  - `applyLiveControlStoppedDisplay` + `showLiveControlWarningIfNeeded` (**shared** display cleanup
    used by both product and advanced-manual stops — reached from the coordinator through the seam's
    `applyLiveControlStoppedDisplay` callback; do **not** move into the product coordinator).
  - `setExperimentalRealAppControlEnabled` (global Real-off command), `stopActiveAudioWorkForOutputDeviceChange`
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
    no-active-session display path). The unused `selectedProcessTapAppID` requirement was **removed**
    in Prompt 221 (the coordinator never read it; the VM keeps its own property for the row filter).
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
  `productRealControlState` and `setOnWillChange` forward to the store (as does the stop coordinator's
  private state accessor). The VM wires `coordinator.setOnWillChange { objectWillChange.send() }` in
  `init` (unchanged), so a mutating call still emits exactly one `objectWillChange` (matching the old
  `@Published willSet`). The VM keeps a forwarding computed `productRealControlState` so all its
  existing call sites are unchanged.
- Uses Core Audio **Process Tap + `.mutedWhenTapped` + AudioQueue replay/gain**. Each session owns
  its own tap / private aggregate device / IOProc / replay AudioQueue.
- **Up to 3 concurrent** Product Real sessions; the active banner summarizes 3+ apps as "first two
  names +1 more" with "Stop All". **N > 3 deferred.**
- Normal per-app row sliders/mute are **UI-state/preview only** when Real Control is not active for
  that row — they do not change any app's real per-app audio. When Real Control **is** active for a
  row, that row's slider/gain drives the **real** Process Tap gain.
- **System output volume is real Core Audio** (via `SystemVolumeControlling`).
- `MockAudioController` (the production `AudioControlling`) is a UI-state cache for preview slider
  values and the system-volume display — it does **not** mean the app's real audio paths are fake.
- **Normal-use 3-session long-run smoke PASSED (with caveat)** on one real Mac (Drops/Fail/Starv 0,
  CPU ~20–35% depending on panel state, no `coreaudiod` restart).
- **Rapid manual Real on/off toggle spam** is now guarded (Prompt 194): a per-app
  pending-operation flag in `ProductRealControlState` makes `MixerViewModel` ignore toggle/
  slider-auto-start attempts for a row while its start/stop is in flight, and the row shows a
  non-interactive "working" spinner badge. This is layered **above** the settle (P179) and
  lifecycle-serialization (P181) gates; the audio callback is untouched. Deliberate consequence: a
  toggle can no longer cancel an in-flight start mid-flight — the start finishes first.
- **Real-device stress testing should continue** (the guard's real-world effect is not yet
  hardware-verified). See `docs/MANUAL_TEST_CHECKLIST.md` §18.

## 5. Recent key commits

Most recent (the **internal Product Real split** — state store + stop coordinator):

```
7af8b2f Extract Product Real state store and stop coordinator            (Prompts 223 + 224, combined)
b9fdffc Fix stale Product Real comments and remove dead context requirement (Prompt 221)
e4b04b5 Update docs after Product Real stop-path coordinator extraction   (Prompt 219, docs)
```

> **Note:** `7af8b2f` intentionally **combines Prompt 223 (state store) and Prompt 224 (stop
> coordinator)** in one commit. Prompt 223 was never committed before Prompt 224 began, so the
> coordinator and `project.pbxproj` diffs interleaved both changes; they were committed together
> rather than split with history rewriting, `git add -p`, or artificial patches. Prompt 222 was
> analysis-only (design of the internal split); Prompt 220 was a read-only reassessment.

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

**Internal split milestone (Prompts 220–224):**

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

- **Local:** last full run = **407 passed / 0 failed / 0 skipped** (code state = `7af8b2f`, the
  current HEAD before this docs-only refresh). The +20 over the previous 387 = 4 new
  `ProductRealControlStateStoreTests` + 20 new `ProductRealStopCoordinatorTests` − 4 stop-callback
  tests moved out of `ProductRealControlCoordinatorTests`.
- **CI:** **green** at the last pushed state (GitHub Actions Build workflow, success).
- An earlier README-only commit had a one-off CI failure that **passed on rerun** (a flake).
- `xcodebuild test` exits `0` on pass, `65` on any test failure. Get exact counts from the newest
  result bundle:
  `xcrun xcresulttool get test-results summary --path "$(ls -td ./.DerivedData/Logs/Test/*.xcresult | head -1)"`

## 7. Known deferred / candidate items

- **N > 3** concurrent sessions — deferred.
- **`MARKETING_VERSION` bump / tag / public release** — deferred (stays `0.13`).
- **Core Audio property-listener (polling → HAL) migration** — deferred / research-only.
- **Broad `MixerViewModel` / `ProductRealControlCoordinator` extraction** — deferred.
- **`Info.plist` `NSHumanReadableCopyright`** — empty; deferred until owner/year confirmed
  (candidates: `Copyright © 2026 Ahmed Tuğra Kasem`, or owner-neutral `© 2026 MacMiniMixer
  contributors` — project is MIT-licensed).
- Candidates, not urgent: UI **accessibility polish**; direct **`SystemOutputCoordinator`
  failure-path tests**; **`MockAudioController` rename**; **localization**; **keyboard
  navigation**; **view/snapshot** and **integration** tests.

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
git grep -n "maxConcurrentLiveSessions" -- MacMiniMixer          # expect cap = 3
git grep -n "MARKETING_VERSION = 0.13" -- '*.pbxproj'            # expect present (unchanged)
```

Full test + Release build (when code changes):

```bash
xcodebuild test  -project MacMiniMixer.xcodeproj -scheme MacMiniMixer \
  -destination 'platform=macOS' -derivedDataPath ./.DerivedData CODE_SIGNING_ALLOWED=NO
xcodebuild build -project MacMiniMixer.xcodeproj -scheme MacMiniMixer -configuration Release \
  -destination 'platform=macOS' -derivedDataPath ./.DerivedData CODE_SIGNING_ALLOWED=NO
```

## 10. What remains & recommended next step

The Product Real **start** and **stop** paths are extracted, and the coordinator has begun an
**internal split**: state now lives in `ProductRealControlStateStore` and the stop path in
`ProductRealStopCoordinator`, both behind the unchanged facade (full suite green, 407). The next
internal target is `ProductRealStartCoordinator` (see below). First re-verify live state (§9) and
re-read the target methods in the repo — **do not trust the line numbers in this file; inspect the
repo.**

### What remains in `MixerViewModel` (intentional — the coordinator refactor is NOT "done")

`ProductRealControlCoordinator` owns Product Real **state + product-only start/stop logic**. The
view model remains the **cross-subsystem router and lifecycle/UI orchestration layer**, and these
responsibilities are deliberately staying there — they are not product-only, so moving them into a
product coordinator would *increase* coupling, not reduce it:

- `toggleExperimentalControl` — the row entry point (delegates start/stop to the coordinator).
- `stopProcessTapLiveControl` — the **product-vs-advanced-manual router** (product branch delegates
  to `coordinator.stopProductLiveSessions`); `handleAdvancedManualLiveControlStopped`.
- `applyLiveControlStoppedDisplay` + `showLiveControlWarningIfNeeded` — **shared** display cleanup
  used by both product and advanced-manual stops (reached from the coordinator through the seam).
- `tearDownAllProcessTapWork` — the global sleep/termination teardown **fan-out** (engine hard stop,
  two-app readiness, helper/probe, resolver invalidation, diagnostics/replay, advanced-manual reset,
  `cancelResolutionTask()`); only its Product Real state-reset sub-block delegates to
  `coordinator.tearDownProductStateForHardStop()`.
- `stopActiveAudioWorkForOutputDeviceChange` — the 5-subsystem output-device-change fan-out.
- `setExperimentalRealAppControlEnabled`, `handleSystemWillSleep` / `handleSystemDidWake` /
  `stopProcessTapLiveControlForTermination`, and `refreshApplications` / running-app orchestration
  (delegates only the app-exit product slice).
- Advanced diagnostics, helper discovery/probe, and Two-App Readiness orchestration.

Note also: the remaining `MixerViewModel` responsibilities above are genuinely cross-subsystem — do
**not** move the router, shared display, lifecycle entry points, or multi-subsystem fan-out into any
Product Real coordinator; that would pull non-product concerns into a product-scoped type.

### Next internal extraction: `ProductRealStartCoordinator`

The next target is to move the START + resolution path out of the facade into a
`ProductRealStartCoordinator`, mirroring the stop-coordinator extraction. It should contain:

- app-audio resolution (`startResolvedExperimentalControl`, `handleAppAudioTargetResolution`,
  `cancelAppAudioTargetResolution`, `cancelResolutionTask`);
- resolution-task ownership **and** the `deinit` cancellation of that task;
- Product Real start preflight (`productSessionStartBlockReason`);
- **both** `startExperimentalControl` overloads (sync preflight + async body);
- the async start body;
- cached-helper retry;
- stale-start cleanup (`cleanupStaleProductLiveStart`).

Constraints for that extraction:

- **Resolution must remain with Start** — they are bidirectionally coupled (Resolution → Start to
  launch; Start → Resolution for the cached-helper retry) and share per-app start-request tokens.
- **`ProductRealControlCoordinator` must remain the only facade `MixerViewModel` knows** — the
  facade's public API and `MixerViewModel` stay unchanged.
- **`ProductRealStopCoordinator` must not directly own or reference `ProductRealStartCoordinator`**
  (and vice-versa). The existing cross-edges stay **narrow closures** wired by the facade:
  start `onStopped` → stop's `handleProductLiveControlStopped`; start active-name refresh → stop's
  `updateActiveLiveControlAppNameAfterProductChange`; stop app-exit → start/resolution's
  `cancelResolution`. Both sub-coordinators share the one `ProductRealControlStateStore` by reference.
- Do a **read-only implementation-boundary reassessment** against the post-Stop architecture
  **before moving any code**, then implement in staged, test-backed, individually reviewable commits
  (new `ProductRealStartCoordinatorTests`; keep `MixerViewModelLiveControlTests` unchanged; no real
  sleeps; state mutation only through the shared store). After Start lands, slim the facade and do a
  final docs/handoff refresh.

Whatever the next step: do **not** release/tag or bump `MARKETING_VERSION`; keep the cap at 3 and
`N > 3` deferred.
