import Foundation

enum ProcessTapLiveStopReason: Equatable, Sendable {
    case userStopped
    case timedOut
    case outputDeviceChanged
    case targetAppExited
    case appTerminating
    case setupFailed
}
