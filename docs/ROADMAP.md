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

### Reassess Product Real Control after state/model extraction

**Priority**: High | **Risk**: Low

Do a read-only reassessment of the Product Real Control cluster now that pure state/model
helpers have been extracted.

**Decision point**: Decide whether a narrow `ProductRealControlCoordinator` is justified.
Do not assume the extraction must happen. If the benefit does not justify the risk, leave
working Product orchestration in `MixerViewModel`.

**Likely files**: `MixerViewModel.swift`, `ProductRealControlState.swift`,
`MixerViewModelLiveControlTests.swift`.

---

### Non-writable output-volume UX

**Priority**: High | **Risk**: Low

Some output devices do not expose a writable volume API. The app already surfaces short
warnings; improve discoverability with a compact persistent indicator, tooltip, or clearer
status affordance.

**Likely files**: `SystemOutputCoordinator.swift`, `MixerPanelView.swift`,
`OutputDeviceSelectorView.swift`.

---

### Accessibility labels

**Priority**: Medium | **Risk**: Low

Add explicit labels/hints for app rows, sliders, mute buttons, Real/Resolving state, and
output-device controls.

**Likely files**: `MixerAppRowView.swift`, `MixerPanelView.swift`,
`OutputDeviceSelectorView.swift`.

---

### System Settings permission affordance

**Priority**: Medium | **Risk**: Low

Permission-denied messages are clearer now. Add a safe, compact affordance or link to
System Settings for System Audio Recording if a public and non-surprising path is
available.

**Likely files**: `ProcessTapPermissionMessage.swift`, Advanced views,
`MixerPanelView.swift`.

---

### CHANGELOG and release-readiness cleanup

**Priority**: Low | **Risk**: Low

Add `CHANGELOG.md`, keep docs synchronized with code, and prepare conservative release
notes without implying production-grade multi-app mixer support.

**Likely files**: `CHANGELOG.md`, `README.md`, `docs/*`.

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
