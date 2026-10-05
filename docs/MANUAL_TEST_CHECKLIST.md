# MacMiniMixer — Manual Test Checklist

Use this checklist before releases or after significant changes to the audio path,
output device handling, or helper resolution logic.

Each section describes setup, the action to take, and the expected outcome.
Mark pass (P), fail (F), or not applicable (N/A).

Requirements: macOS 14.2+, an Xcode build or the packaged zip (§20), System Audio Recording
permission granted. Use a **Release** build for anything that records CPU or audio-quality numbers.

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

### 1.7 Read-only badge appears before the first drag
- Switch the default output to a device without a writable volume (e.g. an HDMI display or
  optical output) — once from the MacMiniMixer device list, once from System Settings / by
  plugging the device in while the panel is open. Also quit and relaunch MacMiniMixer while that
  device is the default.
- **Do not** touch the System Output slider. Open the panel and look at the System Output section.
- **Expected**: the "Read-only" badge is already visible (probed at launch, on the output-device
  change, and after a successful selection), and VoiceOver reads it as one element with its hint.
  Switching back to a writable device (built-in speakers, headphones) removes the badge without any
  slider interaction.
- **Red flags**: the badge only appears after dragging; the badge shows on a writable device; the
  badge stays after switching to a writable device.

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

### 4.5 Interacting with a second app starts a second session
- Live control active for Spotify.
- Move Music's slider.
- **Expected**: Music starts its own Real session (no app-count limit); the banner shows both
  names with **Stop All**; Spotify keeps playing undisturbed. No "Stop active live control first"
  warning.

### 4.5a A start requested during another start is queued, not rejected
- Global "Real app control" ON, nothing Real yet. Move Spotify's slider and, immediately after,
  Music's slider (or click Music's Real toggle) while Spotify is still starting.
- **Expected**: Music's row shows the pending ("working") badge while Spotify starts, then Music
  starts on its own. No "Finish resolving app audio first", "Stop active live control first", or
  "Process Tap is already busy" warning. Moving the queued row's slider again does not queue a
  second start; when the row starts, it uses the slider position at that moment.

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
hardware with three concurrent sessions (v0.14 stability evidence). The cap has since been removed;
sleep/wake with more sessions is covered by §19.

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
- This test was written for the Product cap=3 path (three sessions).
- The Advanced Two-App Readiness diagnostic is a separate two-session measurement tool and must
  not be conflated with this.
- More than three sessions need their own evidence (§19); passing this only covers three.

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
- **Expected**: CI build/test workflow passes and its `package` job uploads the `MacMiniMixer-app`
  artifact (zip + `.sha256`). Check Actions tab. For a launch check of that zip, see §20.

---

## 16. Release CPU / Resource Profiling (cap=3 baseline)

Use this when re-checking two- or three-session resource cost, and as the setup for the many-app
run in §19 (the three-session numbers below are the only real-hardware baseline so far).
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

> With the default direct output engine (§21) there is no output queue: `Queued` shows 0, and
> `Starv` / `Drops` only count the in-engine resampler's FIFO underruns / overflows (always 0 when
> the HAL passes the tap through at the device rate). So a clean `Starv 0` is weaker evidence than it
> was on the `AudioQueue` path — **listen**, and check the log (§21).

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
> ≈ 55%); judge the cap=3 gate on the panel-closed number. These panel-open numbers predate the
> per-session ~4 Hz publish gate and the focused-session / Advanced-visible gating; they have not
> been re-measured.

### 16.5 Long-run three-session characterization (30–60 min, v0.14 stability gate)
The short smokes (14.6, 16.3, 16.4) only cover minutes of runtime. This run looks for what they
cannot see: slow resource leaks (memory/threads), accumulating `late`/`starv`, and audio-path
degradation over time. It covers three sessions only; a long run with more sessions is an
optional extension of §19.

Setup:
- Release build, single process, as in 16.1 (Instruments is optional here; Activity Monitor
  plus the live diagnostics card is enough).
