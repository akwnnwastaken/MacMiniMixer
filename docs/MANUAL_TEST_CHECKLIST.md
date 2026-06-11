# MacMiniMixer — Manual Test Checklist

Use this checklist before releases or after significant changes to the audio path,
output device handling, or helper resolution logic.

Each section describes setup, the action to take, and the expected outcome.
Mark pass (P), fail (F), or not applicable (N/A).

Requirements: macOS 14.2+, Xcode build, System Audio Recording permission granted.

---

## 1. System Output Volume

### 1.1 Slider move changes real volume
- Open panel.
- Move the System Output slider.
- **Expected**: macOS system volume changes in real time. Menu bar volume indicator
  reflects the same value.

### 1.2 Mute button sets volume to zero
- Set volume to ~60.
- Click mute icon.
- **Expected**: Volume drops to 0. Mute icon changes to speaker-slash. Real system audio
  is silent.

### 1.3 Unmute restores previous volume
- After muting (1.2), click mute icon again.
- **Expected**: Volume returns to ~60 (the pre-mute value). Real system audio resumes.

### 1.4 Mute when already at zero
- Drag slider to 0.
- Click mute.
- Unmute.
- **Expected**: Volume restores to `defaultSystemOutputRestoreVolume` (50) since there was
  no non-zero value to restore.

### 1.5 Non-writable device shows status warning
- Switch output to a device known not to expose writable volume (e.g., certain HDMI
  displays or optical output).
- Move the slider.
- **Expected**: Status message "This device does not expose writable volume" appears for
  ~2.5s. Volume slider snaps back (or stays at reflected value) after `finishSystemVolumeEditing`.

### 1.6 External volume change syncs panel
- Open panel.
- Change system volume using macOS keyboard keys or menulet.
- **Expected**: The slider in MacMiniMixer updates within ~1 second (live sync loop).

---

## 2. Output Device Listing and Switching

### 2.1 Real devices appear
- Open panel → click output device button.
- **Expected**: Hardware output devices listed (built-in speakers, headphones, AirPods if
  connected). Obvious virtual devices (Zoom, Teams, BlackHole, etc.) are hidden unless
  they are the current default.

### 2.2 Current default is selected
- **Expected**: The system's current default output device is highlighted/selected.

### 2.3 Selecting a device switches default
- Click a non-default device in the selector.
- **Expected**: macOS default output device changes to the selected device. Volume reads
  from the new device.

### 2.4 Unswitchable device shows warning
- If possible, attempt to switch to a device that Core Audio rejects.
- **Expected**: Status message "Could not switch output device". Previous selection is
  restored.

### 2.5 External device connect/disconnect refreshes list
- Connect AirPods or plug in USB headphones while panel is open.
- **Expected**: Device list refreshes within ~2 seconds. New device appears. If AirPods
  auto-switch, selection updates.

### 2.6 Device change stops active live control
- Start live control for an app (see section 4).
- Connect/disconnect an audio device so the default output changes.
- **Expected**: Live control stops. Status message "Live control stopped: output device
  changed". Menu bar icon reverts to non-active state.

---

## 3. Running App Discovery

### 3.1 Audio-relevant apps appear
- Launch Spotify, Music, Safari.
- Open panel.
- **Expected**: These apps appear in the Applications list with real icons.

### 3.2 Non-audio apps are filtered
- Open panel with Finder, Notes, Xcode, TextEdit running.
- **Expected**: These do not appear in the default list (unless "Show all" is checked).

### 3.3 Show all reveals hidden apps
- Check "Show all".
- **Expected**: All regular running apps including non-audio ones appear.

### 3.4 App exit removes it from list
- Quit Spotify while panel is open.
- Open panel again (or wait for next refresh).
- **Expected**: Spotify no longer appears.

---

## 4. Spotify/Music Direct Real App Control

Setup: Global "Real app control" ON. Spotify playing audio.

### 4.1 Slider starts live control for Spotify
- Move Spotify's slider.
- **Expected**: Live control starts. Orange banner "Real control: Spotify" appears.
  Menu bar icon shows waveform. Spotify's volume adjusts according to slider position
  (gain applies to replayed audio).

