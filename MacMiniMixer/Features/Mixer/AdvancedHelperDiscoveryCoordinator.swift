import Foundation

@MainActor
final class AdvancedHelperDiscoveryCoordinator {
    private let processLister: ProcessListing
    private let helperProcessAudioProbe: ProcessTapCandidateAudioProbing
    private let processTapEligibility: @Sendable (Int32) -> ProcessTapProcessEligibility
    private var onWillChange: (@MainActor () -> Void)?
    private var onAdvancedTargetChanged: (@MainActor (_ removedTargetID: String?) -> Void)?

    private(set) var selectedAppID: MixerAppItem.ID?
    private(set) var candidates: [HelperProcessCandidate] = []
    private(set) var message: String?
    private(set) var isScanning = false
    private(set) var isAutoDetectRunning = false
    private(set) var autoDetectProgressText: String?
    private(set) var advancedTarget: AdvancedProcessTapTarget?
    private(set) var probeResultsByPID: [Int32: ProcessTapTestResult] = [:]
    private(set) var probeProgressByPID: [Int32: ProcessTapDiagnosticProgress] = [:]
    private(set) var runningProbePID: Int32?
    private var autoDetectTask: Task<Void, Never>?
    private var selectedAppName: String?

    init(
        processLister: ProcessListing,
        helperProcessAudioProbe: ProcessTapCandidateAudioProbing,
        initialApps: [MixerAppItem],
        processTapEligibility: @escaping @Sendable (Int32) -> ProcessTapProcessEligibility = {
            ProcessTapCoreAudio.processTapEligibility(for: $0)
        },
        onWillChange: (@MainActor () -> Void)? = nil
    ) {
        self.processLister = processLister
        self.helperProcessAudioProbe = helperProcessAudioProbe
        self.processTapEligibility = processTapEligibility
        self.onWillChange = onWillChange
        self.selectedAppID = Self.preferredHelperDiscoveryAppID(in: initialApps)
        self.selectedAppName = selectedAppID.flatMap { selectedID in
            initialApps.first { $0.id == selectedID }?.name
        }
    }

    func setOnWillChange(_ onWillChange: (@MainActor () -> Void)?) {
        self.onWillChange = onWillChange
    }

    func setOnAdvancedTargetChanged(_ onAdvancedTargetChanged: (@MainActor (_ removedTargetID: String?) -> Void)?) {
        self.onAdvancedTargetChanged = onAdvancedTargetChanged
    }

    func selectApp(
        _ appID: MixerAppItem.ID,
        apps: [MixerAppItem],
        isAutoDetectRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) {
        guard !isScanning,
              runningProbePID == nil,
              !self.isAutoDetectRunning,
              !isAppAudioTargetResolving,
              apps.contains(where: { $0.id == appID }) else {
            return
        }

        sendWillChange()
        selectedAppID = appID
        selectedAppName = apps.first { $0.id == appID }?.name
        candidates = []
        message = nil
        probeResultsByPID = [:]
        probeProgressByPID = [:]
    }

    func scanHelperProcesses(
        apps: [MixerAppItem],
        isAutoDetectRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) {
        Task {
            await scanHelperProcessesNow(
                apps: apps,
                isAutoDetectRunning: isAutoDetectRunning,
                isAppAudioTargetResolving: isAppAudioTargetResolving
            )
        }
    }

    func scanHelperProcessesNow(
        apps: [MixerAppItem],
        isAutoDetectRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) async {
        guard !isScanning,
              runningProbePID == nil,
              !self.isAutoDetectRunning,
              !isAppAudioTargetResolving else {
            return
        }

        guard let app = selectedHelperDiscoveryApp(in: apps) else {
            sendWillChange()
            message = "Select a visible app"
            candidates = []
            return
        }

        sendWillChange()
        selectedAppName = app.name
        isScanning = true
        message = nil
        candidates = []
        probeResultsByPID = [:]
        probeProgressByPID = [:]

        let processLister = processLister
        let eligibilityChecker = processTapEligibility
        let processes = await Task.detached(priority: .userInitiated) {
            processLister.listProcesses()
        }.value
        let scannedCandidates = HelperProcessCandidateDiscovery.candidates(
            for: app.helperProcessDiscoveryTarget,
            processes: processes,
            eligibilityChecker: eligibilityChecker
        )
        let eligibleCount = scannedCandidates.filter { $0.isTapEligible }.count

        guard selectedAppID == app.id else {
            sendWillChange()
            isScanning = false
            return
        }

        sendWillChange()
        candidates = scannedCandidates
        isScanning = false

        if scannedCandidates.isEmpty {
            message = "No related helper candidates found"
        } else if eligibleCount == 0 {
            message = "No tap-eligible helper processes found"
        } else {
            message = "\(eligibleCount) tap-eligible candidate\(eligibleCount == 1 ? "" : "s")"
        }
    }

