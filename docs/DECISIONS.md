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

## Why `MixerViewModel` is not yet split

**Decision**: All coordinator logic lives in one `@MainActor` class.

**Reasoning**:
- A split was not attempted yet because the boundaries between subsystems are still
  shifting as features are added (e.g., helper resolution interacts with live control
  state in several places).
- An incorrect split creates inter-coordinator dependencies that are harder to reason
  about than a single monolithic class.
- The current size (~1900 lines) is large but still navigable with good naming.

**Would revisit**: This is explicitly on the roadmap. The plan is to extract one
coordinator at a time, starting with the most self-contained subsystem (helper discovery
or Two-App Readiness), validate the pattern, then proceed.
