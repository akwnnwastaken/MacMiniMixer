struct AdvancedProcessTapTarget: Identifiable, Equatable, Sendable {
    let target: ProcessTapTarget
    let parentAppName: String
    let relation: HelperProcessRelation
    let eligibility: ProcessTapProcessEligibility
    let probeResult: ProcessTapTestResult?

    var id: String { target.appID }

    var displayName: String {
        "\(parentAppName) helper"
    }

    var detail: String {
        let pidText = target.processIdentifier.map { "PID \($0)" } ?? "PID -"
        return "\(target.appName) · \(pidText) · \(relation.label)"
    }

    var twoAppReadinessTitle: String {
        let pidText = target.processIdentifier.map { "PID \($0)" } ?? "PID -"
        return "Helper: \(parentAppName) \(pidText)"
    }
}

struct HelperProcessAutoDetectScore: Comparable {
    let processIdentifier: Int32
    let result: ProcessTapTestResult
    let progress: ProcessTapDiagnosticProgress

    var hasDetectedAudio: Bool {
        progress.audioDetected || result.outcome == .streamDiagnosticsDetectedAudio
    }

    static func < (lhs: HelperProcessAutoDetectScore, rhs: HelperProcessAutoDetectScore) -> Bool {
        if lhs.hasDetectedAudio != rhs.hasDetectedAudio {
            return !lhs.hasDetectedAudio && rhs.hasDetectedAudio
        }

        if lhs.progress.rmsLevel != rhs.progress.rmsLevel {
            return lhs.progress.rmsLevel < rhs.progress.rmsLevel
        }

        if lhs.progress.peakLevel != rhs.progress.peakLevel {
            return lhs.progress.peakLevel < rhs.progress.peakLevel
        }

        return lhs.progress.callbackCount < rhs.progress.callbackCount
    }
}

extension MixerAppItem {
    var helperProcessDiscoveryTarget: HelperProcessDiscoveryTarget {
        HelperProcessDiscoveryTarget(
            id: id,
            name: name,
            processIdentifier: processIdentifier
        )
    }
}
