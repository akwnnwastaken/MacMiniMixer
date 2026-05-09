import Foundation

struct MockSystemVolumeReader: SystemVolumeReading {
    private let volumeScalar: Double?

    init(volumeScalar: Double? = nil) {
        self.volumeScalar = volumeScalar
    }

    func readCurrentOutputVolumeScalar() -> Double? {
        volumeScalar
    }
}
