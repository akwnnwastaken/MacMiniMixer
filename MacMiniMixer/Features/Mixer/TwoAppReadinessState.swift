import Foundation

struct TwoAppReadinessTargetOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let target: ProcessTapTarget
    let eligibility: ProcessTapProcessEligibility
    let isHelper: Bool

    var processIdentifier: Int32? {
        target.processIdentifier
    }
}

enum TwoAppReadinessState {
    static func targetOptions(
        apps: [MixerAppItem],
        eligibilityByAppID: [MixerAppItem.ID: ProcessTapProcessEligibility],
        advancedProcessTapTarget: AdvancedProcessTapTarget?,
        processTapEligibility: @Sendable (Int32?) -> ProcessTapProcessEligibility
    ) -> [TwoAppReadinessTargetOption] {
        let appTargets = apps.compactMap { app -> TwoAppReadinessTargetOption? in
            guard eligibilityByAppID[app.id]?.isEligible == true else {
                return nil
            }

            return TwoAppReadinessTargetOption(
                id: app.id,
                title: app.name,
                detail: app.processIdentifier.map { "PID \($0)" },
                target: ProcessTapTarget(
                    appID: app.id,
                    appName: app.name,
                    processIdentifier: app.processIdentifier
                ),
                eligibility: eligibilityByAppID[app.id] ?? .unavailable("Core Audio process unavailable"),
                isHelper: false
            )
        }

        guard let advancedProcessTapTarget else {
            return appTargets
        }

        let helperEligibility = processTapEligibility(advancedProcessTapTarget.target.processIdentifier)
        guard helperEligibility.isEligible else {
            return appTargets
        }

        let helperTarget = TwoAppReadinessTargetOption(
            id: advancedProcessTapTarget.id,
            title: advancedProcessTapTarget.twoAppReadinessTitle,
            detail: advancedProcessTapTarget.detail,
            target: ProcessTapTarget(
                appID: advancedProcessTapTarget.target.appID,
                appName: advancedProcessTapTarget.twoAppReadinessTitle,
                processIdentifier: advancedProcessTapTarget.target.processIdentifier
            ),
            eligibility: helperEligibility,
            isHelper: true
        )

        return appTargets + [helperTarget]
    }

    static func preferredAppIDs(
        in apps: [MixerAppItem],
        eligibilityByAppID: [MixerAppItem.ID: ProcessTapProcessEligibility]
    ) -> (appAID: MixerAppItem.ID?, appBID: MixerAppItem.ID?) {
        let eligibleApps = apps.filter { app in
            eligibilityByAppID[app.id]?.isEligible == true
        }

        return (
            appAID: eligibleApps.first?.id,
            appBID: eligibleApps.dropFirst().first?.id
        )
    }

    static func preferredTargetIDs(
        in targets: [TwoAppReadinessTargetOption]
    ) -> (appAID: String?, appBID: String?) {
        let appA = targets.first
        let appB = targets.first { target in
            target.id != appA?.id && target.processIdentifier != appA?.processIdentifier
        }

        return (
            appAID: appA?.id,
            appBID: appB?.id
        )
    }

    static func eligibilityByAppID(
        for apps: [MixerAppItem],
        processTapEligibility: @Sendable (Int32?) -> ProcessTapProcessEligibility
    ) -> [MixerAppItem.ID: ProcessTapProcessEligibility] {
        Dictionary(
            uniqueKeysWithValues: apps.map { app in
                (app.id, processTapEligibility(app.processIdentifier))
            }
        )
    }

    static func targetsUseSameProcess(
        _ targetA: TwoAppReadinessTargetOption?,
        _ targetB: TwoAppReadinessTargetOption?
    ) -> Bool {
        guard let targetA, let targetB else {
            return false
        }

        return targetA.processIdentifier == targetB.processIdentifier
    }

    static func validProcessIdentifier(_ processIdentifier: Int32?) -> Bool {
        guard let processIdentifier else {
            return false
        }

        return processIdentifier > 0
    }

