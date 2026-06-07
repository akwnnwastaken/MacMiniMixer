# MacMiniMixer Roadmap

Current repository state: v0.12 with Product Real App Control, Advanced diagnostics,
fake-backed tests, and incremental coordinator extraction in place.

This roadmap separates stable foundation, near-term low-risk work, later research, and
explicitly deferred large-scope ideas. It is intentionally conservative: MacMiniMixer is
not yet a finished Windows Volume Mixer replacement.

---

## Completed / Stable Foundation

- System output volume and mute controls.
- Output device listing and switching.
- Application discovery via the current app-listing path.
- Simplified menu bar mixer UI.
- Global Product Real App Control opt-in.
- Direct visible-PID Product Real Control for eligible apps such as Music/Spotify.
- Browser/helper-PID resolution for Safari/YouTube-style rows when global Real App
  Control is enabled and the user interacts with a row.
- Validation-first in-memory helper cache and early-accept fast path.
- Persistent Product Real App Control sessions while healthy.
- One-active-real-session Product limitation.
- Product Real Control lifecycle characterization tests.
- Product Real Control state/model helper extraction.
- Advanced Helper Process Discovery, manual helper Probe, Find audio helper, and
  Advanced helper target selection.
- Advanced Process Tap Test, Mute Probe, Replay Probe, manual Advanced Live Control,
  and Two-App Readiness.
- XCTest target with fake-backed coverage for helper discovery, helper resolver/cache,
  permission messaging, live session management, Product/Advanced live behavior,
  coordinators, Two-App Readiness, diagnostics accumulation, and output buffer copying.
- GitHub Actions build/test CI.
- MIT License.
- Shared `ProcessTapDiagnosticsAccumulator`.
- Shared `ProcessTapOutputBufferCopier`.
- Extracted coordinators:
  - `AdvancedHelperDiscoveryCoordinator`
  - `SystemOutputCoordinator`
  - `AdvancedProcessTapDiagnosticsCoordinator`
  - `AdvancedLiveControlCoordinator`
  - `TwoAppReadinessCoordinator`
- `CHANGELOG.md` with milestone history.
- Persistent read-only output-volume indicator for devices without a writable volume API.
- Accessibility labels/values/hints for app rows, system output controls, and output-device
  selection.
- Consolidated output-device-change teardown in `MixerViewModel`
  (`stopActiveAudioWorkForOutputDeviceChange`).

---

## Current Architecture and Hardening Status

- `MixerViewModel` remains the central traffic controller for app list/mock row state,
  Product Real Control orchestration, lifecycle cleanup, cross-feature coordination, and
  status messages.
- Product Real Control orchestration intentionally remains in `MixerViewModel` for now.
  The state/model helper extraction is complete, but a full coordinator extraction has
  not been justified yet.
- Product sessions use an indefinite timeout policy while healthy. Manual Advanced Live
  and diagnostic/readiness paths remain limited/short-lived.
- Helper mappings are validation-first, in-memory only, and not persisted across
  launches.
- No background helper scanning runs just because an app appears.
- Helper PID/process names stay hidden from the main mixer UI.
- Process Tap features are guarded for macOS 14.2+ while deployment target remains
  macOS 13.0.
- Safety constraints remain:
  - Public APIs only.
  - No HAL driver.
  - No persistent virtual audio device.
  - No private APIs.
  - No third-party dependencies.
  - No disk audio saving.
  - Product sessions remain one active real session at a time for now.

---

## Next Recommended Low-Risk Work

### Reassess Product Real Control after state/model extraction — done

**Priority**: High | **Risk**: Low | **Status**: Reassessed; coordinator deferred

Read-only reassessment complete. **Decision: do not extract a `ProductRealControlCoordinator`
yet** — the cluster is the central arbiter (~142 references), mutates four `@Published`
properties the panel and other VM logic share, and drives the Advanced diagnostics display.
Extraction would likely increase coupling/complexity. Full rationale and the conditions that
would change the decision are recorded in `docs/DECISIONS.md`. Low-risk simplifications that
fell out of the review were applied (pure `liveControlWarningMessage`, named app-refresh
teardown helpers, documented intentional double `beginSession`).

---

### Non-writable output-volume UX — done (follow-up optional)

**Priority**: High | **Risk**: Low | **Status**: Implemented

`SystemOutputCoordinator` now tracks per-device writability
(`isSystemOutputVolumeWritable`) and `MixerPanelView` shows a compact persistent
"Read-only" badge plus tooltip when the selected device rejects volume writes. Writability
resets when the selected device changes.

**Optional follow-up**: probe writability proactively on device refresh (instead of only
after a rejected write) so the badge appears before the user first drags the slider.

---

### Accessibility labels — done

**Priority**: Medium | **Risk**: Low | **Status**: Implemented

Explicit labels/values/hints added for app rows (volume slider, mute, Real/Resolving
state), the system output slider and mute button, and output-device selection rows.

**Optional follow-up**: SwiftUI accessibility/snapshot tests once a view-test harness
exists (see "UI-layer test coverage" below).

---

### System Settings permission affordance — done (follow-up optional)

**Priority**: Medium | **Risk**: Low | **Status**: Implemented

A compact "Open System Settings" button now appears in the Advanced Process Tap result line
when the outcome is `.permissionDenied`, opening the Privacy & Security pane via
`NSWorkspace`. It is deliberately not shown for `.missingUsageDescription` (a build-config
problem, not a user-fixable setting). The settings URL targets the Privacy & Security root
rather than a version-specific anchor for robustness across macOS versions.

