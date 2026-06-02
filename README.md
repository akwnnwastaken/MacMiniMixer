# MacMiniMixer

MacMiniMixer is a native Swift + SwiftUI macOS menu bar audio utility inspired by the Windows Volume Mixer. It is designed as an open-source, technical macOS project for users who understand experimental system-level audio tools.

The app is not targeting the Mac App Store. It uses native macOS APIs directly, avoids private APIs, and currently has no third-party dependencies.

## Current Status

MacMiniMixer is in a v0.12 experimental browser-helper row resolution milestone. The main product path can still run only one real-controlled app/session at a time, but global Real App Control can now resolve a browser/web helper process internally for one user-facing row when the user explicitly interacts with that row.

It provides a cleaner menu bar mixer panel focused on everyday controls, with stable system-level output controls, real output device listing/switching, real running app discovery, a compact global opt-in mode that can make one eligible app row real when the user interacts with it, and technical Process Tap tools tucked into a collapsed Advanced section.

v0.12 keeps the simplified v0.10.1 main UI and the v0.11 internal `ProcessTapLiveSessionManager` foundation. The main UI still does not expose production multi-app mixer control. App rows are mock-only by default, and real row control requires the global Real App Control toggle to be ON.

When global Real App Control is ON, visible tap-eligible apps such as Spotify or Music can still use the direct visible PID path. For YouTube/Safari-style browser rows whose visible PID is not tap-eligible, MacMiniMixer can now attempt user-triggered helper resolution: it scans related helper/content candidates, probes eligible candidates with short unmuted diagnostics, selects a best audio-carrying helper, and starts the existing one-app live control path against that helper PID while keeping helper PID/process names hidden from the main mixer UI.

A validation-first in-memory helper cache reuses successful helper mappings only after validating that the helper PID still exists and remains Core Audio tap-eligible. Helper mappings are not persisted across launches, and no background helper scanning starts merely because an app appears.

Advanced helper diagnostics can scan helper/content process candidates for visible apps such as Safari or YouTube. Candidate Probe can detect audio on a helper process, such as `com.apple.WebKit.GPU`, and that helper can be manually selected as an Advanced helper target. The `Find audio helper` action can also probe eligible helper candidates sequentially with short unmuted diagnostics, score them by detected audio, RMS, peak, and callback count, and automatically select the best audio-carrying helper as the Advanced target. Process Tap Test, Replay Probe, and Two-App Readiness can then run against that helper PID from Advanced.

A successful Advanced readiness test was observed with Spotify + a YouTube helper target at 50% gain: Spotify reported 928 callbacks, peak 0.202, RMS 0.060, 928 queued buffers, 0 drops, and 0 failures; the YouTube helper reported 932 callbacks, peak 0.590, RMS 0.174, 932 queued buffers, 0 drops, and 0 failures. Both sessions stopped cleanly by timeout. This is promising, but it does not mean the app is production-ready as a multi-app mixer or that browser/helper row control is stable production behavior.

Recent maintenance work replaced brittle string-based result checks with typed outcomes, made Process Tap resource cleanup thread-safe, added lightweight `os.Logger` diagnostics, added macOS 14.2 Process Tap availability guards while keeping the deployment target at macOS 13.0, added an MIT License, added GitHub Actions build/test CI, added XCTest coverage, unified Process Tap diagnostics accumulation, and extracted shared Process Tap output buffer copying logic with unit tests. `MixerViewModel` has also started an incremental split into coordinators for Advanced helper discovery, system output, Advanced Process Tap diagnostics, and manual Advanced Live Control.

It is not a full Windows Volume Mixer replacement yet: app rows are mock-only by default, only one real-controlled row/session can be active, and production multi-app per-application control is not implemented.

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
- Mock per-app sliders and mute controls for UI/UX development
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
- Slider interaction can start real one-app control when the global mode is enabled
- One active experimental app row at a time
- Active row slider controls real experimental Process Tap gain
- Active row mute maps to experimental gain 0
- Menu bar active indicator and compact panel active banner while real app control is active
- Non-active app rows remain mock-only
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
- Global Experimental Real App Control mode that can start one eligible row automatically from slider/mute interaction
- While one eligible row is active, that row's slider controls experimental live gain and that row's mute maps to gain 0
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
- Multi-app real row control in the main UI
- Browser/helper targets as main UI rows
- General multi-app per-application audio routing, replay, gain, or modification

By default, the global Real app control mode is OFF. In that mode, app rows are UI state only unless the user explicitly starts manual Live control from Advanced. Moving a normal row slider does not change Safari, Music, Spotify, Chrome, Discord, or any other app's real audio.

