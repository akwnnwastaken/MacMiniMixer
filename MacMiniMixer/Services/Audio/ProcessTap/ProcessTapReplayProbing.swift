import Foundation

struct ProcessTapReplayGainOption: Identifiable, Equatable, Sendable {
    let scalar: Float
    let label: String

    var id: Float {
        scalar
    }

    var percentLabel: String {
        label
    }

    static let options: [ProcessTapReplayGainOption] = [
        ProcessTapReplayGainOption(scalar: 0.25, label: "25%"),
        ProcessTapReplayGainOption(scalar: 0.5, label: "50%"),
        ProcessTapReplayGainOption(scalar: 0.75, label: "75%"),
        ProcessTapReplayGainOption(scalar: 1.0, label: "100%")
    ]

    static let defaultOption = ProcessTapReplayGainOption(scalar: 0.5, label: "50%")
}

protocol ProcessTapReplayProbing: Sendable {
    func runReplayProbe(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapReplayResult
}