### 4.2 Active slider controls gain in real time
- While live control active, move slider.
- **Expected**: Audible gain change. Diagnostics (in Advanced) show updated gain label.

### 4.3 Mute maps to gain 0
- Click Spotify's mute toggle while live control is active.
- **Expected**: Audio is silenced (gain 0 applied to replay). Unmuting restores previous
  slider gain.

### 4.4 Stop button stops live control
- Click "Stop" in the active banner.
- **Expected**: Live control stops. Banner disappears. Spotify audio resumes at its
  normal volume (original output is no longer suppressed).

### 4.5 Interacting with a second app while one is active shows a warning
- Live control active for Spotify.
- Move Music's slider.
- **Expected**: Status warning "Stop active live control first". Music live control does
  not start.

### 4.6 Product live control persists past 60 seconds
- Start product live control. Wait longer than 60 seconds.
- **Expected**: Live control remains active while the app and output device remain valid.

### 4.7 App quit stops live control
- Start live control for an app, then quit the app.
- **Expected**: Live control stops with "Live control stopped: app exited".

---

## 5. YouTube/Safari Helper Row Real App Control

Setup: Safari open with YouTube playing. Global "Real app control" ON.

### 5.1 Safari row triggers helper resolution
- Move Safari's slider.
- **Expected**: Row shows a spinner/resolving state. Helper resolution runs (may take
  ~1–3 seconds if 2–3 candidates are probed). If a helper process with audio is found,
  live control starts and the banner shows "Real control: Safari".

### 5.2 Row label stays as "Safari" not helper process name
- While helper live control is active.
- **Expected**: Row is still labeled "Safari" (or "YouTube"), not "com.apple.WebKit.GPU"
  or whatever the helper PID's process name is.

### 5.3 If no audio detected, shows unavailable warning
- Open Safari with no audio playing.
- Move slider.
- **Expected**: Status "No active audio helper found" (or similar). Live control does
  not start.

### 5.4 Stop stops helper live control
- Click "Stop" in active banner.
- **Expected**: Safari audio resumes at system level. No suppression.

---

## 6. Helper Cache / Fast Path

### 6.1 Second interaction uses cache
- Trigger helper resolution for Safari/YouTube (5.1).
- Stop live control.
- Move slider again.
- **Expected**: Second resolution is fast (< 0.5s) as the cached helper PID is reused
  after validation.

### 6.2 Cache is invalidated after app exits
- Trigger helper resolution. Stop live control. Quit and relaunch Safari. Move slider.
- **Expected**: Full re-probe runs (cache miss, because visible PID changed on relaunch).

### 6.3 Cache is invalidated when Real App Control is turned OFF
- Have a cached helper for Safari.
- Turn off "Real app control" toggle.
- Turn it back on. Move slider.
- **Expected**: Full re-probe runs (cache was cleared when mode was disabled).

---

## 7. Advanced: Helper Process Discovery

### 7.1 Scan finds helper candidates
- Open Advanced. Select "Safari" in Helper Discovery app picker. Click "Scan".
- **Expected**: List of candidate processes (WebKit GPU, WebContent, etc.) with PID,
  relation (child, descendant, nameMatch), and tap eligibility.

### 7.2 Tap-ineligible candidates are shown but not probed as eligible
- Some candidates may show "Core Audio process unavailable" for eligibility.
- **Expected**: These are shown for informational value but cannot be used as advanced
  target or probed.

### 7.3 Probe candidate shows diagnostics
- Click "Probe" next to a tap-eligible candidate.
- **Expected**: Brief diagnostic runs. Callback count, peak, RMS shown. Audio detected
  if YouTube is playing.

### 7.4 Use as Advanced Target
- Click "Use as target" on a tap-eligible candidate.
- **Expected**: Advanced Target shows the helper info. Process Tap Test, Replay Probe, and
  Two-App Readiness now operate against this helper PID.

---

## 8. Advanced: Find Audio Helper

### 8.1 Auto-detect probes all eligible candidates
- Scan for Safari helpers. Click "Find audio helper".
- **Expected**: Progress "Testing 1/N, 2/N, …" shown. After all candidates probed, the
  one with strongest audio (highest RMS/peak, `hasDetectedAudio = true`) is selected as
  the advanced target.

