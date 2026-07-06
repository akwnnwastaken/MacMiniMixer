# MacMiniMixer

MacMiniMixer is a native Swift + SwiftUI macOS menu bar audio utility inspired by the Windows Volume Mixer. It is designed as an open-source, technical macOS project for users who understand experimental system-level audio tools.

The app is not targeting the Mac App Store. It uses native macOS APIs directly, avoids private APIs, and currently has no third-party dependencies.

## Current Status

MacMiniMixer is at an **internal v0.14 Product Real stability checkpoint**. This is an unreleased,
internal checkpoint — **not** a public release: no tag has been cut and the app's marketing version
is unchanged. It remains experimental and is not a finished Windows Volume Mixer replacement.

What works today:

- Real system-level output controls: system output volume read/set with live sync, mute-to-zero with
  restore, real default output device listing/switching, and live device refresh (including sync when
  the default output changes externally, such as connecting AirPods).
- Real running-application discovery with app icons.
- **Product Real Control** — real per-app control using a Core Audio **Process Tap** with audio
  replay and gain — supporting **up to 3 concurrent Real sessions** (`maxConcurrentLiveSessions = 3`).
  When the global Real App Control toggle is ON, interacting with an eligible app row starts a real
  session for that row; up to three rows can be Real at once, and the active banner summarizes three
  or more apps as "first two names +1 more" with "Stop All".
- Browser/helper-row resolution (YouTube/Safari-style rows whose visible PID is not tap-eligible)
  behind the global toggle and only after explicit interaction, keeping helper PIDs/process names
  hidden from the main UI.
- A collapsed Advanced section with Process Tap diagnostics, Mute/Replay probes, manual one-app Live
  Control, helper discovery, and a separate two-session Two-App Readiness diagnostic.

Stability checkpoint status:

- The Product Real teardown/starvation path was hardened: process-tap destroy retry with fault
  reporting, output-queue disposal after IOProc stop/destroy, a stop→start settle gate, Core Audio
  lifecycle serialization, and starvation gating so silent apps show a neutral "Waiting for app
  audio" state and a freshly (re)started queue's startup transient is not reported as a real
  underrun. See `CHANGELOG.md` (`[v0.14] - Unreleased`) for details.
- A normal-use three-session long-run smoke **passed (with caveat)** on one Mac: Drops/Fail/Starv
  stayed 0 during normal use and no `sudo killall coreaudiod` was needed.
- Going beyond three concurrent sessions (`N > 3`) remains deferred, and Product Real Control remains
  experimental.

What is still mock / UI-only:

- Normal per-app row sliders and mute controls, when Real Control is not active for that row, are
  **UI-state/preview only** — they do not change any app's real per-app audio. Only the system output
  slider changes real audio (at the system level), and only an **active** Product Real row drives
  real per-app gain through the Process Tap. `MockAudioController` backs those preview values and the
  cached system-volume display; it does **not** mean the app's real audio paths are fake — system
  output volume and Product Real Control are both real Core Audio.

Advanced helper diagnostics can scan helper/content process candidates for visible apps such as
Safari or YouTube, probe them for audio (e.g. `com.apple.WebKit.GPU`), and select the best
audio-carrying helper — manually or via the `Find audio helper` auto-detect flow — so Process Tap
Test, Replay Probe, and Two-App Readiness can run against that helper PID. Helper mappings use a
validation-first in-memory cache, are not persisted across launches, and no background scanning
starts merely because an app appears.

## Features