    /// Maps a finished Two-App Readiness run to its aggregate result.
    ///
    /// Failure precedence: if **any** session did not tear down cleanly (`phase == .failed` —
    /// set when the controller returned `.tapCleanupFailed`, or when a session never completed),
    /// the run reports a visible `.cleanupWarning` instead of a normal `.timedOut`/`.stopped`
    /// result. This is the fix for the reporting gap where a per-session Core Audio cleanup
    /// failure (e.g. a Process Tap that failed to destroy) was hidden under the normal stop
    /// outcome, so a user saw "stopped" while a muted tap lingered. On the clean path the result
    /// is identical to before. Pure and side-effect-free so it can be unit-tested directly.
    static func aggregateResult(
        reason: ProcessTapLiveStopReason,
        snapshot: ProcessTapTwoAppReadinessSnapshot
    ) -> ProcessTapTwoAppReadinessResult {
        let detail = snapshot.sessions
            .map { session in
                let diagnostics = session.diagnostics
                return "\(session.appName): \(diagnostics?.callbackCount ?? 0) cb, drops \(diagnostics?.droppedBufferCount ?? 0), fail \(diagnostics?.totalFailureCount ?? 0)"
            }
            .joined(separator: " | ")

        let failedSessions = snapshot.sessions.filter { $0.phase == .failed }
        if !failedSessions.isEmpty {
            let failureDetail = failedSessions
                .map { "\($0.appName): \($0.cleanupFailureDetail ?? $0.message ?? "cleanup failed")" }
                .joined(separator: " | ")
            let cleanSessions = snapshot.sessions.filter { $0.phase != .failed }
            let cleanNote = cleanSessions.isEmpty
                ? ""
                : " | clean: \(cleanSessions.map(\.appName).joined(separator: ", "))"

            return ProcessTapTwoAppReadinessResult(
                outcome: .cleanupWarning,
                message: "Two-app test stopped with cleanup warnings",
                detail: failureDetail + cleanNote,
                severity: .warning
            )
        }

        switch reason {
        case .timedOut:
            return ProcessTapTwoAppReadinessResult(
                outcome: .timedOut,
                message: "Two-app test stopped: timeout",
                detail: detail,
                severity: .warning
            )
        case .outputDeviceChanged:
            return ProcessTapTwoAppReadinessResult(
                outcome: .outputDeviceChanged,
                message: "Two-app test stopped: output changed",
                detail: detail,
                severity: .warning
            )
        case .targetAppExited:
            return ProcessTapTwoAppReadinessResult(
                outcome: .appExited,
                message: "Two-app test stopped: app exited",
                detail: detail,
                severity: .warning
            )
        case .appTerminating:
            return ProcessTapTwoAppReadinessResult(
                outcome: .stopped,
                message: "Two-app test stopped for quit",
                detail: detail,
                severity: .info
            )
        case .systemSleep:
            return ProcessTapTwoAppReadinessResult(
                outcome: .stopped,
                message: "Two-app test stopped: system sleep",
                detail: detail,
                severity: .info
            )
        case .setupFailed:
            return ProcessTapTwoAppReadinessResult(
                outcome: .setupFailed,
                message: "Two-app setup failed",
                detail: detail,
                severity: .warning
            )
        case .userStopped:
            return ProcessTapTwoAppReadinessResult(
                outcome: .stopped,
                message: "Two-app test stopped",
                detail: detail,
                severity: .info
            )
        }
    }

    static func startingSnapshot(
        appA: ProcessTapTarget,
        appB: ProcessTapTarget,
        gain: ProcessTapReplayGainOption
    ) -> ProcessTapTwoAppReadinessSnapshot {
        ProcessTapTwoAppReadinessSnapshot(
            sessions: [
                .starting(slot: .appA, target: appA, gain: gain),
                .starting(slot: .appB, target: appB, gain: gain)
            ]
        )
    }
}
