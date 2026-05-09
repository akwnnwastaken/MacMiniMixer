struct MockProcessTapTester: ProcessTapTesting {
    let result: ProcessTapTestResult

    init(
        result: ProcessTapTestResult = ProcessTapTestResult(
            outcome: .tapSetupSucceeded,
            message: "Mock Process Tap test result",
            severity: .info
        )
    ) {
        self.result = result
    }

    func testProcessTap(
        for target: ProcessTapTarget,
        mode: ProcessTapTestMode,
        onProgress: @escaping @Sendable (ProcessTapDiagnosticProgress) -> Void
    ) async -> ProcessTapTestResult {
        onProgress(
            ProcessTapDiagnosticProgress(
                callbackCount: 0,
                peakLevel: 0,
                rmsLevel: 0,
                audioDetected: false
            )
        )
        return result
    }
}
