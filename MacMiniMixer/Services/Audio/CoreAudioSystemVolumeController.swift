import CoreAudio
import Foundation

struct CoreAudioSystemVolumeController: SystemVolumeControlling {
    /// Scopes tried, in order, by both the volume write path and the writability probe.
    private static let volumeScopes: [AudioObjectPropertyScope] = [
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyScopeGlobal
    ]

    /// Per-channel elements tried when no main (virtual master) volume element is writable.
    private static let channelElements: [AudioObjectPropertyElement] = [
        AudioObjectPropertyElement(1),
        AudioObjectPropertyElement(2)
    ]

    func setCurrentOutputVolumeScalar(_ volumeScalar: Double) -> Bool {
        guard let deviceID = CoreAudioHelpers.defaultOutputDeviceID() else {
            return false
        }

        return setOutputVolumeScalar(volumeScalar, for: deviceID)
    }

    func isCurrentOutputVolumeSettable() -> Bool? {
        guard let deviceID = CoreAudioHelpers.defaultOutputDeviceID() else {
            return nil
        }

        return isOutputVolumeSettable(for: deviceID)
    }

    private func setOutputVolumeScalar(_ volumeScalar: Double, for deviceID: AudioDeviceID) -> Bool {
        let clampedScalar = Float32(volumeScalar.clamped(to: 0...1))

        for scope in Self.volumeScopes {
            if setVolumeScalar(
                clampedScalar,
                for: deviceID,
                scope: scope,
                element: kAudioObjectPropertyElementMain
            ) {
                return true
            }
        }

        for scope in Self.volumeScopes {
            let channelResults = Self.channelElements
                .map { element in
                    setVolumeScalar(
                        clampedScalar,
                        for: deviceID,
                        scope: scope,
                        element: element
                    )
                }

            if channelResults.contains(true) {
                return true
            }
        }

        return false
    }

    /// Read-only mirror of `setOutputVolumeScalar(_:for:)`: checks the same device,
    /// selector, scopes, and elements in the same fallback order (main element per scope,
    /// then per-channel elements per scope), using the same settability check the write
    /// path applies before writing. Never writes.
    ///
    /// A device with no volume property at all reports `false`, because the write path
    /// would reject every address. A failed settability query with nothing settable
    /// reports `nil` (unknown) so a transient HAL error never marks a device read-only.
    private func isOutputVolumeSettable(for deviceID: AudioDeviceID) -> Bool? {
        let mainCandidates = Self.volumeScopes.map { scope in
            VolumePropertyCandidate(scope: scope, element: kAudioObjectPropertyElementMain)
        }
        let channelCandidates = Self.volumeScopes.flatMap { scope in
            Self.channelElements.map { element in
                VolumePropertyCandidate(scope: scope, element: element)
            }
        }

        var didAnyQueryFail = false

        for candidate in mainCandidates + channelCandidates {
            switch volumeSettability(for: deviceID, scope: candidate.scope, element: candidate.element) {
            case .settable:
                return true
            case .queryFailed:
                didAnyQueryFail = true
            case .unavailable, .notSettable:
                continue
            }
        }

        return didAnyQueryFail ? nil : false
    }

    private func setVolumeScalar(
        _ volumeScalar: Float32,
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        guard volumeSettability(for: deviceID, scope: scope, element: element) == .settable else {
            return false
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: element
        )
        var writableScalar = volumeScalar
        let dataSize = UInt32(MemoryLayout<Float32>.size)
        let setStatus = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            dataSize,
            &writableScalar
        )

        return setStatus == noErr
    }

    /// Shared by the write path and the probe so both agree on which addresses are writable.
    private func volumeSettability(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> VolumePropertySettability {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return .unavailable
        }

        var isSettable = DarwinBoolean(false)
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        guard settableStatus == noErr else {
            return .queryFailed
        }

        return isSettable.boolValue ? .settable : .notSettable
    }

    private struct VolumePropertyCandidate {
        let scope: AudioObjectPropertyScope
        let element: AudioObjectPropertyElement
    }

    private enum VolumePropertySettability {
        case unavailable
        case notSettable
        case settable
        case queryFailed
    }
}
