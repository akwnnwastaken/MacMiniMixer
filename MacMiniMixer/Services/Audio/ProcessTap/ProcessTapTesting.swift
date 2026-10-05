import Foundation

struct ProcessTapTarget: Equatable, Sendable {
    let appID: String
    let appName: String
    let processIdentifier: Int32?
    /// Further processes that belong to the same app and are tapped together with
    /// `processIdentifier` in one tap (browser / Electron audio helpers, the WebKit GPU process,
    /// child processes). Empty for a classic single-process target. Only the Product Real live path
    /// honors it; the Advanced tester, probes and Two-App Readiness tap `processIdentifier` alone.
    var additionalProcessIdentifiers: [Int32] = []

    /// The primary process (when valid) followed by the additional ones, without duplicates or
    /// invalid (non-positive) ids, in order.
    var allProcessIdentifiers: [Int32] {
        var candidates: [Int32] = []
        if let processIdentifier {
            candidates.append(processIdentifier)
        }
        candidates.append(contentsOf: additionalProcessIdentifiers)

        var seen = Set<Int32>()
        var result: [Int32] = []
        for candidate in candidates where candidate > 0 {
            if seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        return result
    }
}

struct ProcessTapDiagnosticProgress: Equatable, Sendable {
    let callbackCount: Int
    let peakLevel: Double
    let rmsLevel: Double
    let audioDetected: Bool
}

enum ProcessTapTestMode: Equatable, Sendable {
    case diagnostics
    case muteBehaviorProbe
}

protocol ProcessTapTesting: Sendable {
    func testProcessTap(
        for target: ProcessTapTarget,
        mode: ProcessTapTestMode,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult
}
