import CoreAudio
import Foundation

struct ProcessTapLiveSessionID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum ProcessTapLiveSessionPhase: Equatable, Sendable {
    case starting
    case active
    case stopping
    case stopped
    case failed
}

struct ProcessTapLiveSessionState: Identifiable, Equatable, Sendable {
    let id: ProcessTapLiveSessionID
    let appID: String
    let appName: String
    let processIdentifier: Int32?
    let outputDeviceIDAtStart: AudioDeviceID?
    let startedAt: Date
    var gain: ProcessTapReplayGainOption
    var phase: ProcessTapLiveSessionPhase
    var diagnostics: ProcessTapLiveDiagnostics?
    var stopReason: ProcessTapLiveStopReason?
    var cleanupWarnings: [String]

    init(
        id: ProcessTapLiveSessionID = ProcessTapLiveSessionID(),
        target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        outputDeviceIDAtStart: AudioDeviceID? = ProcessTapCoreAudio.defaultOutputDeviceID(),
        phase: ProcessTapLiveSessionPhase = .starting
    ) {
        self.id = id
        self.appID = target.appID
        self.appName = target.appName
        self.processIdentifier = target.processIdentifier
        self.outputDeviceIDAtStart = outputDeviceIDAtStart
        self.startedAt = Date()
        self.gain = gain
        self.phase = phase
        self.cleanupWarnings = []
    }
}

struct ProcessTapLiveSessionStartResult: Sendable {
    let sessionID: ProcessTapLiveSessionID?
    let result: ProcessTapTestResult
}
