import Foundation

protocol SystemVolumeReading {
    /// Returns the current default output volume as a 0.0...1.0 scalar, or nil if unavailable.
    func readCurrentOutputVolumeScalar() -> Double?
}
