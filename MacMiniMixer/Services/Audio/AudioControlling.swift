import Foundation

protocol AudioControlling {
    var systemVolume: Double { get }

    func setSystemVolume(_ volume: Double)
    func setVolume(_ volume: Double, for appID: MixerAppItem.ID)
    func setMuted(_ isMuted: Bool, for appID: MixerAppItem.ID)
}