### 8.2 No audio helper found when nothing playing
- Open Safari with no audio. Find audio helper.
- **Expected**: "No audio helper detected".

### 8.3 Early-accept with strong audio
- If a candidate has RMS ≥ 0.01 or peak ≥ 0.05, it should be accepted immediately
  without probing the remaining candidates.
- **Verify in logs**: `AppLogger.helperResolution` should show "early-accepted candidate".

---

## 9. Advanced: Helper Replay Probe

### 9.1 Replay Probe runs against selected app
- In Advanced, select Spotify (direct PID). Choose 50% gain. Click "Replay Probe".
- **Expected**: Spotify audio is temporarily suppressed and replayed at 50% for ~2.5s.
  Callback count, peak, RMS, queued/dropped/failed buffers reported.

### 9.2 Replay Probe runs against Advanced helper target
- Set Safari helper as advanced target. Click "Replay Probe".
- **Expected**: WebKit audio suppressed and replayed for ~2.5s.

### 9.3 No audio detected result
- Run Replay Probe on an app not currently playing audio.
- **Expected**: "No audio detected" result with 0 peak / 0 RMS.

---

## 10. Advanced: Two-App Readiness

### 10.1 Spotify + Music simultaneous readiness test
- Select Spotify as App A, Music as App B. Choose 50% gain. Click "Start".
- **Expected**: Both sessions start. Both show active state with increasing callback
  count, non-zero peak/RMS. Test auto-stops at 10s with "Two-app test stopped: timeout".
  Both callback counts should be similar (e.g., ~90–100 in 10s at 100ms diagnostic interval).
  Drops = 0, failures = 0 is the healthy target.

### 10.2 Spotify + YouTube helper target
- Set YouTube helper as Advanced target. Select Spotify as App A and helper as App B.
  Start test.
- **Expected**: Both sessions active, both reporting audio. Similar to 10.1.

### 10.3 Stop All stops both sessions
- Start two-app test. Click "Stop All" before timeout.
- **Expected**: Both sessions stop immediately. "Two-app test stopped" message.

### 10.4 Ineligible target shows setup failure
- Select an app not tap-eligible as App A or B. Click Start.
- **Expected**: "Core Audio process unavailable" or similar. Test does not start.

### 10.5 Same app selected for both slots
- Select Spotify for both App A and App B. Click Start.
- **Expected**: "Choose two different apps" warning. Test does not start.

---

## 11. Stop / Stop All / Timeout Behavior

### 11.1 "Stop" in banner stops live control
- Covered in section 4.4.

### 11.2 Timeout fires at 60s for live control
- Covered in section 4.6.

### 11.3 "Stop All" in Two-App Readiness stops both
- Covered in section 10.3.

### 11.4 App quit during live control stops gracefully
- Covered in section 4.7.

### 11.5 Quit MacMiniMixer stops all active sessions
- Start live control. Use "Quit MacMiniMixer" button.
- **Expected**: App quits cleanly. No Core Audio resources left hanging (check Console
  for cleanup log messages).

---

## 12. Output Device Change While Active

### 12.1 Output device change stops live control
- Covered in section 2.6.

### 12.2 Output device change stops Two-App Readiness
- Start two-app readiness. Change default output device.
- **Expected**: Both sessions stop. "Two-app test stopped: output changed".

### 12.3 Output device change stops helper probe
- Probe a helper candidate in Advanced. Change default output device during probe.
- **Expected**: Probe stops. Result shows output-changed outcome.

---

## 13. Panel Close and Reopen

### 13.1 Panel close stops Two-App Readiness
- Start two-app readiness test. Click outside panel to close it.
- **Expected**: `onDisappear` fires, `stopTwoAppReadinessForPanelClose()` stops the test.

### 13.2 Panel close does NOT stop live control
- Start live control. Close panel.
- **Expected**: Live control continues. Menu bar icon shows waveform-circle.fill. No
  orange banner visible (panel closed), but waveform icon indicates active.

### 13.3 Reopen panel shows active banner
- While live control active (12.2), reopen panel.
- **Expected**: Orange "Real control: AppName" banner shown. Stop button works.

### 13.4 Panel refresh on reopen
- Quit an app while panel is closed. Reopen panel.
- **Expected**: App no longer in list. `refreshApplications()` fires on panel `onAppear`.

