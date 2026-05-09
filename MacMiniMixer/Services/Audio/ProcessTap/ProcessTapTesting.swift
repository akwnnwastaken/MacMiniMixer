import Foundation

struct ProcessTapTarget: Equatable, Sendable {
    let appID: String
    let appName: String
    let processIdentifier: Int32?
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
