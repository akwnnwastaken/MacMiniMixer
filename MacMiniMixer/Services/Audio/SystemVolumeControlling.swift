import Foundation

protocol SystemVolumeControlling {
    @discardableResult
    func setCurrentOutputVolumeScalar(_ volumeScalar: Double) -> Bool

    /// Read-only, synchronous probe of whether `setCurrentOutputVolumeScalar(_:)` can
    /// write the current default output device's volume. It never writes and never
    /// installs listeners.
    ///
    /// - Returns: `true` when the write path would find a settable volume property,
    ///   `false` when the device exposes no settable volume property, or `nil` when
    ///   writability is unknown (no default device, a failed query, or a controller
    ///   that does not support probing).
    func isCurrentOutputVolumeSettable() -> Bool?
}

extension SystemVolumeControlling {
    /// Default: writability is unknown, so callers keep assuming the device is writable.
    func isCurrentOutputVolumeSettable() -> Bool? {
        nil
    }
}
