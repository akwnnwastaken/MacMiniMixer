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
  Product Real START path:**
  - `ProductRealControlState` (the session/pending/resolution value type).
  - App-audio resolution task + resolution handling (`startResolvedExperimentalControl`,
    `handleAppAudioTargetResolution`, `cancelAppAudioTargetResolution`, `cancelResolutionTask`).
  - Stale-start cleanup (`cleanupStaleProductLiveStart`).
  - Start preflight + resolved-start path + **both `startExperimentalControl` overloads**
    (the sync preflight and the async start body).
  - `productSessionStartBlockReason` (cap/mutual-exclusion decision) and
    `updateActiveLiveControlAppNameAfterProductChange` (shared active-name helper).
- **Still in `MixerViewModel` (STOP + lifecycle + shared/router):**
  - `toggleExperimentalControl` (row entry point) — calls `coordinator.startExperimentalControl`
    on start; still calls the VM's own `stopExperimentalControl` on stop.
  - `stopExperimentalControl` (per-app stop leaf) — **the next thing to move (Prompt 215)**.
  - `stopProductLiveSessions` (Stop All product), `handleProductLiveControlStopped` (stop callback),
    `stopRealControlForExitedTargetApps` (app-exit product slice).
  - `stopProcessTapLiveControl` (router: product vs advanced-manual), `handleAdvancedManualLiveControlStopped`.
  - `applyLiveControlStoppedDisplay` + `showLiveControlWarningIfNeeded` (**shared** display cleanup
    used by both product and advanced-manual stops — do not move into the product coordinator).
  - `setExperimentalRealAppControlEnabled` (global Real-off command), `stopActiveAudioWorkForOutputDeviceChange`
    (5-subsystem output-change fan-out), `tearDownAllProcessTapWork` (global sleep/termination teardown),
    `handleSystemWillSleep` / `handleSystemDidWake` / `stopProcessTapLiveControlForTermination`.
