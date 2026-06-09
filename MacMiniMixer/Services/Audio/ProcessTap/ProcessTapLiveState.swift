import Foundation

enum ProcessTapLiveStopReason: Equatable, Sendable {
    case userStopped
    case timedOut
    case outputDeviceChanged
    case targetAppExited
    case appTerminating
    /// Controlled teardown because the system is going to sleep. A normal (non-failure) stop —
    /// distinct from quit/output-change so logs and diagnostics read accurately. Triggering this
    /// from a sleep observer is a later step (Phase 4c-2); adding the case here is behaviour-neutral.
    case systemSleep
    case setupFailed
}