- Native macOS menu bar app using SwiftUI `MenuBarExtra`
- Compact liquid/glass-style mixer panel
- Simplified main mixer panel focused on output, app rows, and active control state
- Real running application list using `NSWorkspace`
- Real app icons where macOS provides them
- Audio-relevant app list with `Show all`
- Real output audio device listing using public Core Audio APIs
- Filtering for obvious virtual/app-created output devices in the normal selector
- Live refresh of output devices while the panel/selector is open
- UI sync when the real default output changes externally, such as connecting AirPods
- Real macOS default output device switching
- Real current system output volume reading
- Live system output volume sync while the panel is open
- Real system output volume setting from the `System Output` slider
- System output mute/unmute using volume-to-zero plus restore behavior
- Preview (UI-state) per-app sliders and mute controls when Real Control is not active for a row
- Collapsed Advanced diagnostics section, hidden by default
- Experimental Process Tap Test UI inside Advanced
- Running app selection for Process Tap diagnostics
- Short-lived Process Tap diagnostics for selected apps
- Live diagnostic level meter during the test
- Callback count, peak, and RMS reporting
- Experimental Mute Probe that may briefly suppress the selected app during a user-triggered test
- Experimental Replay Probe with fixed gain choices: 25%, 50%, 75%, and 100%
- Experimental one-app Live Control session with Start/Stop, selected gain, smoothing, safety timeout, and cleanup
- Internal `ProcessTapLiveSessionManager` foundation for future multi-session work
- Advanced Two-App Readiness test for short-lived multi-session diagnostics
- Isolated Advanced readiness path with up to two short-lived diagnostic live sessions
- Per-session Two-App Readiness diagnostics: app name, state, callbacks, peak/RMS, queued buffers, drops, failures, and gain
- `Stop All` for the Two-App Readiness test
- Core Audio tap-eligible app filtering for the Two-App Readiness pickers
- Advanced Helper Process Discovery for browser/helper/content process candidates
- Manual helper candidate audio probe for identifying which helper process carries audio
- `Find audio helper` auto-detect flow for selecting the best audio-carrying helper candidate
- Browser/helper row resolution in the main mixer behind global Real App Control
- Hidden helper PID mapping for YouTube/Safari-style rows after explicit slider/mute interaction
- Validation-first in-memory helper cache with no persistence across app launches
- Manual Advanced helper target selection
- Process Tap Test against an Advanced helper target
- Replay Probe against an Advanced helper target
- Two-App Readiness with a visible app plus one selected Advanced helper target
- Compact `Real app control` toggle, OFF by default
- Slider interaction can start real per-app control when the global mode is enabled
- Up to three active experimental app rows at a time (Product cap = 3); `N > 3` deferred
- Active row slider controls real experimental Process Tap gain
- Active row mute maps to experimental gain 0
- Menu bar active indicator and compact panel active banner while real app control is active
- Active banner summarizes three or more Real apps as "first two names +1 more" with `Stop All`
- Non-active app rows remain preview/UI-state only
- MIT License
- GitHub Actions build/test CI
- XCTest target with fake-backed unit and characterization tests

## Real vs Mock-Only

Stable system output features:

- Menu bar app and mixer panel
- Running app discovery
- App icon display
- Output audio device discovery
- Default output device switching
- Output device refresh and external default-output sync while the panel/selector is open
- System output volume read, live sync, set, mute-to-zero, and restore

Experimental Process Tap features:

- Short-lived Process Tap diagnostics that can detect selected app audio
- Diagnostic callback count, peak, RMS, and live level meter
- Mute Probe that can briefly suppress selected app audio during a user-triggered test
- Replay Probe that can capture selected app audio, suppress original output, apply fixed gain, replay through `AudioQueue`, and clean up
- One-app Live Control that applies a selected fixed gain while active, with Start/Stop smoothing and a 60-second safety timeout
- Manual one-app Live Control remains available from Advanced when global real app control is OFF
- Global Experimental Real App Control mode that can start real sessions for eligible rows (up to three concurrently) from slider/mute interaction
- While a row is active, that row's slider controls experimental live gain and that row's mute maps to gain 0
- Browser/helper row resolution for one YouTube/Safari-style row after user interaction when global Real App Control is ON
- Validation-first in-memory helper cache for previously resolved helper PIDs
- Advanced Two-App Readiness diagnostic that can run two explicit, short-lived readiness sessions with per-session diagnostics
- Advanced Helper Process Discovery that can find tap-eligible helper/content processes for visible browser/web apps
- Advanced helper auto-detect that sequentially probes eligible candidates and selects the strongest detected audio helper
- Advanced helper targets that can be tested with Process Tap Test, Replay Probe, and Two-App Readiness

Mock-only today:

- App row volume sliders when the global mode is OFF, unless manual Live is started from Advanced
- App row mute controls when the global mode is OFF, unless manual Live is started from Advanced
- Non-active app row sliders and mute controls
- Real control beyond three concurrent rows (`N > 3`)
- Browser/helper targets as main UI rows
- General multi-app per-application audio routing, replay, gain, or modification

