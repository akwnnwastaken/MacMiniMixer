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
