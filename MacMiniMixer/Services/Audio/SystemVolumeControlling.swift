import Foundation

protocol SystemVolumeControlling {
    @discardableResult
    func setCurrentOutputVolumeScalar(_ volumeScalar: Double) -> Bool
}