By default, the global Real app control mode is OFF. In that mode, app rows are UI state only unless the user explicitly starts manual Live control from Advanced. Moving a normal row slider does not change Safari, Music, Spotify, Chrome, Discord, or any other app's real audio.

When the global mode is ON, moving an eligible app row slider or clicking mute on an eligible inactive row can start a real experimental Process Tap live session for that app. Up to **three** apps can be Real at the same time (`maxConcurrentLiveSessions = 3`); interacting with another eligible app starts an additional session, and attempting a fourth shows a "Real app control supports 3 apps at a time" warning rather than silently switching. For visible tap-eligible apps, this uses the visible app PID directly. For YouTube/Safari-style browser rows whose visible PID is not tap-eligible, MacMiniMixer may resolve an audio helper PID internally after the user interaction, keep the row labeled as the visible app, and hide helper PID/process details from the main UI. For each active row the app's audio is captured, the original stream is suppressed, processed audio is replayed, the row slider maps to live gain, and the row mute maps to gain 0. Non-active rows remain preview/UI-state only.

The Advanced diagnostics section can create short-lived Core Audio process tap diagnostics for a selected running app. During diagnostic tests, it creates temporary private Core Audio resources, shows a live diagnostic level meter, reports callback count plus peak/RMS levels, and then cleans up.

The Advanced Two-App Readiness test is separate from the main mixer. It uses an isolated readiness configuration with `maxSessions = 2`, requires explicit user start, runs for a short timeout, currently 10 seconds, and provides `Stop All`. It can use visible apps whose PID translates to a Core Audio process object, and it can also use one manually selected Advanced helper target. Music + Spotify have run together successfully in testing with callbacks, peak/RMS, queued buffers, and zero drops/failures observed. Spotify + a YouTube helper target has also run successfully in Advanced diagnostics. This remains prototyping-only and is not exposed as production multi-app row control.

Safari, YouTube, and other browser/web surfaces may not be tap-eligible through the visible app PID because their audio can be rendered by helper/content processes instead of the visible app process. In the main product path, helper resolution is available only behind the global Real App Control toggle and only after user interaction. In Advanced, helper targets remain manually selectable or auto-detected for diagnostics. Helper mappings are not persisted across app launches.

Replay Probe, manual Live Control, and global opt-in row control go further: they can temporarily suppress the selected app's original output, replay captured audio through `AudioQueue`, and apply gain. These paths are experimental and user-triggered. Replay Probe and the Advanced manual Live Control are one-app; global opt-in Product Real Control supports up to three concurrent Real sessions. None of them make every row a real mixer control.

The app includes `NSAudioCaptureUsageDescription` for system audio capture experiments. It does not request system audio recording permission on launch. macOS may ask for System Audio Recording permission when the user explicitly runs a diagnostic or live control action.

## Architecture Notes

Product Real Control runs up to three concurrent live sessions through `ProcessTapLiveSessionManager`;
each session owns its own Core Audio process tap, private aggregate device, IOProc, and replay
`AudioQueue`.

- `ProcessTapLiveSessionManager` wraps the Core Audio live controller and tracks per-session state.
- `ProcessTapLiveSessionID` and `ProcessTapLiveSessionState` back per-session tracking.
- The Product cap is `maxConcurrentLiveSessions = 3`; going beyond three (`N > 3`) is deferred.
- Global Real App Control and Advanced manual Live Control both route through this manager-backed path.
- Product Real create/destroy operations are serialized and gated (stop→start settle + startup
  warmup) so overlapping teardown/setup does not churn the shared Core Audio route.