- Start **2 direct + 1 helper** sessions and make all three Real, as in 14.6 steps 1–3.
  Confirm the banner reads "first two names +1 more" with **Stop All**.
- Use audio sources that keep playing for the full duration (long playlist, long video) so the
  helper input does not pause mid-run.
- Close the panel. Keep Activity Monitor open on the MacMiniMixer row.

Procedure:
- Run for **30 minutes minimum, 60 preferred**.
- Sample at start and then every ~10 minutes: panel-closed CPU (avg over ~1 min), memory,
  thread count; then briefly open the panel → Advanced to read "Gap … · Late … · Starv …" and
  drops/failures, and close it again. Keep the panel open under ~30 s per sample — panel-open
  CPU is much higher (16.4) and would pollute the panel-closed numbers.
- Interaction probes around mid-run and near the end: move each of the three sliders and
  mute/unmute one app. **Expected**: gain still responds immediately on all three.
- At the end: **Stop All**. Record the stop detail line (`maxGap …ms, late …, starv …`), the
  time for CPU to return to ~0%, and confirm all three apps' audio returns to normal without
  quitting/relaunching anything.

Record per sample: elapsed time, CPU (panel closed), memory, threads, `maxGap`, `late`,
`starv`, drops, failures, audible glitch yes/no.

- **Expected**: panel-closed CPU stays in the ~17–25% band with no upward drift; memory stays
  near the ~59 MB three-session baseline and stable between samples; thread count stable
  (~16); `starv`/`drops`/`fail` stay 0 for the whole run; `late` stays low and does **not**
  grow steadily with time; no audible glitch; sliders responsive throughout; clean Stop All
  with CPU back to ~0% within ~10 s and audio normal afterwards.
- **Red flags**: monotonic growth of CPU, memory, or threads across samples (leak); `late` or
  `starv` accumulating with runtime; any drop/failure/cleanup warning; an audible glitch or
  dropout mid-run; an app silent until MacMiniMixer is quit (orphan tap); CPU not returning to
  ~0% after Stop All.

Notes:
- Record the results as a `> Reference (…)` block under this section once run, as in 16.3/16.4.
- Passing strengthens the three-session stability evidence for v0.14; more sessions need §19.

> **Reference (one real Mac, normal use) — PASS (with caveat).** Three Product Real sessions ran
> cleanly during normal use; ordinary per-app stop/start during use was clean; `Drops`/`Fail`/`Starv`
> stayed **0** during normal usage; CPU settled roughly in the **20–35%** range depending on panel /
> Activity Monitor state; **no `sudo killall coreaudiod`** was needed; output remained usable.
> This meets the v0.14 normal-use long-run gate.
>
> **Caveat (not a v0.14 blocker):** *extremely* rapid repeated Real on/off spam eventually produced
> severe crackle and `Starv`. The intended flow is Real Control staying enabled during use, not rapid
> manual toggling, so this is outside the normal-use envelope. **Since then a per-app
> pending-operation guard has been implemented** (repeated toggles / slider starts are ignored while
> a row's start or stop is in flight, with a "working" badge — see ROADMAP "Rapid Real-toggle
> protection" and `docs/DECISIONS.md`); its real-hardware effect is checked by §18. (This run used
> the cap of 3 that existed at the time; the cap has since been removed.)

---

## 17. Product Real teardown/starvation hardening smoke (P177–P182 checkpoint)

Manual smoke for the teardown/starvation hardening checkpoint (commit `88bbed5`; rationale in
`docs/DECISIONS.md`, roadmap entry "Product Real teardown/starvation hardening"). Use a Release
build with the panel closed for steady state; open the Advanced diagnostics card only briefly to
read the counters. Enable global Real App Control first.

Run these steps in order:

1. **One-session start/stop**: start Real for one app, let it play, stop it.
2. **Two-session combination change**: start Real for two apps.
3. **Cross-app change**: YouTube + Spotify Real → stop Spotify → start Music while YouTube stays
   active (the previously failing case). YouTube must stay clean throughout.
