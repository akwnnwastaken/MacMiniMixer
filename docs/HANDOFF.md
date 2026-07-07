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

```
3cefcf7 Add UI-level guard for rapid Product Real toggles      (Prompt 194)
cb7f98e Fix audit-confirmed Swift 6 and documentation issues   (Prompt 193)
fd1c973 Perform low-risk v0.15 cleanup                          (Prompt 192)
4fbca1a Refresh README to v0.14 internal Product Real checkpoint(Prompt 191)
aca855b Reframe v0.14 notes as unreleased internal checkpoint   (Prompt 190)
f6fcad8 Add v0.14 release notes                                 (Prompt 189)
febb628 Document v0.14 Product Real long-run smoke result       (Prompt 188)
00da311 Document Product Real teardown/starvation hardening checkpoint
0f5652a Make MixerViewModel live-control test waits deadline-bounded (Prompt 185)
c0f8ad4 Fix Swift 6 async locking in lifecycle serialization tests   (Prompt 184)
88bbed5 Harden Product Real teardown and starvation handling   (P177–P182 bundle)
83b8dd9 Add long-run three-session characterization checklist
```

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

- **Local:** last full run = **315 passed / 0 failed / 0 skipped** (after Prompt 194).
- **CI:** **green** for `3cefcf7` (GitHub Actions Build workflow, success).
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

With Prompt 194 committed and CI green, the safest next moves are docs/verification, not code:
keep this handoff and the ROADMAP/CHANGELOG/checklist current, and run the real-device rapid-toggle
smoke in `docs/MANUAL_TEST_CHECKLIST.md` §18. Do **not** release/tag or bump `MARKETING_VERSION`.