- Advanced Two-App Readiness uses a separate isolated manager/configuration with `maxSessions = 2` for diagnostics only.
- Browser and web audio may be rendered by helper/content processes rather than the visible app PID.
- Helper process PIDs can change as tabs, pages, and browser helpers restart.
- MacMiniMixer can resolve a browser/web-style main row to a helper PID internally after user interaction when global Real App Control is ON.
- The main UI continues to show the visible app name and hides helper process names/PIDs.
- Helper resolution uses a validation-first in-memory cache keyed by the visible app identity/PID.
- Cached helper mappings are reused only after validating PID existence and Core Audio tap eligibility.
- Helper mappings are not persisted across app launches and are not refreshed by background scanning.
- `Find audio helper` is Advanced-only and uses short unmuted diagnostic probes to rank eligible helper candidates.
- Advanced helper target state is manual, temporary, Advanced-only, and not currently persisted across launches.
- Helper-target diagnostics currently help evaluate feasibility; they are not a stable tab-level browser mapping layer.
- Result handling now uses typed outcomes/status values rather than comparing user-facing message strings for control flow.
- Process Tap resource cleanup is guarded for idempotent, thread-safe cleanup.
- Process Tap availability is guarded so Process Tap features require macOS 14.2 or later while non-Process-Tap app features can still be built with the macOS 13.0 deployment target.
- Shared Process Tap diagnostics accumulation keeps callback/peak/RMS semantics consistent.
- Shared Process Tap output buffer copying covers Float32 interleaved/planar sample copying while Replay and Live `AudioQueue` owners remain separate.
- `AdvancedHelperDiscoveryCoordinator` owns helper discovery, manual helper probe, Find audio helper, and Advanced helper target state.
- `SystemOutputCoordinator` owns system volume/device state and pure volume/device operations.
- `AdvancedProcessTapDiagnosticsCoordinator` owns Process Tap Test, Mute Probe, and Replay Probe.
- `AdvancedLiveControlCoordinator` owns manual Advanced Live start/stop orchestration.
- `TwoAppReadinessCoordinator` owns Advanced Two-App Readiness selection, target options, start/stop orchestration, snapshot/result state, and selection repair.
- `MixerViewModel` remains the central coordinator for product Real App Control, app list/mock row state, lifecycle cleanup, cross-feature busy gating, and status messages.
- XCTest coverage currently focuses on pure logic and synthetic buffers, not real Process Tap or device integration.

## Requirements

- macOS (deployment target macOS 13.0 for non-Process-Tap features)
- **macOS 14.2 or later for Product Real Control / any Process Tap feature**
- System Audio Recording permission (requested only when you run a Process Tap or Real Control action)
- Xcode
- Swift and SwiftUI

The current project is a native macOS Xcode project. It does not use Flutter and does not require external packages.

## Known Limitations and Caveats

- **Product Real Control is experimental** and capped at **three** concurrent Real sessions
  (`maxConcurrentLiveSessions = 3`). Going beyond three (`N > 3`) is deferred.
- Normal per-app row sliders/mute are **UI-state/preview only** unless Real Control is active for
  that row; they do not change any app's real per-app volume.
- **Rapid manual Real on/off toggle spam** can still cause crackle/Starv if toggled aggressively.
  The intended flow is Real Control staying enabled during use, not rapid toggling. A UI-level
  debounce / disabled pending-operation guard is tracked for v0.15.
- Process Tap features require **macOS 14.2+** and fail gracefully on older versions.
- Browser/helper PIDs can change across tab reloads and helper restarts; helper mappings are
  in-memory only and not persisted across launches.
- **v0.14 is an internal, unreleased stability checkpoint** — no public release/tag has been cut and
  the marketing version is unchanged. See `CHANGELOG.md` (`[v0.14] - Unreleased`).

## How to Run

1. Open `MacMiniMixer.xcodeproj` in Xcode.
2. Select the `MacMiniMixer` scheme.
3. Press Run.
4. Look for the `MacMiniMixer` icon in the macOS menu bar.
5. Click the menu bar icon to open the mixer panel.

## Safety Notes