4. **Per-app restart**: with YouTube still active, stop Music Real → start Music Real again. Watch
   for transient Starv/clicks; a brief "Starting audio…" status is expected, not alarming Starv.
5. **Three-session rotation**: run three apps Real, then rotate (stop one, start another) a few
   times, keeping the other two active.
6. **Output switch**: switch output speakers ↔ headphones while sessions are active.
7. **Quit / reopen**: quit MacMiniMixer with sessions active, reopen, confirm no orphaned mute.
8. **Optional long-run**: the 30–60 minute three-session run (§16.5) — the open v0.14 gate.

For each step record: **Starv**, **Drops**, **Fail**, **Gap** (from the Advanced card / stop
detail), audible **clicks/crackle** (yes/no), and whether audio ever required
`sudo killall coreaudiod`.

**Expected final-retest result**:
- Starv / Drops / Fail remain 0 or non-alarming during normal steady state.
- No audible clicks or crackle.
- No `coreaudiod` restart required at any point.
- A silent app shows a neutral audio status ("Waiting for app audio" / "No app audio detected")
  and a freshly (re)started app may briefly show "Starting audio…" — neither should read as
  alarming Starv.

---

## 18. Product Real rapid-toggle guard smoke (Prompt 194)

Verifies the per-app pending-operation guard (see `docs/DECISIONS.md` "Why rapid Product Real
toggles are guarded…" and ROADMAP "Rapid Real-toggle protection"). Use a Release build with global
Real App Control enabled.

Single-row start spam:
1. Start audio in one app (e.g. Music) and make it Real.
2. While the row is starting, **rapidly click/toggle** the row (and drag its slider).
   - **Expected**: the row shows a non-interactive "working" badge during the transition; the extra
     clicks are ignored; only **one** session is created (no duplicate-start churn); no crackle.

Single-row stop spam:
3. With the row active, click stop and then **rapidly click/toggle** it again during teardown.
   - **Expected**: repeated attempts are ignored until the stop reaches its terminal state; the row
     ends cleanly stopped; no crackle.

Concurrent rows:
4. Repeat steps 1–3 with **2–3 concurrent Real sessions**, spamming toggles on individual rows and
   across rows.
   - **Expected**: each row guards independently; other active rows keep playing; no crackle/Starv.

Aggressive normal clicking + no app-count limit:
5. Do a burst of aggressive (but human-speed) on/off clicking across rows.
   - **Expected**: `Starv`/`Drops`/`Fail` stay 0 or non-alarming; no audible crackle. Rows clicked
     while another row is starting show the working badge (queued) and start one after another.
6. With 3 apps already Real, make a **4th** app Real.
   - **Expected**: the 4th app starts its own session (no app-count limit); **no** "Real app control
     supports 3 apps at a time" warning; the banner reads "first two names +2 more" with Stop All.
     For more apps, continue with §19.

For each step record: whether the "working" badge appears, audible **clicks/crackle** (yes/no),
`Starv`/`Drops`/`Fail`, and whether audio ever required `sudo killall coreaudiod`.

**Expected result**: the working badge appears during transitions and on queued rows; repeated
toggles are ignored until the operation completes; no duplicate-start churn; no crackle/Starv under
normal aggressive clicking; no app-count warning. A deliberate behavior: a toggle **cannot cancel an
in-flight start mid-flight** — the start finishes first, then the row can be stopped. A *queued*
row's own toggle is ignored too (it counts as pending), but Stop All, turning Real App Control off,
closing the panel, or quitting that app drops it before it starts.

**If severe audio loss occurs** (an app silent until the app is quit): quit MacMiniMixer, and only
if audio is still broken, `sudo killall coreaudiod`. This should **not** be expected in the normal
guarded flow — record it as a regression if it happens.

---

## 19. Many-app Product Real Control (no app-count limit — N-session characterization)

Product Real Control has **no app-count limit** (owner decision). Real-hardware resource evidence so
far stops at three sessions (§14.6, §16, §16.5, all measured before the direct output engine); the
direct engine was only listened to with up to six sessions (§21). This section is the gate for more.
Nothing here has been run yet — record only what you measure. Also confirm in the log that every
session started with `output=direct` (§21 step 2); a session on the legacy `AudioQueue` path is not
comparable.

Setup:
- **Release** build, single MacMiniMixer process (as in §16.1). Activity Monitor open on the
  MacMiniMixer row; Console.app filtered to `MacMiniMixer` (category `processTap` shows the
  per-session starvation attribution debug lines, `cleanup` the teardown).
- **5–8 apps playing audio continuously**: e.g. Music, Spotify, a browser/YouTube helper row, plus
  other tap-eligible players (VLC, IINA, a second browser, a game or meeting app, …). Include at
  least one browser/helper row so the queue has a slow resolution in it.
- Global "Real app control" ON, nothing Real yet. Note idle CPU with the panel closed.

Steps:
1. **Fast start via sliders.** Within a few seconds, move the slider of every app, one after
   another.
   - **Expected**: the first row starts; rows touched while another row is resolving/starting show
     the pending ("working") badge, then start one after another (a browser/helper row may take a
     second or more to resolve and the rows behind it wait). **No** "Finish resolving app audio
     first" / "Stop active live control first" / "Process Tap is already busy" / "supports N apps at
     a time" warnings. Each row ends Real; the banner reads "first two names +N more" with Stop All;
     each queued row's gain matches its slider when it started.
   - Record: number of Real apps, time from first slider move until the last row is Real.
2. **Steady state (panel closed, 5–10 min).** Close the panel.
   - Record: CPU (avg over ~1 min, panel closed), memory, threads, audible glitches yes/no; then
     briefly open the panel → Advanced and read Drops/Fail/Starv/Gap for the focused (most recently
     started) session; close it again. Also note panel-open CPU with Advanced collapsed vs expanded.
   - **Expected**: every app audible at its own gain; Drops/Fail stay 0; no audible glitch; CPU stable
     (no drift). Compare against the three-session baseline in §16.3 — do **not** assume linear
     scaling; write down what you see.
3. **Per-app stop.** Stop two different rows (row toggle).
   - **Expected**: only those apps return to normal volume; every other Real app keeps playing
     without a click or dropout.
4. **Quit one controlled app** (e.g. quit Music) — also try quitting the app that is selected in the
   Advanced picker (by default the first eligible app).
   - **Expected**: only that app's session ends; all other Real apps keep running.
5. **Output-device change** with all sessions active (speakers ↔ headphones, or connect AirPods).
   - **Expected**: all Real sessions stop ("output device changed"), every app's audio returns to
     normal on the new device without quitting anything; no orphaned mute; CPU returns to ~0%.
   - Record: time until all audio is back; any Drops/Fail/cleanup warnings in Console.
6. **Stop All.** Make the apps Real again, then press Stop All in the banner.
   - **Expected**: every session stops and every app's audio returns. Stop All tears sessions down
     one after another, so note how long it takes until the last app is back and CPU is ~0%.
7. **Queue cancellation.** While several rows are queued (repeat step 1), press Stop All / turn
   "Real app control" off / close the panel (one per run).
   - **Expected**: queued rows never start afterwards (no background helper probing after the panel
     closes); an in-flight helper resolution is cancelled by Stop All and does not start a session
     late.
8. **Sleep/wake.** Make the apps Real, close the panel, sleep the Mac briefly, wake, reopen.
   - **Expected**: as §14.6 — nothing Real after wake, all apps' audio normal, no resurrection. Note
     whether the Mac took noticeably long to go to sleep (the teardown is synchronous on the main
     thread and grows with the number of sessions).
9. **Quit MacMiniMixer** with all sessions active.
   - **Expected**: quits cleanly; all apps' audio normal afterwards; no `sudo killall coreaudiod`.
     Note whether quitting took noticeably long.

Record per step: number of sessions, CPU (panel closed), memory, threads, Drops/Fail/Starv/Gap,
audible glitch yes/no, timings asked for above, Console cleanup warnings, and whether audio ever
required `sudo killall coreaudiod`.

**Red flags** (record as regressions, with the Console log): an app silent/muted until MacMiniMixer
quits (orphan tap); a queued row that never starts or starts after Stop All / Real off / panel close;
other sessions stopping when one app quits; Drops/Fail > 0 or Starv rising together with an audible
glitch; CPU drifting up over time or not returning to ~0% after stops; sleep or quit hanging for
several seconds; any crash.

Notes:
- Known open items this run is meant to size: engine-initiated stops (output change / app exit /
  timeout) bypass the lifecycle and settle gates; the sleep/quit teardown blocks the main thread
  longer with every session; Stop All is sequential. See `docs/ROADMAP.md` "Many-session
  hardening".
- Record results as `> Reference (…)` blocks under this section, as in §16.3/§16.4.

---

## 20. Packaged build (zip) launch check

Use the ad-hoc signed zip from `scripts/package-app.sh`, the `MacMiniMixer-app` CI artifact, or a
draft release — downloaded **in a browser** so it carries the quarantine flag like a user download.

1. Verify the checksum in the folder that holds both files:
   `shasum -a 256 -c MacMiniMixer-<version>….zip.sha256`.
   - **Expected**: `OK`.
2. Unzip, move `MacMiniMixer.app` to `/Applications`, double-click it.
   - **Expected**: Gatekeeper blocks the first launch (ad-hoc signed, not notarized). Open it via
     Control-click → Open (macOS 13–14) or System Settings → Privacy & Security → **Open Anyway**
     (macOS 15+), as in `docs/RELEASING.md` §5.
3. After it opens:
   - **Expected**: the icon appears in the **menu bar**; there is no Dock icon or window; the panel
     opens; Finder → Get Info shows version `0.13` (unless a release bumped it) and "Copyright © 2026
     Ahmed Tuğra Kasem. MIT License."
4. Run a short smoke on the packaged app: §1.1, §2.3, §4.1 (macOS asks for System Audio Recording
   permission on the first Process Tap action — a new ad-hoc build may ask again), §4.4, §11.5.
   - **Expected**: same behavior as an Xcode build; after quitting, all audio is normal.

---

## 21. Direct output engine check (live output path)

Use after any change to the live audio path, on a new output device or sample rate, or whenever
something crackles. The default live output is the **direct aggregate output engine** (one aggregate
IOProc = output device + tap, writing straight to the device, no `AudioQueue`); the legacy
`AudioQueue` path is only a fallback. Record the output device, its sample rate (Audio MIDI Setup),
the macOS version and the Mac for every run.

Setup:
- A **Release** build (or the packaged zip, §20), System Audio Recording granted, global "Real app
  control" ON.
- Two to six apps playing audio continuously (e.g. Spotify, Music, a browser/YouTube row, a Safari
  web app).
- A Terminal for the log command (the live start line is `info` level, so `--info --debug` is
  needed):

  ```bash
  log show --last 30m --info --debug --predicate 'process == "MacMiniMixer"'
  ```

Steps:
1. **One session.** Move one row's slider to start Real control, then open the panel → Advanced and
   read the live diagnostics line.
   - **Expected**: `Queued 0` (the queue-only counters report 0 in direct mode), Drops 0, Fail 0,
     Starv 0; the app plays at its slider's gain; no audible crackle.
2. **Log lines.** Run the log command.
   - **Expected** for every started session: "Live control start requested … `output=direct`" and
     "Live control started … `output=direct` rate=<device rate> … tapRate=<tap rate>
     resample=<true|false>".
   - **Expected** about 2 s after a start where the tap and device rates differ (for example built-in
     speakers at 44.1 kHz): one notice "Live control direct resample report … `path=passthrough`
     … avgTapFramesPerCycle ≈ avgOutputFramesPerCycle … measuredRatio=1.00000 … `underruns=0
     overflows=0`" (the HAL already delivers the tap at the aggregate's rate). `path=converting` means
     the HAL delivered a different rate — record `measuredRatio` against `expectedRatio` and any
     underruns; it has not been seen on real hardware yet. With equal rates there is no report line
     (`resample=false`).
   - **Red flag**: "Live control direct output unavailable, falling back to AudioQueue … reason=…" —
     record the reason. Expected only for an output device with input streams or a real setup failure.
3. **Several sessions, repeated rounds.** Start 3–6 apps in quick succession (rows queue, §19 step
   1), then per-app stop and Stop All, and start them again — three rounds. Listen the whole time,
   especially right after a second session starts (where the old path crackled).
   - **Expected**: every start logs `output=direct`, no fallbacks, `underruns=0 overflows=0` in each
     report, no Core Audio error/overload lines, no audible crackle.
4. **Sample rates.** Repeat steps 1–3 with the output device at 48 kHz and at 44.1 kHz (built-in
   speakers default to 44.1 kHz). MacMiniMixer must **not** change the device's sample rate itself.
   - **Expected**: crackle-free at both; record `path=` for each.
5. **A second output device.** Switch the default output to another device (headphones, HDMI/USB DAC,
   Bluetooth); sessions stop on the device change (§12.1), then restart them.
   - Record: device, sample rate, the `output=` / `path=` lines, crackle yes/no. A device with input
     streams is expected to log "falling back to AudioQueue … output device has input streams" and
     `output=audioQueue`; crackle there is a known limit of the legacy path.
6. **A/B fallback switch.** `defaults write com.example.MacMiniMixer MacMiniMixerLiveOutputMode
   audioQueue`, quit and reopen MacMiniMixer, start a session.
   - **Expected**: log shows `output=audioQueue` and the Advanced `Queued` count rises. Remove the key
     (`defaults delete com.example.MacMiniMixer MacMiniMixerLiveOutputMode`) and reopen.
7. **Resample switch** (device at 44.1 kHz). `defaults write com.example.MacMiniMixer
   MacMiniMixerDirectResample off`, reopen, start a session.
   - **Expected**: "falling back to AudioQueue … reason=sample rate mismatch …" and
     `output=audioQueue`. Remove the key and reopen.

**Red flags**: any crackle with `output=direct`; an unexpected fallback; `underruns` or `overflows` > 0;
Core Audio errors in the log; an app silent after stopping (orphan tap — see §17).

> Reference (owner's ad-hoc runs, one MacBook Pro, listening + unified log; not a CPU or latency
> measurement): built-in speakers at **48 kHz**, five sessions (two Safari web apps, Safari, Spotify,
> Music), three rounds — every start `output=direct rate=48000`, no fallbacks, no Core Audio
> errors, no crackle. Built-in speakers at the default **44.1 kHz**, up to six sessions with repeated
> stop/start rounds — `path=passthrough` (512 tap frames per 512 output frames, `measuredRatio=1.00000`),
> `underruns=0 overflows=0`, no crackle. A second output device at 48 kHz with Firefox, Safari, Spotify,
> Music and YouTube — crackle-free; every start on that device logged `output=direct rate=48000 resample=false`.

---

## Notes

- To read the app's recent log in Terminal (Release or Debug):
  `log show --last 30m --info --debug --predicate 'process == "MacMiniMixer"'` (see §21 for the lines
  worth looking for).
- All Process Tap tests require macOS 14.2 or later. On older macOS, all Process Tap
  actions should return "Process Tap requires macOS 14.2 or later" without crashing.
- System Audio Recording permission must be granted. If not granted, tap creation returns
  `kAudioDevicePermissionsError` and the UI shows "Audio capture permission was denied".
- No audio is saved to disk during any of these tests.
- All temporary Core Audio resources (tap, aggregate device, IOProc) should be destroyed
  on session end. Check Console.app for `MacMiniMixer cleanup` log messages to confirm.
