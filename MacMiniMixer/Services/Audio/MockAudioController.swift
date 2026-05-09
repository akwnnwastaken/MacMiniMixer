import Foundation

final class MockAudioController: AudioControlling {
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