    func probeHelperProcessCandidate(
        _ processIdentifier: Int32,
        isAutoDetectRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) {
        Task {
            await probeHelperProcessCandidateNow(
                processIdentifier,
                isAutoDetectRunning: isAutoDetectRunning,
                isAppAudioTargetResolving: isAppAudioTargetResolving
            )
        }
    }

    func probeHelperProcessCandidateNow(
        _ processIdentifier: Int32,
        isAutoDetectRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) async {
        guard runningProbePID == nil,
              !self.isAutoDetectRunning,
              !isAppAudioTargetResolving else {
            return
        }

        guard let candidate = candidates.first(where: { $0.id == processIdentifier }),
              candidate.isTapEligible else {
            sendWillChange()
            probeResultsByPID[processIdentifier] = ProcessTapTestResult(
                outcome: .processNotFound,
                message: "Core Audio process unavailable",
                severity: .warning
            )
            return
        }

        let target = ProcessTapTarget(
            appID: "process:\(candidate.process.processIdentifier)",
            appName: candidate.process.name,
            processIdentifier: candidate.process.processIdentifier
        )
        let initialProgress = ProcessTapDiagnosticProgress(
            callbackCount: 0,
            peakLevel: 0,
            rmsLevel: 0,
            audioDetected: false
        )

        beginProbe(
            processIdentifier,
            progress: initialProgress,
            result: ProcessTapTestResult(
                outcome: .helperProbeRunning,
                message: "Probing...",
                detail: "Listening briefly. No audio will be replayed, saved, or modified.",
                severity: .info
            )
        )

        let result = await helperProcessAudioProbe.probeAudio(
            for: target,
            duration: AppConstants.processTapDiagnosticDuration
        ) { [weak self] progress in
            Task { @MainActor in
                self?.updateProbeProgress(processIdentifier, progress: progress)
            }
        }

        finishProbe(processIdentifier, result: result)
    }

    func stopProbe(reason: ProcessTapCandidateProbeStopReason) {
        guard runningProbePID != nil else {
            return
        }

        helperProcessAudioProbe.stopCurrentProbe(reason: reason)
    }

    func autoDetectHelperProcessCandidate(isAppAudioTargetResolving: Bool) {
        guard !isAutoDetectRunning,
              runningProbePID == nil,
              !isScanning,
              !isAppAudioTargetResolving else {
            return
        }

        let eligibleCandidates = candidates.filter { $0.isTapEligible }
        guard !eligibleCandidates.isEmpty else {
            setMessage("No tap-eligible helper processes found")
            return
        }

        guard selectedAppID != nil else {
            setMessage("Select a visible app")
            return
        }

        sendWillChange()
        isAutoDetectRunning = true
        autoDetectProgressText = "Testing 1/\(eligibleCandidates.count)"
        message = "Testing 1/\(eligibleCandidates.count)"
        AppLogger.helperResolution.info("Advanced helper auto-detect started candidates=\(eligibleCandidates.count, privacy: .public)")

        autoDetectTask?.cancel()
        autoDetectTask = Task { [weak self] in
            await self?.runAutoDetect(candidates: eligibleCandidates)
        }
    }

