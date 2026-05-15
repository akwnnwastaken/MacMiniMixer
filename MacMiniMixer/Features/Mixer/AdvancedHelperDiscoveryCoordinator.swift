import Foundation

@MainActor
final class AdvancedHelperDiscoveryCoordinator {
    private let processLister: ProcessListing
    private let helperProcessAudioProbe: ProcessTapCandidateAudioProbing
    private let processTapEligibility: @Sendable (Int32) -> ProcessTapProcessEligibility
    private var onWillChange: (@MainActor () -> Void)?

    private(set) var selectedAppID: MixerAppItem.ID?
    private(set) var candidates: [HelperProcessCandidate] = []
    private(set) var message: String?
    private(set) var isScanning = false
    private(set) var probeResultsByPID: [Int32: ProcessTapTestResult] = [:]
    private(set) var probeProgressByPID: [Int32: ProcessTapDiagnosticProgress] = [:]
    private(set) var runningProbePID: Int32?

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
    }

    func setOnWillChange(_ onWillChange: (@MainActor () -> Void)?) {
        self.onWillChange = onWillChange
    }

    func selectApp(
        _ appID: MixerAppItem.ID,
        apps: [MixerAppItem],
        isAutoDetectRunning: Bool,
        isAppAudioTargetResolving: Bool
    ) {
        guard !isScanning,
              runningProbePID == nil,
              !isAutoDetectRunning,
              !isAppAudioTargetResolving,
              apps.contains(where: { $0.id == appID }) else {
            return
        }

        sendWillChange()
        selectedAppID = appID
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
              !isAutoDetectRunning,
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
              !isAutoDetectRunning,
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

    func refreshSelectionAfterAppRefresh(apps: [MixerAppItem]) {
        let appIDs = Set(apps.map(\.id))

        guard selectedAppID.map({ appIDs.contains($0) }) != true else {
            return
        }

        sendWillChange()
        selectedAppID = Self.preferredHelperDiscoveryAppID(in: apps)
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

    private func sendWillChange() {
        onWillChange?()
    }
}
