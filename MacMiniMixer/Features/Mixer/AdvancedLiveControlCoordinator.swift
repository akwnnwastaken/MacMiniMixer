import Foundation

@MainActor
final class AdvancedLiveControlCoordinator {
    nonisolated private let liveController: ProcessTapLiveControlling
    private let diagnostics: AdvancedProcessTapDiagnosticsCoordinator

    init(
        liveController: ProcessTapLiveControlling,
        diagnostics: AdvancedProcessTapDiagnosticsCoordinator
    ) {
        self.liveController = liveController
        self.diagnostics = diagnostics
    }

    func startLiveControl(
        apps: [MixerAppItem],
        selectedAppID: MixerAppItem.ID?,
        gain: ProcessTapReplayGainOption,
        isLiveControlActive: Bool,
        isTwoAppReadinessRunning: Bool,
        isAppAudioTargetResolving: Bool,
        onDiagnostics: @escaping @MainActor (ProcessTapLiveDiagnostics) -> Void,
        onStarted: @escaping @MainActor (String) -> Void,
        onFailed: @escaping @MainActor (ProcessTapTestResult) -> Void,
        onStopped: @escaping @MainActor (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) {
        guard !diagnostics.isRunningDiagnostics,
              !isLiveControlActive,
              !isTwoAppReadinessRunning,
              !isAppAudioTargetResolving else {
            return
        }

        guard let selectedAppID,
              let app = apps.first(where: { $0.id == selectedAppID }) else {
            diagnostics.setResult(
                ProcessTapTestResult(
                    outcome: .invalidTarget,
                    message: "Select a running app",
                    severity: .warning
                )
            )
            return
        }

        let target = ProcessTapTarget(
            appID: app.id,
            appName: app.name,
            processIdentifier: app.processIdentifier
        )

        diagnostics.setResult(
            ProcessTapTestResult(
                outcome: .liveControlStarting,
                message: "Starting live control for \(app.name)...",
                detail: "Experimental: original output is suppressed and replayed with gain \(gain.percentLabel).",
                severity: .info
            )
        )
        diagnostics.setProgress(
            ProcessTapDiagnosticProgress(
                callbackCount: 0,
                peakLevel: 0,
                rmsLevel: 0,
                audioDetected: false
            )
        )
        diagnostics.setRunning(true)

        Task {
            let result = await liveController.startLiveControl(
                for: target,
                gain: gain
            ) { liveDiagnostics in
                Task { @MainActor in
                    onDiagnostics(liveDiagnostics)
                    self.diagnostics.setProgress(liveDiagnostics.progress)
                }
            } onStopped: { result, liveDiagnostics in
                Task { @MainActor in
                    onStopped(result, liveDiagnostics)
                }
            }

            await MainActor.run {
                diagnostics.setResult(result)
                diagnostics.setRunning(false)

                if result.outcome == .liveControlStarted {
                    onStarted(app.name)
                } else {
                    diagnostics.setProgress(nil)
                    onFailed(result)
                }
            }
        }
    }

    func stopLiveControl(
        reason: ProcessTapLiveStopReason,
        isLiveControlActive: Bool,
        currentDiagnostics: ProcessTapLiveDiagnostics?,
        onNotActive: @escaping @MainActor (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) {
        guard isLiveControlActive || diagnostics.isRunningDiagnostics else {
            return
        }

        Task {
            let result = await liveController.stopLiveControl(reason: reason)

            await MainActor.run {
                if result.outcome == .liveControlNotActive {
                    onNotActive(result, currentDiagnostics)
                }
            }
        }
    }
}