**Optional follow-up**: surface the same affordance on the main transient status banner (not
just the collapsed Advanced section) for users who hit a permission denial while toggling
Real App Control. This needs `MixerStatusMessage` to carry an optional action.

---

### CHANGELOG and release-readiness cleanup — partially done

**Priority**: Low | **Risk**: Low | **Status**: `CHANGELOG.md` added

`CHANGELOG.md` now exists with milestone history and an `[Unreleased]` section. Remaining
work: keep it synchronized with each change and prepare conservative release notes without
implying production-grade multi-app mixer support.

**Likely files**: `CHANGELOG.md`, `README.md`, `docs/*`.

---

### Continue `MixerViewModel` cleanup

**Priority**: Medium | **Risk**: Low

`MixerViewModel` is still the largest file (~1.1k lines). The output-device-change teardown
was consolidated into `stopActiveAudioWorkForOutputDeviceChange`; continue collapsing other
repeated cross-feature cleanup patterns (app-refresh handling, termination teardown) into
named helpers before deciding on any further coordinator extraction. This is distinct from
the Product Real Control coordinator decision above — it is pure local simplification with
no behavior change, verified by the existing characterization tests.

**Likely files**: `MixerViewModel.swift`.

**Note**: The duplicated `beginSession` call in `startExperimentalControl` is intentional
(early optimistic set + post-`await` re-assertion) and is now documented inline. Do not
"simplify" it away without re-checking the suspension-point behavior.

---

### Diagnostic tooling inventory and sunset decision

**Priority**: Medium | **Risk**: Low (decision) / Medium (if removing code)

The Advanced section now carries a large surface: Process Tap Test, Mute Probe, Replay
Probe, Two-App Readiness, Helper Discovery, manual Probe, and auto-detect. Several of these
exist to gather feasibility evidence rather than as permanent product features, and they
account for a large share of the codebase and maintenance cost.

**Decision point**: For each Advanced tool, decide whether it is (a) a permanent product
feature, (b) evidence-gathering that can be removed once its question is answered, or (c)
developer-only and movable behind a debug flag. Record outcomes in `docs/DECISIONS.md`.
Do not remove anything until its purpose is explicitly reclassified.

**Likely files**: `docs/DECISIONS.md`, Advanced views/services.

---

### UI-layer test coverage

**Priority**: Low | **Risk**: Low

All 164 tests target view models, coordinators, and services. SwiftUI views
(`MixerPanelView`, `ProcessTapTestView`, etc.) have no automated coverage. Investigate a
lightweight accessibility/snapshot harness so view regressions (including the new
accessibility labels) are caught.

**Likely files**: new test target/helpers, `MacMiniMixerTests/*`.

---

## Later Research / Experimental Work

### Helper PID-change hardening

**Priority**: High | **Risk**: Medium

Helper PIDs can change after browser navigation, tab close/reopen, helper restart, or app
updates. Current cache validation and failure cleanup are conservative, but active-session
recovery is still manual/user-triggered.

**Research questions**:
- Should a stopped helper session offer a fresh resolution retry?
- Can PID changes be detected without background probing?
- How should the UI explain browser/helper instability without exposing helper names?

---

### Two-App Readiness repeatability and latency characterization

**Priority**: Medium | **Risk**: Medium

Continue measuring callbacks, peak/RMS, queued buffers, drops, failures, cleanup behavior,
and latency across more eligible app combinations and repeated runs.

**Goal**: Use this only as Advanced diagnostic evidence, not as a shortcut to main UI
multi-app control.

---

### Experimental per-app volume boost

**Priority**: Low | **Risk**: High | **Status**: Later research / experimental

Product Real App Control may eventually allow an eligible selected app to be amplified
above its original audio level, with a research target of up to 200%.

**User value**: Mute, reduce, or experimentally boost applications that provide no
built-in volume controls.

Constraints:
- Off by default.
- Separate explicit opt-in from normal 0-100% control.
- Public Process Tap/Core Audio APIs only.
- No HAL driver, persistent virtual audio device, private APIs, third-party dependencies,
  or disk audio saving.
- Preserve the one-active-real-session limitation initially.
- Affect only the selected application.
- Do not boost system output volume.
- Do not affect unrelated applications.
- Test direct visible-PID and browser/helper-PID paths separately.
- Warn users before enabling gain above 100%, especially with headphones.

Before implementation, require a read-only assessment of current gain mapping, headroom,
clipping, distortion, hard clipping versus limiter or soft-clipping options, CPU, latency,
long-session resources, repeated gain updates, sleep/wake behavior, output changes,
app/helper exit cleanup, and Core Audio failure recovery.

Treat 200% as a research target, not a promise of clean output. Start later with
characterization tests and a narrowly scoped experimental mode.

---

### Sleep/wake and long-running resource characterization

**Priority**: Medium | **Risk**: Medium

Product sessions can now persist while healthy. Characterize behavior across sleep/wake,
long idle periods, output-device changes, app exit, helper exit, and Core Audio failure.

---

### Release packaging and distribution

**Priority**: Medium | **Risk**: Low-Medium

Investigate a direct-distribution package such as a notarized `.zip` or `.dmg`. Keep this
separate from runtime audio behavior.

---

## Explicitly Deferred Large-Scope Work

These are not immediate tasks.

- Full simultaneous multi-app Product Real Control.
- Centralized mixer/renderer architecture.
- HAL driver, plug-in, or system extension.
- Persistent virtual audio device.
- Large Core Audio redesign.
- Installer/uninstaller work required by any future persistent system component.

The current direction remains: preserve the public-API Process Tap approach, keep Product
control one-active-session-at-a-time, validate behavior with tests/manual diagnostics, and
avoid broad audio-path rewrites unless evidence shows they are necessary.
