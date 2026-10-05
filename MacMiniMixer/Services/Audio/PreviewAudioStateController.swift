import Foundation

/// The production `AudioControlling` implementation: an in-memory UI-state store, not an audio path.
///
/// It records the per-app preview slider values and mute flags for app rows, plus a cached copy of
/// the system output volume used for the initial/display value. It never touches Core Audio and has
/// no effect on any app's real audio.
///
/// Real audio changes happen elsewhere: system output volume is read and written through Core Audio
/// via `SystemVolumeReading` / `SystemVolumeControlling` (see `SystemOutputCoordinator`), and an
/// active Product Real Control row drives real per-app gain through the Process Tap live controller.
final class PreviewAudioStateController: AudioControlling {
    private(set) var systemVolume: Double = 68
    private var appVolumes: [MixerAppItem.ID: Double] = [:]
    private var mutedApps: Set<MixerAppItem.ID> = []

    func setSystemVolume(_ volume: Double) {
        systemVolume = volume
    }

    func setVolume(_ volume: Double, for appID: MixerAppItem.ID) {
        appVolumes[appID] = volume
    }

    func setMuted(_ isMuted: Bool, for appID: MixerAppItem.ID) {
        if isMuted {
            mutedApps.insert(appID)
        } else {
            mutedApps.remove(appID)
        }
    }
}
