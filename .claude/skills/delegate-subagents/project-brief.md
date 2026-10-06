# MacMiniMixer — brief for subagents

Native Swift + SwiftUI macOS menu bar per-app volume mixer (Core Audio Process Taps).
Xcode project, no third-party dependencies, public APIs only.

## Environment
- Cloud sessions run on Linux: **no Swift compiler, no Xcode**. Your code is first compiled by
  GitHub Actions (Xcode 16, macos-15) or by the owner locally. A compile error costs a full round
  trip, so: verify every type, method and signature by reading the source; grep every call site,
  protocol conformer and test fake you affect; re-read your whole diff for compile errors before
  committing. CI runs only for pull requests, pushes to `main`, and manual runs (not for other
  branch pushes or tags), and macOS minutes count 10x on this private repo.
- Swift 5 language mode, deployment target **macOS 13.0**; Process Tap code is guarded with
  `@available(macOS 14.2, *)`. SwiftUI APIs must exist on macOS 13.
- Tests must be deterministic: no real sleeps; reuse the suites' existing gates, continuations
  and deadline-bounded waits.
- Do not push, trigger, wait for, or poll GitHub Actions — CI may be unavailable (out of macOS
  minutes). Finish with a committed, carefully self-reviewed change; the parent verifies it.

## If you are in a worktree
Run `git reset --hard <base given in your prompt>` first and confirm with `git log --oneline -1`.

## Guardrails
- No private APIs, no HAL driver / virtual device, no audio written to disk.
- Don't touch without an explicit ask: the audio callback paths (`ProcessTapDirectOutputRenderer` /
  direct IOProc, legacy `ProcessTapLegacyAudioQueueOutput.swift`), `ProcessTapLiveGainRamp`, `ProcessTapResourceContext.cleanup()`, `AppConstants` timing values.
- Don't reintroduce a default-output Core Audio property listener (it once left system audio
  silent until `sudo killall coreaudiod`).
- No app-count limit for Product Real Control (owner decision) — don't add a cap.
- Don't bump `MARKETING_VERSION`, tag, or release.
- New `.swift` files need 4 manual `project.pbxproj` entries — prefer adding to existing files.
- Docs (README, CHANGELOG, docs/*) are updated only when your prompt asks.

## Where things are
- Architecture and history: `docs/HANDOFF.md` §4, `docs/ARCHITECTURE.md` — read only the
  sections your task needs.
- Product Real: `ProductRealControlCoordinator` (facade) → `ProductRealControlStateStore`,
  `ProductRealStartCoordinator` (start lane, resolution), `ProductRealStopCoordinator`; seam in
  `ProductRealControlSideEffects.swift`; `MixerViewModel` is the cross-subsystem router.

## Finish
- Commit with a clear message ending with exactly the attribution lines given in your prompt
  (Co-Authored-By / Claude-Session); do not invent or reword them. Do not push unless told to.
- Report in ≤ 15 lines: worktree path, branch, commit SHA, files changed, behavior summary,
  tests added/changed, and any spot you are not sure compiles.