    func autoDetectHelperProcessCandidateNow(isAppAudioTargetResolving: Bool) async {
        guard !isAutoDetectRunning,
              runningProbePID == nil,
              !isScanning,
              !isAppAudioTargetResolving else {
            return
        }

        let eligibleCandidates = candidates.filter { $0.isTapEligible }
        guard !eligibleCandidates.isEmpty else {
            setMessage("No tap-eligible helper processes found")
            return
        }

        guard selectedAppID != nil else {
            setMessage("Select a visible app")
            return
        }

        sendWillChange()
        isAutoDetectRunning = true
        autoDetectProgressText = "Testing 1/\(eligibleCandidates.count)"
        message = "Testing 1/\(eligibleCandidates.count)"

        await runAutoDetect(candidates: eligibleCandidates)
    }

    func stopAutoDetect(reason: ProcessTapCandidateProbeStopReason) {
        guard isAutoDetectRunning else {
            return
        }

        autoDetectTask?.cancel()
        autoDetectTask = nil
        helperProcessAudioProbe.stopCurrentProbe(reason: reason)
    }

    func useCandidateAsAdvancedTarget(_ processIdentifier: Int32) -> Bool {
        guard !isAutoDetectRunning else {
            return false
        }

        return setAdvancedTargetFromCandidate(processIdentifier)
    }

    @discardableResult
    func clearAdvancedTarget(notify: Bool = true) -> String? {
        let removedTargetID = advancedTarget?.id

        sendWillChange()
        advancedTarget = nil

        if notify, removedTargetID != nil {
            onAdvancedTargetChanged?(removedTargetID)
        }

        return removedTargetID
    }

    func refreshSelectionAfterAppRefresh(apps: [MixerAppItem]) {
        let appIDs = Set(apps.map(\.id))

        guard selectedAppID.map({ appIDs.contains($0) }) != true else {
            selectedAppName = selectedHelperDiscoveryApp(in: apps)?.name
            return
        }

        sendWillChange()
        selectedAppID = Self.preferredHelperDiscoveryAppID(in: apps)
        selectedAppName = selectedAppID.flatMap { selectedID in
            apps.first { $0.id == selectedID }?.name
        }
        candidates = []
        message = nil
        probeResultsByPID = [:]
        probeProgressByPID = [:]
        runningProbePID = nil
    }

    func selectedHelperDiscoveryApp(in apps: [MixerAppItem]) -> MixerAppItem? {
        guard let selectedAppID else {
            return nil
        }

        return apps.first { $0.id == selectedAppID }
    }

    func candidate(processIdentifier: Int32) -> HelperProcessCandidate? {
        candidates.first { $0.id == processIdentifier }
    }

    func setMessage(_ message: String?) {
        sendWillChange()
        self.message = message
    }

    func beginProbe(
        _ processIdentifier: Int32,
        progress: ProcessTapDiagnosticProgress,
        result: ProcessTapTestResult
    ) {
        sendWillChange()
        runningProbePID = processIdentifier
        probeProgressByPID[processIdentifier] = progress
        probeResultsByPID[processIdentifier] = result
    }

    func updateProbeProgress(
        _ processIdentifier: Int32,
        progress: ProcessTapDiagnosticProgress
    ) {
        guard runningProbePID == processIdentifier else {
            return
        }

        sendWillChange()
        probeProgressByPID[processIdentifier] = progress
    }

    func finishProbe(
        _ processIdentifier: Int32,
        result: ProcessTapTestResult
    ) {
        sendWillChange()
        probeResultsByPID[processIdentifier] = result
        if runningProbePID == processIdentifier {
            runningProbePID = nil
        }
    }

    static func preferredHelperDiscoveryAppID(in apps: [MixerAppItem]) -> MixerAppItem.ID? {
        apps.first { app in
            HelperProcessCandidateDiscovery.isLikelyHelperResolvable(app.helperProcessDiscoveryTarget)
        }?.id ?? apps.first?.id
    }