---

## 14. System Sleep / Wake

These verify the deliberate sleep-teardown / wake-refresh-only behavior. No automatic
session restart is expected after wake — the user re-engages manually. The sleep/wake
observers are app-lifetime (in `MixerViewModel`), so they fire whether or not the panel is open.

### 14.1 Sleep tears down active Product live control
- Start Product Real Control for an app (section 4). Confirm the banner and menu bar waveform.
- Put the Mac to sleep (Apple menu → Sleep, or close the lid), wait a few seconds, then wake.
- **Expected**: After wake, live control is no longer active (no banner, menu bar icon
  reverted). The app's audio plays at its normal volume. No crash, no hung Core Audio
  resources (check Console for cleanup logs). The "Real app control" global toggle is still ON.

### 14.2 Sleep stops Two-App Readiness and Advanced work
- Start a Two-App Readiness test (section 10) or Advanced manual live control. Sleep, wake.
- **Expected**: The test / live control is stopped after wake; nothing resumes on its own.

### 14.3 Wake refreshes device, volume, and app state
- Before sleep, note the current output device and system volume. Optionally change the
  default output device or quit an app during sleep.
- Sleep, then wake and open the panel.
- **Expected**: Output device list, the selected default device, system volume/mute, and the
  visible app list reflect post-wake reality. No spurious "output device changed" warning
  appears merely from waking (nothing was active to stop).

### 14.4 User re-engages after wake
- After a wake that tore down a session (14.1), move the app's slider again.
- **Expected**: A fresh live-control session starts normally (fresh helper resolution for
  browser rows). Behavior is identical to a first-time start.

### 14.5 Sleep/wake with the panel closed
- Start live control, close the panel, sleep, wake, reopen the panel.
- **Expected**: Same as 14.1 — the session was torn down at sleep even though the panel was
  closed. The reopened panel shows no active banner.

### 14.6 Three-session sleep/wake smoke (cap=3 evidence gate)
The sleep/wake teardown is collection-based and expected to be N-safe; this confirms it on real
hardware with three concurrent sessions (v0.14 stability evidence). It does **not** enable N > 3.

Procedure:
1. Launch the app from a **Release** build.
2. Play audio in **2 direct + 1 helper** app (e.g. Music + Spotify + a YouTube/browser helper).
3. Make all three Real.
4. Confirm the banner reads "first two names +1 more" with **Stop All**.
5. Close the panel.
6. Put the Mac to sleep briefly (Apple menu → Sleep, or close the lid).
7. Wake, then reopen the panel.

- **Expected**: no Real session remains active; the banner is gone; the "Real app control"
  toggle may stay ON; **all three apps' audio returns to normal without quitting/relaunching the
  app**; no cleanup warning / drop / failure; CPU returns to ~0%.
- **Red flags**: after wake an app stays silent/muted; audio only recovers when MacMiniMixer is
  quit (orphan tap); a session still shows active (resurrection); any cleanup warning / drop /
  failure; CPU does not drop after stop; crash.

Notes:
- This test is for the Product cap=3 path.
- The Advanced Two-App Readiness diagnostic is a separate two-session measurement tool and must
  not be conflated with this.
- N > 3 requires its own gate; passing this only strengthens cap=3 stability evidence.

---

## 15. CI Build and Test

### 15.1 Clean build succeeds
- `xcodebuild build -scheme MacMiniMixer`
- **Expected**: Build succeeds, zero warnings that are errors.

### 15.2 Tests pass
- `xcodebuild test -project MacMiniMixer.xcodeproj -scheme MacMiniMixer -destination 'platform=macOS'`
- **Expected**: The full XCTest suite passes, including fake-backed coordinator,
  helper discovery/resolver, live-control, Two-App Readiness, diagnostics accumulator,
  and output buffer copier tests.

### 15.3 GitHub Actions build passes
- Push to main or open a PR.
- **Expected**: CI build/test workflow passes. Check Actions tab.

---

## 16. Release CPU / Resource Profiling (cap=3 baseline)

Use this when re-checking two- or three-session resource cost or before considering N > 3.
**Always profile a Release build** — Debug (`-Onone`) inflates the per-sample audio loops and is
not representative.