When the global mode is ON, moving an eligible app row slider or clicking mute on an eligible inactive row can start one real experimental Process Tap live session for that app, as long as no other app is active. For visible tap-eligible apps, this uses the visible app PID directly. For YouTube/Safari-style browser rows whose visible PID is not tap-eligible, MacMiniMixer may resolve an audio helper PID internally after the user interaction, keep the row labeled as the visible app, and hide helper PID/process details from the main UI. The app's audio is captured, the original stream is suppressed, processed audio is replayed, the active row slider maps to live gain, and the active row mute maps to gain 0. Non-active rows remain mock-only. Interacting with another app while one is active shows a warning and does not silently switch.

The Advanced diagnostics section can create short-lived Core Audio process tap diagnostics for a selected running app. During diagnostic tests, it creates temporary private Core Audio resources, shows a live diagnostic level meter, reports callback count plus peak/RMS levels, and then cleans up.

The Advanced Two-App Readiness test is separate from the main mixer. It uses an isolated readiness configuration with `maxSessions = 2`, requires explicit user start, runs for a short timeout, currently 10 seconds, and provides `Stop All`. It can use visible apps whose PID translates to a Core Audio process object, and it can also use one manually selected Advanced helper target. Music + Spotify have run together successfully in testing with callbacks, peak/RMS, queued buffers, and zero drops/failures observed. Spotify + a YouTube helper target has also run successfully in Advanced diagnostics. This remains prototyping-only and is not exposed as production multi-app row control.

Safari, YouTube, and other browser/web surfaces may not be tap-eligible through the visible app PID because their audio can be rendered by helper/content processes instead of the visible app process. In the main product path, helper resolution is available only behind the global Real App Control toggle and only after user interaction. In Advanced, helper targets remain manually selectable or auto-detected for diagnostics. Helper mappings are not persisted across app launches.

Replay Probe, manual Live Control, and global opt-in row control go further: they can temporarily suppress the selected app's original output, replay captured audio through `AudioQueue`, and apply gain. These paths are experimental, user-triggered, and currently limited to one app. They do not make every row a real mixer control.

The app includes `NSAudioCaptureUsageDescription` for system audio capture experiments. It does not request system audio recording permission on launch. macOS may ask for System Audio Recording permission when the user explicitly runs a diagnostic or live control action.

## Architecture Notes

The current live-control implementation is intentionally still limited to one active session. v0.11 adds internal session-management scaffolding without exposing multi-app control in the UI.

- `ProcessTapLiveSessionManager` wraps the existing Core Audio live controller.
- `ProcessTapLiveSessionID` and `ProcessTapLiveSessionState` provide a foundation for future per-session tracking.
- `maxSessions` is currently `1`.
- Existing global Real app control and Advanced manual Live Control route through this manager-backed path.
- Future multi-session work can build on this foundation, but multi-app real control is not enabled yet.
- Advanced Two-App Readiness uses a separate isolated manager/configuration with `maxSessions = 2` for diagnostics only.
- The main product path remains one-app-only.
- Browser and web audio may be rendered by helper/content processes rather than the visible app PID.
- Helper process PIDs can change as tabs, pages, and browser helpers restart.
- v0.12 can resolve one browser/web-style main row to a helper PID internally after user interaction when global Real App Control is ON.
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
- `MixerViewModel` remains the central coordinator for product Real App Control, Two-App Readiness, app list/mock row state, lifecycle cleanup, cross-feature busy gating, and status messages.
- XCTest coverage currently focuses on pure logic and synthetic buffers, not real Process Tap or device integration.

## Requirements

- macOS
- Xcode
- Swift and SwiftUI

The current project is a native macOS Xcode project. It does not use Flutter and does not require external packages.

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
- Experimental app-row control is limited to one active app at a time.
- Experimental live control may affect the selected app's audio while it is active.
- Panel close does not stop active real app control, but the menu bar icon and panel banner indicate that it is active when visible.
- Stop, output device changes, selected app exit, timeout, or app quit should clean up the live session.
- Temporary Core Audio resources are created and cleaned up for Process Tap experiments.
- No audio is saved to disk.
- No HAL driver or persistent virtual audio device is installed.
- Normal app row controls are mock-only by default and only become real for one active row through explicit experimental opt-in.
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
- Continue the careful `MixerViewModel` split with Two-App Readiness state/model extraction before any larger coordinator move
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
- Refine the v0.12 one-browser-row mapping prototype behind explicit experimental mode
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
- Multi-app simultaneous control
- Production-grade shared renderer
- Production-ready low-latency renderer
- Full Windows Volume Mixer replacement behavior
- HAL driver / virtual audio device
- Persistent virtual audio device
- App Store distribution
- Installer/uninstaller

## License

MIT License.