- **The seam** (`MacMiniMixer/Features/Mixer/ProductRealControlSideEffects.swift`):
  - `ProductRealControlSideEffects` (write/callback side, coordinator → VM): `showProductRealStatus`,
    `setActiveLiveControlAppName`, `setProcessTapLiveDiagnostics`, `setLiveControlDiagnosticResult` /
    `Progress` / `Running`, and `handleProductLiveControlStopped` (routes the engine `onStopped`
    back to the VM's still-resident handler).
  - `ProductRealControlContext` (read side, VM → coordinator): `apps`,
    `isExperimentalRealAppControlEnabled`, `advancedManualLiveControlActive`, `selectedProcessTapAppID`,
    `isTwoAppReadinessRunning`, `isProcessTapTesting`, `isHelperBusy`, `isAppAudioTargetResolving`,
    `isProcessTapLiveControlActive`.
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

Most recent (the staged `ProductRealControlCoordinator` **start-path** extraction, Prompts 205–214):

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
  smallest step (see §10). **215 is not yet implemented.**

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

- **Local:** last full run = **371 passed / 0 failed / 0 skipped** (code state = `92a82c3`; the
  current HEAD `c12aa73` is docs-only and does not change the count).
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

## 10. Recommended next step

The Product Real **start** path is fully extracted (full suite green, 371). Prompt 214 analyzed the
**stop/lifecycle** migration and chose the smallest safe next step, recorded below. First re-verify
live state (§9) and re-read the target methods in `MixerViewModel.swift` — **do not trust the line
numbers in this file; inspect the repo.**

### Next implementation: per-app Product Real stop leaf (Prompt 215)

**Move ONLY `stopExperimentalControl(for:reason:)`** from `MixerViewModel` into
`ProductRealControlCoordinator`. It is the single fully product-only stop method whose every
dependency is already in the coordinator (`productRealControlState`, `liveSessionManager.stopSession`,
`startSettleGate.registerStop`, and the coordinator-owned `updateActiveLiveControlAppNameAfterProductChange`).
No new seam is needed.

- **Behavior to preserve exactly:**
  - clear this app's pending start request, then read its `liveSessionID`;
  - if **no** `liveSessionID` (optimistic window / not active): clear the session locally, call
    `updateActiveLiveControlAppNameAfterProductChange()`, and **return without** calling `stopSession`;
  - if a `liveSessionID` exists: `beginOperation(for: appID)` (rapid-toggle pending flag), then a
    `Task { await liveSessionManager.stopSession(id: sessionID, reason: reason) }` registered with
    `startSettleGate.registerStop(...)`;
  - default `reason` is `.userStopped`; ordering identical.
- **Known VM callers to update (both stay in `MixerViewModel`):**
  - `toggleExperimentalControl` (stop branch) → `coordinator.stopExperimentalControl(for: appID)`.
  - `stopRealControlForExitedTargetApps` → `coordinator.stopExperimentalControl(for: exitedAppID, reason: .targetAppExited)`.
- **Must NOT move in this step:** `stopProductLiveSessions`, `handleProductLiveControlStopped`,
  `stopRealControlForExitedTargetApps` (stays; just delegates), `stopProcessTapLiveControl` router,
  `applyLiveControlStoppedDisplay`, `showLiveControlWarningIfNeeded`, `handleAdvancedManualLiveControlStopped`,
  Stop All / global fan-out, lifecycle / sleep / wake / termination / output-device-change teardown,
  audio-callback code.
- **Expected files:** `MacMiniMixer/Features/Mixer/ProductRealControlCoordinator.swift`,
  `MacMiniMixer/Features/Mixer/MixerViewModel.swift`, `MacMiniMixerTests/ProductRealControlCoordinatorTests.swift`.
  No new files → **no pbxproj change expected** (all three are already registered).
- **Required coordinator tests (deterministic, no sleeps — the fake `liveSessionManager` records
  `stopSession(id:reason:)`):**
  1. `testStopExperimentalControlStopsSessionByIDWithReason` — active session with a `liveSessionID`
     → `stopSession(id:reason:)` recorded with the correct id + reason (settle-gate registration too
     if the fake exposes it).
  2. `testStopExperimentalControlOptimisticWindowClearsLocallyWithoutStopSession` — session without
     `liveSessionID` → session cleared locally, **no** `stopSession` call.
  3. `testStopExperimentalControlMarksOperationPendingForLiveSessionStop` — active session with
     `liveSessionID` → `productRealControlState.isOperationPending(appID)` is true after the call
     (cleared later by the stop callback).
  Existing `MixerViewModelLiveControlTests` must remain green **unchanged**.

**Subsequent staged steps (later prompts, per Prompt 214 / `docs/DECISIONS.md`):** S2 = product stop
core (`stopProductLiveSessions` + `handleProductLiveControlStopped`, which needs a new
`applyLiveControlStoppedDisplay` seam callback + a `processTapLiveDiagnostics` context read); S3 =
`stopRealControlForExitedTargetApps`; S4 = the product-state hard-teardown slice inside
`tearDownAllProcessTapWork`. The router, fan-outs, lifecycle entry points, and shared display helpers
stay in `MixerViewModel`.

### Rollback / stop conditions

- If the move requires a new seam, mutating raw coordinator state (bypassing `onWillChange`), or any
  change to a shared display helper or the router → **stop and report**; the leaf move should need none
  of these.
- If any existing `MixerViewModelLiveControlTests` fails, or the settle-gate / pending-op ordering
  changes → revert and reassess (don't force it).
- Never introduce a real sleep in tests; use the recorded-fake + `waitUntil` observable-wait pattern
  already in `ProductRealControlCoordinatorTests`.

Either way: do **not** release/tag or bump `MARKETING_VERSION`; keep the cap at 3 and `N > 3`
deferred.
