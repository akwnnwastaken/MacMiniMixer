import Foundation

final class MockSystemVolumeController: SystemVolumeControlling {
    private(set) var volumeScalar: Double
    private let shouldSucceed: Bool

    init(volumeScalar: Double = 0.68, shouldSucceed: Bool = true) {
        self.volumeScalar = volumeScalar
        self.shouldSucceed = shouldSucceed
    }

    func setCurrentOutputVolumeScalar(_ volumeScalar: Double) -> Bool {
        guard shouldSucceed else {
            return false
        }

        self.volumeScalar = volumeScalar.clamped(to: 0...1)
        return true
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
