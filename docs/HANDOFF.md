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

- **Code layout (staged coordinator extraction) — `ProductRealControlCoordinator` now owns the
  Product Real START and STOP paths:**
  - `ProductRealControlState` (the session/pending/resolution value type).
  - App-audio resolution task + resolution handling (`startResolvedExperimentalControl`,
    `handleAppAudioTargetResolution`, `cancelAppAudioTargetResolution`, `cancelResolutionTask`).
  - Stale-start cleanup (`cleanupStaleProductLiveStart`).
  - Start preflight + resolved-start path + **both `startExperimentalControl` overloads**
    (the sync preflight and the async start body).
  - `productSessionStartBlockReason` (cap/mutual-exclusion decision) and
    `updateActiveLiveControlAppNameAfterProductChange` (shared active-name helper).
  - **STOP path (Prompts 215–218):** `stopExperimentalControl(for:reason:)` (per-app stop leaf),
    `stopProductLiveSessions(reason:)` (Stop All product core), `handleProductLiveControlStopped(...)`
    (engine stop callback), `stopRealControlForExitedTargetApps()` (app-exit product slice), and
    `tearDownProductStateForHardStop()` (the Product Real state-reset sub-block of hard teardown).
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
    `isExperimentalRealAppControlEnabled`, `advancedManualLiveControlActive`, `selectedProcessTapAppID`,
    `isTwoAppReadinessRunning`, `isProcessTapTesting`, `isHelperBusy`, `isAppAudioTargetResolving`,
    `isProcessTapLiveControlActive`, `processTapLiveDiagnostics` (added Prompt 216 for the Stop All
    no-active-session display path).
  - `MixerViewModel` conforms to both; the coordinator holds them **weakly** (the VM owns the
    coordinator, so a strong back-reference would be a retain cycle).
- **Coordinator init / IUO note:** `MixerViewModel` stores the coordinator as an implicitly-unwrapped
  `ProductRealControlCoordinator!`, assigned at the **end of `init`** once `self` (the seam) is fully
  initialized. This is deliberate and load-bearing: eager assignment guarantees `setOnWillChange` is
  wired before any state mutation. Nothing reads the state during `init`, so the IUO is never accessed
  while nil. Do **not** convert it to `lazy` (a lazy coordinator could be created on first state
  access before the change handler is installed, dropping a UI update).
- **Why `ProductRealControlState` change notifications still work:** the state moved out of the VM's
  `@Published`. The coordinator owns it and exposes a get/set `productRealControlState` property that
  fires `onWillChange` **before every write**; the VM wires
  `coordinator.setOnWillChange { objectWillChange.send() }` in `init`, so a mutating call still emits
  exactly one `objectWillChange` (matching the old `@Published willSet`). The VM keeps a forwarding
  computed `productRealControlState` so all its existing call sites are unchanged.
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

Most recent (the staged `ProductRealControlCoordinator` **stop-path** extraction, Prompts 215–218):

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

- **Local:** last full run = **387 passed / 0 failed / 0 skipped** (code state = `d212fdf`, the
  current HEAD before this docs-only refresh).
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

The staged Product Real **start** and **stop** paths are now both fully extracted into
`ProductRealControlCoordinator` (full suite green, 387). First re-verify live state (§9) and
re-read the target methods in `MixerViewModel.swift` — **do not trust the line numbers in this
file; inspect the repo.**

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

### Recommended next step (conservative): **stop here — the coordinator boundary is healthy**

The Product Real start/stop extraction has reached a clean, stable boundary. The remaining
`MixerViewModel` responsibilities are genuinely cross-subsystem (router, shared display, lifecycle
entry points, multi-subsystem fan-out) — **do not** move them into `ProductRealControlCoordinator`;
that would pull non-product concerns into a product-scoped type. If further `MixerViewModel` cleanup
is desired, prefer a **read-only size/dead-code reassessment** (identify now-thin delegating members
and any dead code left by the extraction) before committing to any new extraction, and only extract
another **self-contained, clearly product-only** helper if one is found. Any such step must stay
behind the unchanged `MixerViewModelLiveControlTests` plus new coordinator tests, use the
recorded-fake + `waitUntil` observable-wait pattern (no real sleeps), route state mutation through
`coordinator.productRealControlState` (never raw state), and touch no new seam member unless
unavoidable — stop and report if it does.

Whatever the next step: do **not** release/tag or bump `MARKETING_VERSION`; keep the cap at 3 and
`N > 3` deferred.