### 16.1 Setup
- Xcode → Product → Scheme → Edit Scheme → **Profile → Build Configuration = Release**.
- Quit any running MacMiniMixer; confirm in Activity Monitor that **no** MacMiniMixer process
  remains (Force Quit leftovers) so only one Release process is measured.
- Xcode → Product → Profile (⌘I) → **Time Profiler** → Choose.

### 16.2 Procedure (per scenario)
- Record 60 s idle (no session, panel closed), then ~2–3 min each for: one direct session,
  two direct sessions, two direct with panel open, and direct + helper.
- Call Tree: Separate by Thread, Invert Call Tree, Hide System Libraries.
- Record per scenario: Activity Monitor CPU avg/peak, memory, thread count, time for CPU to
  return to ~0% after stop, drops/failures, and the top symbols (self/total weight, thread).

### 16.3 Reference baseline (one real Mac, M4 Pro, Release)
Measured values, for comparison — not hard pass thresholds:

| Scenario | Panel | CPU avg | Memory | Threads | Stop→~0 |
|---|---|---:|---:|---:|---:|
| Idle | Closed | ~0% | ~21 MB | ~7 | — |
| 1 direct | Closed | ~7.1% | ~53.9 MB | 13 | ~6–7 s |
| 2 direct | Closed | ~12.2% | ~56.8 MB | 16 | ~returns |
| 2 / direct+helper | Closed | ~13.6% | ~57.7 MB | 14 | ~returns |
| 3 / 2 direct+helper | Closed | ~19% | ~59.1 MB | ~16 | ~returns |

- **Expected**: idle ≈ 0%; two-session ≲ 2× single, three-session within ~17–25%; CPU returns
  to ~0% within ~10 s of stop; no drops/failures/cleanup warnings; memory/threads stable across
  runs. The relative cost centre is Main Thread / SwiftUI / AppKit, not the audio callback path.
  The banner should summarise 3 apps as "first two names +1 more" with "Stop All".
- **Red flags**: idle CPU that stays high; two-session > 2× single or three-session well above
  ~25%; near a full core sustained in Release; audio callback threads still alive long after
  stop; memory/threads growing each run; any drop/failure/cleanup warning.

### 16.4 Callback jitter / output starvation live smoke (Phase 6c)
With Real Control active, the live Advanced diagnostics card shows a second line
"Gap … · Late … · Starv …", and the stop-result detail begins with `maxGap …ms, late …, starv …`.
Use this to check for glitches that the drop/failure counters miss.

- **Values to record** (per run): `maxGap` (ms), `late`, `starv`, `drops`, `fail`, audible
  glitch yes/no, panel state, and CPU with the panel closed vs open.
- **PASS**: `starv` 0 (or very low) and `drops`/`fail` 0; **no audible glitch**; clean stop. A
  single `late` or a `maxGap` of ~70–133 ms on its own is **not** a failure (a brief spike,
  panel open, around stop, or a helper input pause can cause it).
- **Red flags**: `starv` rising **together with** an audible glitch; `late` increasing
  continuously; `drops`/`fail` non-zero; audio lost until the app is quit; panel-closed CPU
  staying unexpectedly high.

> Reference (one real Mac, three sessions, Release): observed `Starv 0`, `Drops 0`, `Fail 0`,
> `Late 1`, `maxGap` ~70–133 ms, no audible glitch — PASS. Panel-open Advanced diagnostics is
> CPU-heavy (panel closed ≈ 25%, panel open / Advanced closed ≈ 39%, panel open / Advanced open
> ≈ 55%); judge the cap=3 gate on the panel-closed number.

---

## Notes

- All Process Tap tests require macOS 14.2 or later. On older macOS, all Process Tap
  actions should return "Process Tap requires macOS 14.2 or later" without crashing.
- System Audio Recording permission must be granted. If not granted, tap creation returns
  `kAudioDevicePermissionsError` and the UI shows "Audio capture permission was denied".
- No audio is saved to disk during any of these tests.
- All temporary Core Audio resources (tap, aggregate device, IOProc) should be destroyed
  on session end. Check Console.app for `MacMiniMixer cleanup` log messages to confirm.