    private func runAutoDetect(candidates: [HelperProcessCandidate]) async {
        var scoredResults: [HelperProcessAutoDetectScore] = []
        let parentAppID = selectedAppID

        for (index, candidate) in candidates.enumerated() {
            guard !Task.isCancelled,
                  isAutoDetectRunning,
                  selectedAppID == parentAppID else {
                finishAutoDetect(bestScore: nil, wasCancelled: true)
                return
            }

            let progressText = "Testing \(index + 1)/\(candidates.count)"
            sendWillChange()
            autoDetectProgressText = progressText
            message = progressText

            let processIdentifier = candidate.process.processIdentifier
            let target = ProcessTapTarget(
                appID: "process:\(processIdentifier)",
                appName: candidate.process.name,
                processIdentifier: processIdentifier
            )
            let initialProgress = ProcessTapDiagnosticProgress(
                callbackCount: 0,
                peakLevel: 0,
                rmsLevel: 0,
                audioDetected: false
            )

            beginProbe(
                processIdentifier,
                progress: initialProgress,
                result: ProcessTapTestResult(
                    outcome: .helperProbeRunning,
                    message: "Auto-detecting...",
                    detail: "Listening briefly. No audio will be replayed, saved, or modified.",
                    severity: .info
                )
            )

            let result = await helperProcessAudioProbe.probeAudio(
                for: target,
                duration: AppConstants.processTapHelperAutoDetectDuration
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self,
                          self.isAutoDetectRunning,
                          self.runningProbePID == processIdentifier else {
                        return
                    }

                    self.updateProbeProgress(processIdentifier, progress: progress)
                }
            }

            let finalProgress = probeProgressByPID[processIdentifier] ?? initialProgress
            finishProbe(processIdentifier, result: result)

            if result.outcome == .helperProbeTargetExited ||
                result.outcome == .helperProbeOutputChanged ||
                result.outcome == .helperProbeStopped {
                finishAutoDetect(bestScore: nil, wasCancelled: true)
                return
            }

            guard !Task.isCancelled,
                  isAutoDetectRunning,
                  selectedAppID == parentAppID else {
                finishAutoDetect(bestScore: nil, wasCancelled: true)
                return
            }

            scoredResults.append(
                HelperProcessAutoDetectScore(
                    processIdentifier: processIdentifier,
                    result: result,
                    progress: finalProgress
                )
            )
        }

        finishAutoDetect(
            bestScore: scoredResults.max(),
            wasCancelled: false
        )
    }

    private func finishAutoDetect(
        bestScore: HelperProcessAutoDetectScore?,
        wasCancelled: Bool
    ) {
        autoDetectTask = nil
        sendWillChange()
        isAutoDetectRunning = false
        autoDetectProgressText = nil

        guard !wasCancelled else {
            message = "Auto-detect stopped"
            AppLogger.helperResolution.info("Advanced helper auto-detect stopped")
            return
        }

        guard let bestScore,
              bestScore.hasDetectedAudio else {
            message = "No audio helper detected"
            AppLogger.helperResolution.info("Advanced helper auto-detect found no audio helper")
            return
        }

        _ = setAdvancedTargetFromCandidate(bestScore.processIdentifier)
        message = "Selected audio helper"
        AppLogger.helperResolution.info("Advanced helper auto-detect selected helperPID=\(bestScore.processIdentifier, privacy: .public) rms=\(bestScore.progress.rmsLevel, privacy: .public) peak=\(bestScore.progress.peakLevel, privacy: .public)")
    }

    private func setAdvancedTargetFromCandidate(_ processIdentifier: Int32) -> Bool {
        guard let candidate = candidate(processIdentifier: processIdentifier),
              candidate.isTapEligible else {
            sendWillChange()
            probeResultsByPID[processIdentifier] = ProcessTapTestResult(
                outcome: .processNotFound,
                message: "Core Audio process unavailable",
                severity: .warning
            )
            return false
        }

        let parentAppName = selectedAppName ?? "Selected app"
        sendWillChange()
        advancedTarget = AdvancedProcessTapTarget(
            target: ProcessTapTarget(
                appID: "helper:\(parentAppName):\(candidate.process.processIdentifier)",
                appName: candidate.process.name,
                processIdentifier: candidate.process.processIdentifier
            ),
            parentAppName: parentAppName,
            relation: candidate.relation,
            eligibility: candidate.eligibility,
            probeResult: probeResultsByPID[processIdentifier]
        )
        onAdvancedTargetChanged?(nil)
        return true
    }

    private func sendWillChange() {
        onWillChange?()
    }
}