- MacMiniMixer changes the real default output device when you select an output device.
- MacMiniMixer changes real system output volume through the `System Output` slider and mute control.
- MacMiniMixer mutes/unmutes system output by setting volume to zero and restoring the previous non-zero value.
- System Audio Recording permission is required for Process Tap experiments.
- Process Tap features require macOS 14.2 or later and should fail gracefully on unsupported macOS versions.
- Advanced Process Tap tools are separated from the normal mixer flow.
- Process Tap features are user-triggered only.
- Helper discovery and helper probing require explicit user action in Advanced.
- `Find audio helper` requires explicit user action, probes candidates sequentially, and uses unmuted diagnostics.
- Helper targets are not persisted across launches.
- No capture starts automatically when a helper process is discovered or selected.
- No capture starts automatically just because a browser/web app appears in the main mixer list.
- Main-row browser/helper resolution requires global Real App Control to be ON and requires explicit slider/mute interaction.
- Product helper mappings are in-memory only, validation-first, and not persisted across launches.
- No background scanning refreshes helper mappings.
- No replay or audio saving happens during helper auto-detect.
- Two-App Readiness is explicit, Advanced-only, short-lived, and diagnostic.
- Two-App Readiness uses `Stop All` and a timeout to clean up both sessions.
- Output device changes, selected app exit, panel close for the Advanced test, or app quit stop the Two-App Readiness test.
- Real app control is still experimental and opt-in.
- The global Real app control toggle is required before automatic row control can start.
- No capture starts just because an app appears in the list.
- Only user interaction starts real app control.
- Experimental app-row control supports up to three active apps at a time (`N > 3` deferred).
- Experimental live control may affect the selected app's audio while it is active.
- Panel close does not stop active real app control, but the menu bar icon and panel banner indicate that it is active when visible.
- Stop, output device changes, selected app exit, timeout, or app quit should clean up the live session.
- Temporary Core Audio resources are created and cleaned up for Process Tap experiments.
- No audio is saved to disk.
- No HAL driver or persistent virtual audio device is installed.
- Normal app row controls are preview/UI-state only by default and become real only for active Real rows (up to three) through explicit experimental opt-in.
- MacMiniMixer does not install a driver.
- MacMiniMixer does not create a persistent virtual audio device.
- MacMiniMixer does not use private APIs.
- MacMiniMixer does not add third-party dependencies.

Output device and system volume behavior is implemented through public macOS/Core Audio APIs. Per-app audio work remains experimental and intentionally limited while the architecture is researched further.

## Roadmap

Near-term:

- Better UI polish
- More robust output device handling
- Error/status UI for devices that cannot switch or expose writable volume
- Continue simplifying the main UI while keeping diagnostics available in Advanced
- Continue the careful `MixerViewModel` split after read-only planning around product Real Control and lifecycle/status boundaries
- Add more characterization tests around remaining product Real Control, lifecycle cleanup, app list/mock state, and status behavior
- Refine live session reliability and latency
- Refine global Experimental Real App Control behavior
- Add accessibility labels for mixer rows, controls, and Advanced diagnostics
- Add `CHANGELOG.md`
- GitHub release packaging

Research and experiments:

- Plan product Real Control extraction boundaries read-only before moving it out of `MixerViewModel`
- Design safe architecture for per-app gain/mute experiments
- Continue testing Advanced Two-App Readiness with more Core Audio tap-eligible apps
- Investigate browser/helper process discovery for Safari, YouTube, and similar web audio
- Refine helper candidate selection
- Refine helper confidence/scoring for auto-detected audio helpers
- Investigate helper PID changes across tab reloads, navigation, and browser helper restarts
- Refine the browser/helper one-row mapping prototype behind explicit experimental mode
- Evaluate whether any output queue architecture should be unified later, after more manual audio regression testing
- Evaluate independent sessions versus a centralized mixer/renderer
- Consider limited multi-app main UI behavior only after readiness, latency, cleanup, and diagnostics look stable
- CPU, latency, buffer drop, and cleanup diagnostics before exposing multi-app control
- Multi-session architecture research using the internal session manager foundation
- Refine automatic audio-relevant app detection
- Audio activity detection improvements
- Eventual automatic real mixer behavior if stable
- Reduce experimental UI over time if stability improves
- Eventually evaluate multi-app architecture
- Evaluate a centralized mixer/renderer if independent sessions are not stable
- Investigate routing/replay requirements
- Decide whether Process Tap alone is enough or whether a virtual device/HAL approach is needed later
- Better app active/inactive state handling

Longer-term:

- Installer/uninstaller if needed
- Documentation for known limitations
- macOS version support notes

Background Music and BlackHole may be studied architecturally later, but their code is not copied.

## Not Implemented

- General per-app volume mixer behavior
- Automatic control of every visible app
- Production multi-app real mixer behavior
- Production automatic browser/helper mapping for every relevant main UI row
- Stable tab-level YouTube/Safari mapping
- Making all normal app row sliders real
- Making all normal app row mute buttons real
- Production multi-app simultaneous control (an experimental 3-session cap exists; `N > 3` and production-grade multi-app are not implemented)
- Production-grade shared renderer
- Production-ready low-latency renderer
- Full Windows Volume Mixer replacement behavior
- HAL driver / virtual audio device
- Persistent virtual audio device
- App Store distribution
- Installer/uninstaller

## License

MIT License.
