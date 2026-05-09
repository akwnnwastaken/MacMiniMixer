# MacMiniMixer

MacMiniMixer is a native Swift + SwiftUI macOS menu bar audio utility inspired by the Windows Volume Mixer. It is designed as an open-source, technical macOS project for users who understand experimental system-level audio tools.

The app is not targeting the Mac App Store. It uses native macOS APIs directly, avoids private APIs, and currently has no third-party dependencies.

## Current Status

MacMiniMixer is in a v0.11 internal live-session manager foundation milestone, with v0.10.1 simplified UI behavior preserved.

It provides a cleaner menu bar mixer panel focused on everyday controls, with stable system-level output controls, real output device listing/switching, real running app discovery, a compact global opt-in mode that can make one eligible app row real when the user interacts with it, and technical Process Tap tools tucked into a collapsed Advanced section.

v0.11 is primarily an internal architecture milestone. The app now has a `ProcessTapLiveSessionManager` and session identity/state foundation for future multi-session work, but the user-facing behavior is still one active real-controlled app at a time. It is not a full Windows Volume Mixer replacement yet: app rows are mock-only by default, and general multi-app per-application control is not implemented.

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
- Compact `Real app control` toggle, OFF by default
- Slider interaction can start real one-app control when the global mode is enabled
- One active experimental app row at a time
- Active row slider controls real experimental Process Tap gain
- Active row mute maps to experimental gain 0
- Menu bar active indicator and compact panel active banner while real app control is active
- Non-active app rows remain mock-only

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

Mock-only today:

- App row volume sliders when the global mode is OFF, unless manual Live is started from Advanced
- App row mute controls when the global mode is OFF, unless manual Live is started from Advanced
- Non-active app row sliders and mute controls
- General multi-app per-application audio routing, replay, gain, or modification

By default, the global Real app control mode is OFF. In that mode, app rows are UI state only unless the user explicitly starts manual Live control from Advanced. Moving a normal row slider does not change Safari, Music, Spotify, Chrome, Discord, or any other app's real audio.

When the global mode is ON, moving an eligible app row slider or clicking mute on an eligible inactive row can start one real experimental Process Tap live session for that app, as long as no other app is active. The app's audio is captured, the original stream is suppressed, processed audio is replayed, the active row slider maps to live gain, and the active row mute maps to gain 0. Non-active rows remain mock-only. Interacting with another app while one is active shows a warning and does not silently switch.

The Advanced diagnostics section can create short-lived Core Audio process tap diagnostics for a selected running app. During diagnostic tests, it creates temporary private Core Audio resources, shows a live diagnostic level meter, reports callback count plus peak/RMS levels, and then cleans up.

Replay Probe, manual Live Control, and global opt-in row control go further: they can temporarily suppress the selected app's original output, replay captured audio through `AudioQueue`, and apply gain. These paths are experimental, user-triggered, and currently limited to one app. They do not make every row a real mixer control.

The app includes `NSAudioCaptureUsageDescription` for system audio capture experiments. It does not request system audio recording permission on launch. macOS may ask for System Audio Recording permission when the user explicitly runs a diagnostic or live control action.

## Architecture Notes

The current live-control implementation is intentionally still limited to one active session. v0.11 adds internal session-management scaffolding without exposing multi-app control in the UI.

- `ProcessTapLiveSessionManager` wraps the existing Core Audio live controller.
- `ProcessTapLiveSessionID` and `ProcessTapLiveSessionState` provide a foundation for future per-session tracking.
- `maxSessions` is currently `1`.
- Existing global Real app control and Advanced manual Live Control route through this manager-backed path.
- Future multi-session work can build on this foundation, but multi-app real control is not enabled yet.

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
- Advanced Process Tap tools are separated from the normal mixer flow.
- Process Tap features are user-triggered only.
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
- Normal app row controls do not yet control per-app audio.
- MacMiniMixer does not install a driver.
- MacMiniMixer does not create a persistent virtual audio device.
- MacMiniMixer does not use private APIs.
- MacMiniMixer does not add third-party dependencies.

Output device and system volume behavior is implemented through public macOS/Core Audio APIs. Per-app audio work is intentionally deferred until the architecture is researched further.

## Roadmap

Near-term:

- Better UI polish
- More robust output device handling
- Error/status UI for devices that cannot switch or expose writable volume
- Continue simplifying the main UI while keeping diagnostics available in Advanced
- Refine live session reliability and latency
- Refine global Experimental Real App Control behavior
- GitHub release packaging

Research and experiments:

- Verify exact macOS Process Tap API requirements
- Improve permission and failure diagnostics for Process Tap tests
- Add safe debug logging for tap diagnostics
- Design safe architecture for per-app gain/mute experiments
- Refine the one-app-row experimental Live opt-in path
- Advanced two-app readiness experiment
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
- Making all normal app row sliders real
- Making all normal app row mute buttons real
- Multi-app simultaneous control
- Production-ready low-latency renderer
- Full Windows Volume Mixer replacement behavior
- HAL driver / virtual audio device
- Persistent virtual audio device
- App Store distribution
- Installer/uninstaller

## License

License TBD.
