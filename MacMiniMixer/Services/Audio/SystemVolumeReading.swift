import Foundation

protocol SystemVolumeReading {
    /// Returns the current default output volume as a 0.0...1.0 scalar, or nil if unavailable.
    func readCurrentOutputVolumeScalar() -> Double?
    /// Returns the default output device's own mute flag (separate from its volume), or nil if
    /// the device has no readable mute.
    func readCurrentOutputMuted() -> Bool?
}

extension SystemVolumeReading {
    func readCurrentOutputMuted() -> Bool? {
        nil
    }
}
