import AppKit
import Foundation

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

private struct HelperProcessAutoDetectScore: Comparable {
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

@MainActor
final class MixerViewModel: ObservableObject {
    @Published private(set) var systemVolume: Double
    @Published private(set) var apps: [MixerAppItem]
    @Published private(set) var outputDevices: [OutputDeviceItem]
    @Published private(set) var selectedOutputDeviceID: OutputDeviceItem.ID
    @Published private(set) var isSystemOutputMuted: Bool
    @Published private(set) var statusMessage: MixerStatusMessage?
    @Published private(set) var selectedProcessTapAppID: MixerAppItem.ID?
    @Published private(set) var processTapTestResult: ProcessTapTestResult?
    @Published private(set) var processTapDiagnosticProgress: ProcessTapDiagnosticProgress?
    @Published private(set) var selectedProcessTapReplayGain: ProcessTapReplayGainOption
    @Published private(set) var processTapLiveDiagnostics: ProcessTapLiveDiagnostics?
    @Published private(set) var isProcessTapLiveControlActive = false
    @Published private(set) var isProcessTapTesting = false
    @Published private(set) var selectedTwoAppReadinessAppAID: MixerAppItem.ID?
    @Published private(set) var selectedTwoAppReadinessAppBID: MixerAppItem.ID?
    @Published private(set) var selectedTwoAppReadinessGain: ProcessTapReplayGainOption
    @Published private(set) var twoAppReadinessEligibilityByAppID: [MixerAppItem.ID: ProcessTapProcessEligibility]
    @Published private(set) var twoAppReadinessSnapshot = ProcessTapTwoAppReadinessSnapshot.empty
    @Published private(set) var twoAppReadinessResult: ProcessTapTwoAppReadinessResult?
    @Published private(set) var isTwoAppReadinessRunning = false
    @Published private(set) var selectedHelperDiscoveryAppID: MixerAppItem.ID?
    @Published private(set) var helperProcessCandidates: [HelperProcessCandidate] = []
    @Published private(set) var helperProcessDiscoveryMessage: String?
    @Published private(set) var isHelperProcessDiscoveryScanning = false
    @Published private(set) var helperProcessProbeResultsByPID: [Int32: ProcessTapTestResult] = [:]
    @Published private(set) var helperProcessProbeProgressByPID: [Int32: ProcessTapDiagnosticProgress] = [:]
    @Published private(set) var helperProcessProbeRunningPID: Int32?
    @Published private(set) var isHelperProcessAutoDetectRunning = false
    @Published private(set) var helperProcessAutoDetectProgressText: String?
    @Published private(set) var advancedProcessTapTarget: AdvancedProcessTapTarget?
    @Published private(set) var appAudioResolutionStateByAppID: [MixerAppItem.ID: AppAudioResolutionState] = [:]
    @Published private(set) var activeExperimentalAppID: MixerAppItem.ID?
    @Published private(set) var activeLiveControlAppName: String?
    @Published private(set) var showAllApps = false
    @Published private(set) var isExperimentalRealAppControlEnabled = false

    private let applicationLister: ApplicationListing
    private let audioController: AudioControlling
    private let outputDeviceLister: OutputDeviceListing
    private let outputDeviceController: OutputDeviceControlling
    private let systemVolumeReader: SystemVolumeReading
    private let systemVolumeController: SystemVolumeControlling
    private let processTapTester: ProcessTapTesting
    private let processTapReplayProbe: ProcessTapReplayProbing
    private let processTapLiveController: ProcessTapLiveControlling
    private let twoAppReadinessTester: ProcessTapTwoAppReadinessTesting
    private let helperProcessAudioProbe: ProcessTapCandidateAudioProbing
    private let appAudioTargetResolver: AppAudioTargetResolving
    private let processLister: ProcessListing
    private var lastNonZeroSystemVolume: Double
    private var lastSliderVolumeSetSucceeded: Bool?
    private var isProcessTapReplayProbeRunning = false
    private var helperProcessAutoDetectTask: Task<Void, Never>?
    private var appAudioResolutionTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    init(
        applicationLister: ApplicationListing,
        audioController: AudioControlling,
        outputDeviceLister: OutputDeviceListing,
        outputDeviceController: OutputDeviceControlling,
        systemVolumeReader: SystemVolumeReading,
        systemVolumeController: SystemVolumeControlling,
        processTapTester: ProcessTapTesting,
        processTapReplayProbe: ProcessTapReplayProbing,
        processTapLiveController: ProcessTapLiveControlling,
        twoAppReadinessTester: ProcessTapTwoAppReadinessTesting,
        helperProcessAudioProbe: ProcessTapCandidateAudioProbing,
        appAudioTargetResolver: AppAudioTargetResolving,
        processLister: ProcessListing
    ) {
        self.applicationLister = applicationLister
        self.audioController = audioController
        self.outputDeviceLister = outputDeviceLister
        self.outputDeviceController = outputDeviceController
        self.systemVolumeReader = systemVolumeReader
        self.systemVolumeController = systemVolumeController
        self.processTapTester = processTapTester
        self.processTapReplayProbe = processTapReplayProbe
        self.processTapLiveController = processTapLiveController
        self.twoAppReadinessTester = twoAppReadinessTester
        self.helperProcessAudioProbe = helperProcessAudioProbe
        self.appAudioTargetResolver = appAudioTargetResolver
        self.processLister = processLister

        let initialSystemVolume = audioController.systemVolume.clamped(to: AppConstants.volumeRange)
        let initialApps = applicationLister.listApplications()
        let initialTwoAppReadinessEligibility = Self.twoAppReadinessEligibility(for: initialApps)
        self.systemVolume = initialSystemVolume
        self.isSystemOutputMuted = initialSystemVolume <= AppConstants.volumeRange.lowerBound
        self.lastNonZeroSystemVolume = initialSystemVolume > AppConstants.volumeRange.lowerBound
            ? initialSystemVolume
            : AppConstants.defaultSystemOutputRestoreVolume
        self.apps = initialApps
        self.selectedProcessTapAppID = Self.preferredProcessTapAppID(in: initialApps)
        self.selectedHelperDiscoveryAppID = Self.preferredHelperDiscoveryAppID(in: initialApps)
        self.selectedProcessTapReplayGain = .defaultOption
        self.twoAppReadinessEligibilityByAppID = initialTwoAppReadinessEligibility
        self.selectedTwoAppReadinessAppAID = Self.preferredTwoAppReadinessAppIDs(
            in: initialApps,
            eligibilityByAppID: initialTwoAppReadinessEligibility
        ).appAID
        self.selectedTwoAppReadinessAppBID = Self.preferredTwoAppReadinessAppIDs(
            in: initialApps,
            eligibilityByAppID: initialTwoAppReadinessEligibility
        ).appBID
        self.selectedTwoAppReadinessGain = .defaultOption

        let listedOutputDevices = outputDeviceLister.listOutputDevices()
        self.outputDevices = listedOutputDevices
        self.selectedOutputDeviceID = Self.preferredOutputDeviceID(in: listedOutputDevices)

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopProcessTapLiveControlForTermination()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }

        _ = processTapLiveController.stopLiveControlNow(reason: .appTerminating)
        _ = twoAppReadinessTester.stopAllNow(reason: .appTerminating)
        helperProcessAutoDetectTask?.cancel()
        appAudioResolutionTask?.cancel()
        appAudioTargetResolver.cancelCurrentResolution(reason: .userStopped)
        appAudioTargetResolver.invalidateAllCachedTargets()
        helperProcessAudioProbe.stopCurrentProbe(reason: .userStopped)
        processTapReplayProbe.stopCurrentReplayProbe(reason: .userStopped)
    }

    var selectedOutputDeviceName: String {
        outputDevices.first { $0.id == selectedOutputDeviceID }?.name ?? "Output"
    }

    var visibleMixerApps: [MixerAppItem] {
        if showAllApps {
            return apps
        }

        return apps.filter { app in
            app.isLikelyAudioRelevant ||
                isActiveLiveControlTarget(app.id) ||
                isResolvingExperimentalControl(for: app.id)
        }
    }

    var twoAppReadinessTargets: [TwoAppReadinessTargetOption] {
        let appTargets = apps.compactMap { app -> TwoAppReadinessTargetOption? in
            guard twoAppReadinessEligibilityByAppID[app.id]?.isEligible == true else {
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
                eligibility: twoAppReadinessEligibilityByAppID[app.id] ?? .unavailable("Core Audio process unavailable"),
                isHelper: false
            )
        }

        guard let advancedProcessTapTarget else {
            return appTargets
        }

        let helperEligibility = ProcessTapCoreAudio.processTapEligibility(
            for: advancedProcessTapTarget.target.processIdentifier
        )
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

    func setShowAllApps(_ showAllApps: Bool) {
        self.showAllApps = showAllApps
    }

    func setExperimentalRealAppControlEnabled(_ isEnabled: Bool) {
        isExperimentalRealAppControlEnabled = isEnabled

        if !isEnabled, isProcessTapLiveControlActive {
            stopProcessTapLiveControl()
        }

        if !isEnabled {
            cancelAppAudioTargetResolution(reason: .userStopped)
            appAudioTargetResolver.invalidateAllCachedTargets()
        }
    }

    private func isActiveLiveControlTarget(_ appID: MixerAppItem.ID) -> Bool {
        appID == activeExperimentalAppID ||
            (isProcessTapLiveControlActive && appID == selectedProcessTapAppID)
    }

    func setSystemVolume(_ volume: Double) {
        lastSliderVolumeSetSucceeded = applyRequestedSystemVolume(volume)
    }

    func finishSystemVolumeEditing() {
        defer {
            lastSliderVolumeSetSucceeded = nil
            refreshSystemOutputVolume()
        }

        guard let didUpdateVolume = lastSliderVolumeSetSucceeded else {
            return
        }

        if !didUpdateVolume {
            showStatus("This device does not expose writable volume", style: .warning)
        }
    }

    func toggleSystemOutputMuted() {
        let willRestoreOutput = isSystemOutputMuted || systemVolume <= AppConstants.volumeRange.lowerBound
        let targetVolume: Double

        if willRestoreOutput {
            targetVolume = restoredSystemOutputVolume
        } else {
            rememberNonZeroSystemVolume(systemVolume)
            targetVolume = AppConstants.volumeRange.lowerBound
        }

        if !applyRequestedSystemVolume(targetVolume) {
            showStatus(
                willRestoreOutput ? "Could not restore system output" : "Could not mute system output",
                style: .warning
            )
            refreshSystemOutputVolume()
        }
    }

    func selectOutputDevice(_ deviceID: OutputDeviceItem.ID) {
        guard let device = outputDevices.first(where: { $0.id == deviceID }) else {
            return
        }

        let previousDeviceID = selectedOutputDeviceID
        selectedOutputDeviceID = deviceID

        guard outputDeviceController.setDefaultOutputDevice(device) else {
            selectedOutputDeviceID = previousDeviceID
            showStatus("Could not switch output device", style: .warning)
            return
        }

        refreshOutputDevices()
        refreshSystemOutputVolume()
    }

    func refreshOutputDevices() {
        let previousDeviceID = selectedOutputDeviceID
        let previousDefaultDeviceID = outputDevices.first { $0.isSystemDefault }?.id
        let refreshedDevices = outputDeviceLister.listOutputDevices()

        outputDevices = refreshedDevices
        let didSelectionChange = syncSelectedOutputDeviceWithDefault(fallbackDeviceID: previousDeviceID)
        let refreshedDefaultDeviceID = refreshedDevices.first { $0.isSystemDefault }?.id

        if isProcessTapLiveControlActive,
           didSelectionChange || refreshedDefaultDeviceID != previousDefaultDeviceID {
            AppLogger.audio.warning("Output device change stopping live control previousDefault=\(previousDefaultDeviceID ?? "none", privacy: .public) currentDefault=\(refreshedDefaultDeviceID ?? "none", privacy: .public)")
            stopProcessTapLiveControl(reason: .outputDeviceChanged)
        }

        if isTwoAppReadinessRunning,
           didSelectionChange || refreshedDefaultDeviceID != previousDefaultDeviceID {
            AppLogger.audio.warning("Output device change stopping two-app readiness previousDefault=\(previousDefaultDeviceID ?? "none", privacy: .public) currentDefault=\(refreshedDefaultDeviceID ?? "none", privacy: .public)")
            stopTwoAppReadiness(reason: .outputDeviceChanged)
        }

        if (helperProcessProbeRunningPID != nil || isHelperProcessAutoDetectRunning),
           didSelectionChange || refreshedDefaultDeviceID != previousDefaultDeviceID {
            AppLogger.audio.warning("Output device change stopping helper probe previousDefault=\(previousDefaultDeviceID ?? "none", privacy: .public) currentDefault=\(refreshedDefaultDeviceID ?? "none", privacy: .public)")
            stopHelperProcessProbe(reason: .outputDeviceChanged)
        }

        if isAppAudioTargetResolving,
           didSelectionChange || refreshedDefaultDeviceID != previousDefaultDeviceID {
            AppLogger.audio.warning("Output device change cancelling app audio resolution previousDefault=\(previousDefaultDeviceID ?? "none", privacy: .public) currentDefault=\(refreshedDefaultDeviceID ?? "none", privacy: .public)")
            cancelAppAudioTargetResolution(reason: .outputDeviceChanged)
        }

        if isProcessTapReplayProbeRunning,
           didSelectionChange || refreshedDefaultDeviceID != previousDefaultDeviceID {
            AppLogger.audio.warning("Output device change stopping replay probe previousDefault=\(previousDefaultDeviceID ?? "none", privacy: .public) currentDefault=\(refreshedDefaultDeviceID ?? "none", privacy: .public)")
            processTapReplayProbe.stopCurrentReplayProbe(reason: .outputDeviceChanged)
        }

        if didSelectionChange || refreshedDefaultDeviceID != previousDefaultDeviceID {
            appAudioTargetResolver.invalidateAllCachedTargets()
            refreshSystemOutputVolume()
        }
    }

    func refreshSystemOutputVolume() {
        guard let volumeScalar = systemVolumeReader.readCurrentOutputVolumeScalar() else {
            return
        }

        let refreshedVolume = (volumeScalar * AppConstants.volumeRange.upperBound)
            .clamped(to: AppConstants.volumeRange)

        applySystemVolume(refreshedVolume)
    }

    func selectProcessTapApp(_ appID: MixerAppItem.ID) {
        guard !isProcessTapLiveControlActive,
              !isAppAudioTargetResolving else {
            return
        }

        guard apps.contains(where: { $0.id == appID }) else {
            return
        }

        selectedProcessTapAppID = appID
        advancedProcessTapTarget = nil
        processTapTestResult = nil
        processTapDiagnosticProgress = nil
    }

    func selectTwoAppReadinessAppA(_ appID: MixerAppItem.ID) {
        guard !isTwoAppReadinessRunning,
              twoAppReadinessTargets.contains(where: { $0.id == appID }) else {
            return
        }

        selectedTwoAppReadinessAppAID = appID
        twoAppReadinessResult = nil
    }

    func selectTwoAppReadinessAppB(_ appID: MixerAppItem.ID) {
        guard !isTwoAppReadinessRunning,
              twoAppReadinessTargets.contains(where: { $0.id == appID }) else {
            return
        }

        selectedTwoAppReadinessAppBID = appID
        twoAppReadinessResult = nil
    }

    func selectTwoAppReadinessGain(_ gain: ProcessTapReplayGainOption) {
        guard !isTwoAppReadinessRunning else {
            return
        }

        selectedTwoAppReadinessGain = gain
        twoAppReadinessResult = nil
    }

    func selectHelperDiscoveryApp(_ appID: MixerAppItem.ID) {
        guard !isHelperProcessDiscoveryScanning,
              helperProcessProbeRunningPID == nil,
              !isHelperProcessAutoDetectRunning,
              !isAppAudioTargetResolving,
              apps.contains(where: { $0.id == appID }) else {
            return
        }

        selectedHelperDiscoveryAppID = appID
        helperProcessCandidates = []
        helperProcessDiscoveryMessage = nil
        helperProcessProbeResultsByPID = [:]
        helperProcessProbeProgressByPID = [:]
    }

    func scanHelperProcesses() {
        guard !isHelperProcessDiscoveryScanning,
              helperProcessProbeRunningPID == nil,
              !isHelperProcessAutoDetectRunning,
              !isAppAudioTargetResolving else {
            return
        }

        guard let app = selectedHelperDiscoveryApp else {
            helperProcessDiscoveryMessage = "Select a visible app"
            helperProcessCandidates = []
            return
        }

        isHelperProcessDiscoveryScanning = true
        helperProcessDiscoveryMessage = nil
        helperProcessCandidates = []
        helperProcessProbeResultsByPID = [:]
        helperProcessProbeProgressByPID = [:]

        let processLister = processLister
        Task {
            let processes = await Task.detached(priority: .userInitiated) {
                processLister.listProcesses()
            }.value
            let candidates = HelperProcessCandidateDiscovery.candidates(
                for: app.helperProcessDiscoveryTarget,
                processes: processes
            )
            let eligibleCount = candidates.filter(\.isTapEligible).count

            await MainActor.run {
                guard self.selectedHelperDiscoveryAppID == app.id else {
                    self.isHelperProcessDiscoveryScanning = false
                    return
                }

                self.helperProcessCandidates = candidates
                self.isHelperProcessDiscoveryScanning = false

                if candidates.isEmpty {
                    self.helperProcessDiscoveryMessage = "No related helper candidates found"
                } else if eligibleCount == 0 {
                    self.helperProcessDiscoveryMessage = "No tap-eligible helper processes found"
                } else {
                    self.helperProcessDiscoveryMessage = "\(eligibleCount) tap-eligible candidate\(eligibleCount == 1 ? "" : "s")"
                }
            }
        }
    }

    func useHelperCandidateAsAdvancedTarget(_ processIdentifier: Int32) {
        guard !isHelperProcessAutoDetectRunning,
              !isAppAudioTargetResolving else {
            return
        }

        guard let candidate = helperProcessCandidates.first(where: { $0.id == processIdentifier }),
              candidate.isTapEligible else {
            processTapTestResult = ProcessTapTestResult(
                outcome: .processNotFound,
                message: "Core Audio process unavailable",
                severity: .warning
            )
            return
        }

        let parentAppName = selectedHelperDiscoveryApp?.name ?? "Selected app"
        advancedProcessTapTarget = AdvancedProcessTapTarget(
            target: ProcessTapTarget(
                appID: "helper:\(parentAppName):\(candidate.process.processIdentifier)",
                appName: candidate.process.name,
                processIdentifier: candidate.process.processIdentifier
            ),
            parentAppName: parentAppName,
            relation: candidate.relation,
            eligibility: candidate.eligibility,
            probeResult: helperProcessProbeResultsByPID[processIdentifier]
        )
        processTapTestResult = nil
        processTapDiagnosticProgress = nil
        refreshTwoAppReadinessSelectionsAfterTargetChange()
    }

    func clearAdvancedProcessTapTarget() {
        let removedTargetID = advancedProcessTapTarget?.id

        if isHelperProcessAutoDetectRunning {
            stopHelperProcessAutoDetect(reason: .userStopped)
        }

        if isTwoAppReadinessRunning {
            stopTwoAppReadiness(reason: .userStopped)
        }

        advancedProcessTapTarget = nil
        processTapTestResult = nil
        processTapDiagnosticProgress = nil
        refreshTwoAppReadinessSelectionsAfterTargetChange(removedTargetID: removedTargetID)
    }

    func probeHelperProcessCandidate(_ processIdentifier: Int32) {
        guard helperProcessProbeRunningPID == nil,
              !isHelperProcessAutoDetectRunning,
              !isAppAudioTargetResolving else {
            return
        }

        guard let candidate = helperProcessCandidates.first(where: { $0.id == processIdentifier }),
              candidate.isTapEligible else {
            helperProcessProbeResultsByPID[processIdentifier] = ProcessTapTestResult(
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

        helperProcessProbeRunningPID = processIdentifier
        helperProcessProbeProgressByPID[processIdentifier] = initialProgress
        helperProcessProbeResultsByPID[processIdentifier] = ProcessTapTestResult(
            outcome: .helperProbeRunning,
            message: "Probing...",
            detail: "Listening briefly. No audio will be replayed, saved, or modified.",
            severity: .info
        )

        Task {
            let result = await helperProcessAudioProbe.probeAudio(
                for: target,
                duration: AppConstants.processTapDiagnosticDuration
            ) { progress in
                Task { @MainActor in
                    guard self.helperProcessProbeRunningPID == processIdentifier else {
                        return
                    }

                    self.helperProcessProbeProgressByPID[processIdentifier] = progress
                }
            }

            await MainActor.run {
                self.helperProcessProbeResultsByPID[processIdentifier] = result
                self.helperProcessProbeRunningPID = nil
            }
        }
    }

    func autoDetectHelperProcessCandidate() {
        guard !isHelperProcessAutoDetectRunning,
              helperProcessProbeRunningPID == nil,
              !isHelperProcessDiscoveryScanning,
              !isAppAudioTargetResolving else {
            return
        }

        let eligibleCandidates = helperProcessCandidates.filter(\.isTapEligible)
        guard !eligibleCandidates.isEmpty else {
            helperProcessDiscoveryMessage = "No tap-eligible helper processes found"
            return
        }

        guard selectedHelperDiscoveryApp != nil else {
            helperProcessDiscoveryMessage = "Select a visible app"
            return
        }

        isHelperProcessAutoDetectRunning = true
        helperProcessAutoDetectProgressText = "Testing 1/\(eligibleCandidates.count)"
        helperProcessDiscoveryMessage = "Testing 1/\(eligibleCandidates.count)"
        AppLogger.helperResolution.info("Advanced helper auto-detect started candidates=\(eligibleCandidates.count, privacy: .public)")

        helperProcessAutoDetectTask?.cancel()
        helperProcessAutoDetectTask = Task { [weak self] in
            await self?.runHelperProcessAutoDetect(candidates: eligibleCandidates)
        }
    }

    func testSelectedProcessTapApp() {
        startProcessTapTest(mode: .diagnostics)
    }

    func testSelectedProcessTapMuteProbe() {
        startProcessTapTest(mode: .muteBehaviorProbe)
    }

    func selectProcessTapReplayGain(_ gain: ProcessTapReplayGainOption) {
        guard !isProcessTapTesting, !isProcessTapLiveControlActive, !isTwoAppReadinessRunning else {
            return
        }

        selectedProcessTapReplayGain = gain
        processTapTestResult = nil
        processTapDiagnosticProgress = nil
    }

    func testSelectedProcessTapReplayProbe() {
        guard !isProcessTapTesting,
              !isProcessTapLiveControlActive,
              !isTwoAppReadinessRunning,
              !isAppAudioTargetResolving else {
            return
        }

        guard let target = replayProbeTarget else {
            processTapTestResult = ProcessTapTestResult(
                outcome: .invalidTarget,
                message: "Select a running app or Advanced target",
                severity: .warning
            )
            return
        }

        if advancedProcessTapTarget != nil {
            let eligibility = ProcessTapCoreAudio.processTapEligibility(for: target.processIdentifier)
            guard eligibility.isEligible else {
                processTapTestResult = ProcessTapTestResult(
                    outcome: .processNotFound,
                    message: "Advanced target unavailable",
                    detail: eligibility.reason ?? "Core Audio process unavailable",
                    severity: .warning
                )
                return
            }
        }

        processTapTestResult = ProcessTapTestResult(
            outcome: .replayProbeRunning,
            message: "Replay testing \(target.appName)...",
            detail: replayProbeRunningDetail,
            severity: .info
        )
        processTapDiagnosticProgress = ProcessTapDiagnosticProgress(
            callbackCount: 0,
            peakLevel: 0,
            rmsLevel: 0,
            audioDetected: false
        )
        isProcessTapTesting = true
        isProcessTapReplayProbeRunning = true

        let replayGain = selectedProcessTapReplayGain
        Task {
            let result = await processTapReplayProbe.runReplayProbe(for: target, gain: replayGain) { progress in
                Task { @MainActor in
                    self.processTapDiagnosticProgress = progress
                }
            }

            await MainActor.run {
                processTapTestResult = result.testResult
                processTapDiagnosticProgress = nil
                isProcessTapTesting = false
                isProcessTapReplayProbeRunning = false
            }
        }
    }

    func startProcessTapLiveControl() {
        guard !isProcessTapTesting,
              !isProcessTapLiveControlActive,
              !isTwoAppReadinessRunning,
              !isAppAudioTargetResolving else {
            return
        }

        guard let app = selectedProcessTapApp else {
            processTapTestResult = ProcessTapTestResult(
                outcome: .invalidTarget,
                message: "Select a running app",
                severity: .warning
            )
            return
        }

        let target = ProcessTapTarget(
            appID: app.id,
            appName: app.name,
            processIdentifier: app.processIdentifier
        )
        let gain = selectedProcessTapReplayGain

        processTapTestResult = ProcessTapTestResult(
            outcome: .liveControlStarting,
            message: "Starting live control for \(app.name)...",
            detail: "Experimental: original output is suppressed and replayed with gain \(gain.percentLabel).",
            severity: .info
        )
        processTapDiagnosticProgress = ProcessTapDiagnosticProgress(
            callbackCount: 0,
            peakLevel: 0,
            rmsLevel: 0,
            audioDetected: false
        )
        processTapLiveDiagnostics = nil
        isProcessTapTesting = true

        Task {
            let result = await processTapLiveController.startLiveControl(
                for: target,
                gain: gain
            ) { diagnostics in
                Task { @MainActor in
                    self.processTapLiveDiagnostics = diagnostics
                    self.processTapDiagnosticProgress = diagnostics.progress
                }
            } onStopped: { result, diagnostics in
                Task { @MainActor in
                    self.handleLiveControlStopped(result, diagnostics: diagnostics)
                }
            }

            await MainActor.run {
                processTapTestResult = result
                isProcessTapTesting = false

                if result.outcome == .liveControlStarted {
                    isProcessTapLiveControlActive = true
                    activeLiveControlAppName = app.name
                } else {
                    processTapLiveDiagnostics = nil
                    processTapDiagnosticProgress = nil
                    activeLiveControlAppName = nil
                    showLiveControlWarningIfNeeded(for: result)
                }
            }
        }
    }

    func stopProcessTapLiveControl() {
        stopProcessTapLiveControl(reason: .userStopped)
    }

    private func stopProcessTapLiveControl(reason: ProcessTapLiveStopReason) {
        guard isProcessTapLiveControlActive || isProcessTapTesting else {
            return
        }

        Task {
            let result = await processTapLiveController.stopLiveControl(reason: reason)

            await MainActor.run {
                if result.outcome == .liveControlNotActive {
                    handleLiveControlStopped(result, diagnostics: processTapLiveDiagnostics)
                }
            }
        }
    }

    func stopProcessTapLiveControlForTermination() {
        _ = processTapLiveController.stopLiveControlNow(reason: .appTerminating)
        _ = twoAppReadinessTester.stopAllNow(reason: .appTerminating)
        helperProcessAutoDetectTask?.cancel()
        appAudioResolutionTask?.cancel()
        appAudioTargetResolver.cancelCurrentResolution(reason: .userStopped)
        appAudioTargetResolver.invalidateAllCachedTargets()
        helperProcessAudioProbe.stopCurrentProbe(reason: .userStopped)
        processTapReplayProbe.stopCurrentReplayProbe(reason: .userStopped)
        isProcessTapLiveControlActive = false
        isProcessTapTesting = false
        isProcessTapReplayProbeRunning = false
        helperProcessProbeRunningPID = nil
        isHelperProcessAutoDetectRunning = false
        helperProcessAutoDetectProgressText = nil
        appAudioResolutionStateByAppID = [:]
        activeExperimentalAppID = nil
        activeLiveControlAppName = nil
        isTwoAppReadinessRunning = false
    }

    func startTwoAppReadinessTest() {
        guard !isTwoAppReadinessRunning else {
            return
        }

        guard !isProcessTapTesting,
              !isProcessTapLiveControlActive,
              !isAppAudioTargetResolving else {
            twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
                outcome: .setupFailed,
                message: "Stop active Process Tap work first",
                severity: .warning
            )
            return
        }

        guard let appA = selectedTwoAppReadinessTargetA,
              let appB = selectedTwoAppReadinessTargetB else {
            twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
                outcome: .invalidTarget,
                message: "Select two targets",
                severity: .warning
            )
            return
        }

        guard appA.id != appB.id else {
            twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
                outcome: .invalidTarget,
                message: "Choose two different apps",
                severity: .warning
            )
            return
        }

        guard validProcessIdentifier(appA.processIdentifier),
              validProcessIdentifier(appB.processIdentifier) else {
            twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
                outcome: .invalidTarget,
                message: "Both apps need valid processes",
                severity: .warning
            )
            return
        }

        guard appA.processIdentifier != appB.processIdentifier else {
            twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
                outcome: .invalidTarget,
                message: "Choose two different process targets",
                severity: .warning
            )
            return
        }

        let appAEligibility = ProcessTapCoreAudio.processTapEligibility(for: appA.processIdentifier)
        let appBEligibility = ProcessTapCoreAudio.processTapEligibility(for: appB.processIdentifier)
        guard appAEligibility.isEligible,
              appBEligibility.isEligible else {
            let reason = [appAEligibility.reason, appBEligibility.reason]
                .compactMap { $0 }
                .first
            twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
                outcome: .setupFailed,
                message: reason == ProcessTapCoreAudio.unsupportedOSMessage
                    ? "Process Tap is not available"
                    : "Core Audio process unavailable",
                detail: reason,
                severity: .warning
            )
            return
        }

        let targetA = appA.target
        let targetB = appB.target
        let gain = selectedTwoAppReadinessGain

        isTwoAppReadinessRunning = true
        twoAppReadinessResult = ProcessTapTwoAppReadinessResult(
            outcome: .starting,
            message: "Starting two-app test...",
            detail: "Gain \(gain.percentLabel).",
            severity: .info
        )
        twoAppReadinessSnapshot = ProcessTapTwoAppReadinessSnapshot(
            sessions: [
                .starting(slot: .appA, target: targetA, gain: gain),
                .starting(slot: .appB, target: targetB, gain: gain)
            ]
        )

        Task {
            let result = await twoAppReadinessTester.startTest(
                appA: targetA,
                appB: targetB,
                gain: gain
            ) { snapshot in
                Task { @MainActor in
                    self.twoAppReadinessSnapshot = snapshot
                }
            } onFinished: { result, snapshot in
                Task { @MainActor in
                    self.handleTwoAppReadinessFinished(result, snapshot: snapshot)
                }
            }

            await MainActor.run {
                twoAppReadinessResult = result
                if result.outcome != .running {
                    isTwoAppReadinessRunning = false
                }
            }
        }
    }

    func stopTwoAppReadinessTest() {
        stopTwoAppReadiness(reason: .userStopped)
    }

    func stopTwoAppReadinessForPanelClose() {
        guard isTwoAppReadinessRunning else {
            stopHelperProcessAutoDetect(reason: .userStopped)
            cancelAppAudioTargetResolution(reason: .userStopped)
            return
        }

        stopTwoAppReadiness(reason: .userStopped)
        stopHelperProcessAutoDetect(reason: .userStopped)
        cancelAppAudioTargetResolution(reason: .userStopped)
    }

    func isExperimentalControlActive(for appID: MixerAppItem.ID) -> Bool {
        activeExperimentalAppID == appID && isProcessTapLiveControlActive
    }

    func isResolvingExperimentalControl(for appID: MixerAppItem.ID) -> Bool {
        appAudioResolutionStateByAppID[appID] != nil
    }

    func toggleExperimentalControl(for appID: MixerAppItem.ID) {
        if isExperimentalControlActive(for: appID) {
            stopProcessTapLiveControl()
            return
        }

        startExperimentalControl(for: appID)
    }

    private func startProcessTapTest(mode: ProcessTapTestMode) {
        guard !isProcessTapTesting,
              !isProcessTapLiveControlActive,
              !isTwoAppReadinessRunning,
              !isAppAudioTargetResolving else {
            return
        }

        guard let target = processTapTarget(for: mode) else {
            processTapTestResult = ProcessTapTestResult(
                outcome: .invalidTarget,
                message: "Select a running app or Advanced target",
                severity: .warning
            )
            return
        }

        if mode == .diagnostics, advancedProcessTapTarget != nil {
            let eligibility = ProcessTapCoreAudio.processTapEligibility(for: target.processIdentifier)
            guard eligibility.isEligible else {
                processTapTestResult = ProcessTapTestResult(
                    outcome: .processNotFound,
                    message: "Advanced target unavailable",
                    detail: eligibility.reason ?? "Core Audio process unavailable",
                    severity: .warning
                )
                return
            }
        }

        processTapTestResult = ProcessTapTestResult(
            outcome: .streamDiagnosticsRunning,
            message: mode.runningMessage(for: target.appName),
            detail: mode.runningDetail,
            severity: .info
        )
        processTapDiagnosticProgress = ProcessTapDiagnosticProgress(
            callbackCount: 0,
            peakLevel: 0,
            rmsLevel: 0,
            audioDetected: false
        )
        isProcessTapTesting = true

        Task {
            let result = await processTapTester.testProcessTap(for: target, mode: mode) { progress in
                Task { @MainActor in
                    self.processTapDiagnosticProgress = progress
                }
            }

            await MainActor.run {
                processTapTestResult = result
                processTapDiagnosticProgress = nil
                isProcessTapTesting = false
            }
        }
    }

    func refreshApplications() {
        let previousProcessTapAppID = selectedProcessTapAppID
        let previousApps = apps
        let existingStates = Dictionary(
            uniqueKeysWithValues: apps.map { app in
                (app.id, (volume: app.volume, isMuted: app.isMuted))
            }
        )

        apps = applicationLister.listApplications().map { app in
            guard let existingState = existingStates[app.id] else {
                return app
            }

            var updatedApp = app
            updatedApp.volume = existingState.volume
            updatedApp.isMuted = existingState.isMuted
            return updatedApp
        }
        refreshTwoAppReadinessEligibility()
        invalidateCachedAudioTargetsForRemovedOrChangedApps(previousApps: previousApps, refreshedApps: apps)

        if let activeExperimentalAppID,
           !apps.contains(where: { $0.id == activeExperimentalAppID }) {
            stopProcessTapLiveControl(reason: .targetAppExited)
        }

        if let resolvingAppID = appAudioResolutionStateByAppID.keys.first,
           !apps.contains(where: { $0.id == resolvingAppID }) {
            cancelAppAudioTargetResolution(reason: .targetExited)
        }

        if let previousProcessTapAppID,
           apps.contains(where: { $0.id == previousProcessTapAppID }) {
            selectedProcessTapAppID = previousProcessTapAppID
        } else {
            if isProcessTapLiveControlActive {
                stopProcessTapLiveControl(reason: .targetAppExited)
            }

            selectedProcessTapAppID = Self.preferredProcessTapAppID(in: apps)
            processTapTestResult = nil
            processTapDiagnosticProgress = nil
            processTapLiveDiagnostics = nil
        }

        refreshTwoAppReadinessSelectionsAfterAppRefresh()
        refreshHelperDiscoverySelectionAfterAppRefresh()
    }

    func volume(for appID: MixerAppItem.ID) -> Double {
        apps.first { $0.id == appID }?.volume ?? 0
    }

    func isMuted(for appID: MixerAppItem.ID) -> Bool {
        apps.first { $0.id == appID }?.isMuted ?? false
    }

    func setAppVolume(_ volume: Double, for appID: MixerAppItem.ID) {
        guard let index = apps.firstIndex(where: { $0.id == appID }) else {
            return
        }

        let clampedVolume = volume.clamped(to: AppConstants.volumeRange)
        apps[index].volume = clampedVolume
        audioController.setVolume(clampedVolume, for: appID)

        startAutomaticRealControlIfNeeded(for: apps[index])
        updateExperimentalGainIfActive(for: apps[index])
    }

    func setMuted(_ isMuted: Bool, for appID: MixerAppItem.ID) {
        guard let index = apps.firstIndex(where: { $0.id == appID }) else {
            return
        }

        apps[index].isMuted = isMuted
        audioController.setMuted(isMuted, for: appID)
        startAutomaticRealControlIfNeeded(for: apps[index])
        updateExperimentalGainIfActive(for: apps[index])
    }

    private func startAutomaticRealControlIfNeeded(for app: MixerAppItem) {
        guard isExperimentalRealAppControlEnabled else {
            return
        }

        guard !isTwoAppReadinessRunning else {
            showStatus("Stop two-app test first", style: .warning)
            return
        }

        guard app.isEligibleForExperimentalLiveControl else {
            showStatus("This app is not available for real app control", style: .warning)
            return
        }

        if isResolvingExperimentalControl(for: app.id) {
            return
        }

        if isAppAudioTargetResolving {
            showStatus("Finish resolving app audio first", style: .warning)
            return
        }

        if helperProcessProbeRunningPID != nil || isHelperProcessAutoDetectRunning {
            showStatus("Stop helper probe first", style: .warning)
            return
        }

        if isExperimentalControlActive(for: app.id) {
            return
        }

        if isProcessTapLiveControlActive || isProcessTapTesting {
            showStatus("Stop active live control first", style: .warning)
            return
        }

        startResolvedExperimentalControl(for: app)
    }

    private func startExperimentalControl(for appID: MixerAppItem.ID) {
        guard !isTwoAppReadinessRunning else {
            showStatus("Stop two-app test first", style: .warning)
            return
        }

        guard !isProcessTapTesting,
              !isAppAudioTargetResolving else {
            showStatus("Process Tap is already busy", style: .warning)
            return
        }

        guard !isProcessTapLiveControlActive else {
            showStatus("Stop the active live control first", style: .warning)
            return
        }

        guard let app = apps.first(where: { $0.id == appID }) else {
            showStatus("This app is not available for live control", style: .warning)
            return
        }

        guard app.isEligibleForExperimentalLiveControl else {
            showStatus("No valid process found", style: .warning)
            return
        }

        guard let processIdentifier = app.processIdentifier,
              NSRunningApplication(processIdentifier: pid_t(processIdentifier)) != nil else {
            showStatus("This app is not available for live control", style: .warning)
            return
        }

        let target = ProcessTapTarget(
            appID: app.id,
            appName: app.name,
            processIdentifier: app.processIdentifier
        )
        startExperimentalControl(for: app, target: target)
    }

    private func startResolvedExperimentalControl(
        for app: MixerAppItem,
        allowsCachedLookup: Bool = true
    ) {
        let request = app.appAudioTargetRequest
        let visibleEligibility = ProcessTapCoreAudio.processTapEligibility(for: app.processIdentifier)

        if visibleEligibility.isEligible {
            startExperimentalControl(
                for: app,
                target: ProcessTapTarget(
                    appID: app.id,
                    appName: app.name,
                    processIdentifier: app.processIdentifier
                )
            )
            return
        }

        if visibleEligibility.reason == ProcessTapCoreAudio.unsupportedOSMessage ||
            visibleEligibility.reason == "Missing audio capture usage description" {
            showStatus(visibleEligibility.reason ?? "Process Tap is unavailable", style: .warning)
            return
        }

        guard HelperProcessCandidateDiscovery.isLikelyHelperResolvable(app.helperProcessDiscoveryTarget) else {
            showStatus("This app is not available for real app control", style: .warning)
            return
        }

        appAudioResolutionStateByAppID = [app.id: .resolving]
        appAudioResolutionTask?.cancel()
        appAudioResolutionTask = Task { [weak self] in
            let result = await self?.appAudioTargetResolver.resolveTarget(
                for: request,
                allowsCachedLookup: allowsCachedLookup
            ) { _ in }

            await MainActor.run {
                self?.handleAppAudioTargetResolution(result, for: app.id)
            }
        }
    }

    private func startExperimentalControl(
        for app: MixerAppItem,
        target: ProcessTapTarget,
        resolutionSource: ResolvedAppAudioTarget.Source? = nil
    ) {
        guard target.processIdentifier.map({ $0 > 0 }) == true else {
            showStatus("This app is not available for live control", style: .warning)
            return
        }

        let gain = experimentalGainOption(for: app)

        activeExperimentalAppID = app.id
        activeLiveControlAppName = app.name
        processTapTestResult = ProcessTapTestResult(
            outcome: .liveControlStarting,
            message: "Starting experimental live control for \(app.name)...",
            detail: "This may affect real audio for this app only. Gain \(gain.percentLabel).",
            severity: .info
        )
        processTapDiagnosticProgress = ProcessTapDiagnosticProgress(
            callbackCount: 0,
            peakLevel: 0,
            rmsLevel: 0,
            audioDetected: false
        )
        processTapLiveDiagnostics = nil
        isProcessTapTesting = true

        Task {
            let result = await processTapLiveController.startLiveControl(
                for: target,
                gain: gain
            ) { diagnostics in
                Task { @MainActor in
                    self.processTapLiveDiagnostics = diagnostics
                    self.processTapDiagnosticProgress = diagnostics.progress
                }
            } onStopped: { result, diagnostics in
                Task { @MainActor in
                    self.handleLiveControlStopped(result, diagnostics: diagnostics)
                }
            }

            await MainActor.run {
                processTapTestResult = result
                isProcessTapTesting = false

                if result.outcome == .liveControlStarted {
                    isProcessTapLiveControlActive = true
                    activeExperimentalAppID = app.id
                    activeLiveControlAppName = app.name
                } else {
                    if resolutionSource == .cachedHelper {
                        appAudioTargetResolver.invalidateCachedTarget(for: app.appAudioTargetRequest)
                    }

                    activeExperimentalAppID = nil
                    activeLiveControlAppName = nil
                    processTapLiveDiagnostics = nil
                    processTapDiagnosticProgress = nil

                    if resolutionSource == .cachedHelper,
                       isExperimentalRealAppControlEnabled,
                       !isTwoAppReadinessRunning,
                       !isProcessTapLiveControlActive,
                       !isAppAudioTargetResolving {
                        startResolvedExperimentalControl(for: app, allowsCachedLookup: false)
                    } else {
                        if resolutionSource == .discoveredHelper {
                            appAudioTargetResolver.invalidateCachedTarget(for: app.appAudioTargetRequest)
                        }
                        showStatus("Could not start live control for this app", style: .warning)
                    }
                }
            }
        }
    }

    private static func preferredOutputDeviceID(in devices: [OutputDeviceItem]) -> OutputDeviceItem.ID {
        devices.first { $0.isSystemDefault }?.id ?? devices.first?.id ?? "output:none"
    }

    private func handleLiveControlStopped(
        _ result: ProcessTapTestResult,
        diagnostics: ProcessTapLiveDiagnostics?
    ) {
        let stoppedAppID = activeExperimentalAppID
        processTapTestResult = result
        processTapLiveDiagnostics = diagnostics
        processTapDiagnosticProgress = diagnostics?.progress
        isProcessTapLiveControlActive = false
        isProcessTapTesting = false
        activeExperimentalAppID = nil
        activeLiveControlAppName = nil
        if result.outcome == .liveControlAppExited,
           let stoppedAppID,
           let stoppedApp = apps.first(where: { $0.id == stoppedAppID }) {
            appAudioTargetResolver.invalidateCachedTarget(for: stoppedApp.appAudioTargetRequest)
        }
        if result.outcome == .liveControlOutputChanged {
            appAudioTargetResolver.invalidateAllCachedTargets()
        }
        showLiveControlWarningIfNeeded(for: result)
    }

    private func handleAppAudioTargetResolution(
        _ result: AppAudioTargetResolutionResult?,
        for appID: MixerAppItem.ID
    ) {
        guard appAudioResolutionStateByAppID[appID] != nil else {
            return
        }

        appAudioResolutionStateByAppID[appID] = nil
        appAudioResolutionTask = nil

        guard let result else {
            return
        }

        switch result {
        case .resolved(let resolvedTarget):
            guard let app = apps.first(where: { $0.id == resolvedTarget.visibleAppID }) else {
                showStatus("This app is not available for real app control", style: .warning)
                return
            }

            guard !isTwoAppReadinessRunning else {
                showStatus("Stop two-app test first", style: .warning)
                return
            }

            guard !isProcessTapLiveControlActive, !isProcessTapTesting else {
                showStatus("Stop active live control first", style: .warning)
                return
            }

            startExperimentalControl(
                for: app,
                target: resolvedTarget.target,
                resolutionSource: resolvedTarget.source
            )

        case .unavailable(let reason):
            showStatus(reason, style: .warning)

        case .cancelled:
            break
        }
    }

    private func showLiveControlWarningIfNeeded(for result: ProcessTapTestResult) {
        switch result.outcome {
        case .tapCleanupFailed:
            showStatus("Live control cleanup warning", style: .warning)
        case .liveControlTimedOut:
            showStatus("Live control stopped: timeout", style: .warning)
        case .liveControlOutputChanged:
            showStatus("Live control stopped: output device changed", style: .warning)
        case .liveControlAppExited:
            showStatus("Live control stopped: app exited", style: .warning)
        case .liveControlSetupFailed:
            showStatus("Could not start live control", style: .warning)
        case .unsupportedOS:
            showStatus(ProcessTapCoreAudio.unsupportedOSMessage, style: .warning)
        default:
            break
        }
    }

    private func stopTwoAppReadiness(reason: ProcessTapLiveStopReason) {
        guard isTwoAppReadinessRunning else {
            return
        }

        Task {
            let result = await twoAppReadinessTester.stopAll(reason: reason)

            await MainActor.run {
                if result.outcome == .notRunning {
                    handleTwoAppReadinessFinished(result, snapshot: twoAppReadinessSnapshot)
                }
            }
        }
    }

    private func stopHelperProcessProbe(reason: ProcessTapCandidateProbeStopReason) {
        guard helperProcessProbeRunningPID != nil || isHelperProcessAutoDetectRunning else {
            return
        }

        if isHelperProcessAutoDetectRunning {
            stopHelperProcessAutoDetect(reason: reason)
        }

        helperProcessAudioProbe.stopCurrentProbe(reason: reason)
    }

    private func stopHelperProcessAutoDetect(reason: ProcessTapCandidateProbeStopReason) {
        guard isHelperProcessAutoDetectRunning else {
            return
        }

        helperProcessAutoDetectTask?.cancel()
        helperProcessAutoDetectTask = nil
        helperProcessAudioProbe.stopCurrentProbe(reason: reason)
    }

    private func cancelAppAudioTargetResolution(reason: ProcessTapCandidateProbeStopReason) {
        guard isAppAudioTargetResolving else {
            return
        }

        appAudioResolutionTask?.cancel()
        appAudioResolutionTask = nil
        appAudioResolutionStateByAppID = [:]
        appAudioTargetResolver.cancelCurrentResolution(reason: reason)
    }

    private func runHelperProcessAutoDetect(candidates: [HelperProcessCandidate]) async {
        var scoredResults: [HelperProcessAutoDetectScore] = []
        let parentAppID = selectedHelperDiscoveryAppID

        for (index, candidate) in candidates.enumerated() {
            guard !Task.isCancelled,
                  isHelperProcessAutoDetectRunning,
                  selectedHelperDiscoveryAppID == parentAppID else {
                finishHelperProcessAutoDetect(bestScore: nil, wasCancelled: true)
                return
            }

            let progressText = "Testing \(index + 1)/\(candidates.count)"
            helperProcessAutoDetectProgressText = progressText
            helperProcessDiscoveryMessage = progressText

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

            helperProcessProbeRunningPID = processIdentifier
            helperProcessProbeProgressByPID[processIdentifier] = initialProgress
            helperProcessProbeResultsByPID[processIdentifier] = ProcessTapTestResult(
                outcome: .helperProbeRunning,
                message: "Auto-detecting...",
                detail: "Listening briefly. No audio will be replayed, saved, or modified.",
                severity: .info
            )

            let result = await helperProcessAudioProbe.probeAudio(
                for: target,
                duration: AppConstants.processTapHelperAutoDetectDuration
            ) { progress in
                Task { @MainActor in
                    guard self.isHelperProcessAutoDetectRunning,
                          self.helperProcessProbeRunningPID == processIdentifier else {
                        return
                    }

                    self.helperProcessProbeProgressByPID[processIdentifier] = progress
                }
            }

            let finalProgress = helperProcessProbeProgressByPID[processIdentifier] ?? initialProgress
            helperProcessProbeResultsByPID[processIdentifier] = result
            helperProcessProbeRunningPID = nil

            if result.outcome == .helperProbeTargetExited ||
                result.outcome == .helperProbeOutputChanged ||
                result.outcome == .helperProbeStopped {
                finishHelperProcessAutoDetect(bestScore: nil, wasCancelled: true)
                return
            }

            guard !Task.isCancelled,
                  isHelperProcessAutoDetectRunning,
                  selectedHelperDiscoveryAppID == parentAppID else {
                finishHelperProcessAutoDetect(bestScore: nil, wasCancelled: true)
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

        finishHelperProcessAutoDetect(
            bestScore: scoredResults.max(),
            wasCancelled: false
        )
    }

    private func finishHelperProcessAutoDetect(
        bestScore: HelperProcessAutoDetectScore?,
        wasCancelled: Bool
    ) {
        helperProcessAutoDetectTask = nil
        helperProcessProbeRunningPID = nil
        isHelperProcessAutoDetectRunning = false
        helperProcessAutoDetectProgressText = nil

        guard !wasCancelled else {
            helperProcessDiscoveryMessage = "Auto-detect stopped"
            AppLogger.helperResolution.info("Advanced helper auto-detect stopped")
            return
        }

        guard let bestScore,
              bestScore.hasDetectedAudio else {
            helperProcessDiscoveryMessage = "No audio helper detected"
            AppLogger.helperResolution.info("Advanced helper auto-detect found no audio helper")
            return
        }

        useHelperCandidateAsAdvancedTarget(bestScore.processIdentifier)
        helperProcessDiscoveryMessage = "Selected audio helper"
        AppLogger.helperResolution.info("Advanced helper auto-detect selected helperPID=\(bestScore.processIdentifier, privacy: .public) rms=\(bestScore.progress.rmsLevel, privacy: .public) peak=\(bestScore.progress.peakLevel, privacy: .public)")
    }

    private func handleTwoAppReadinessFinished(
        _ result: ProcessTapTwoAppReadinessResult,
        snapshot: ProcessTapTwoAppReadinessSnapshot
    ) {
        twoAppReadinessResult = result
        twoAppReadinessSnapshot = snapshot
        isTwoAppReadinessRunning = false

        if result.severity == .warning {
            showStatus(result.message, style: .warning)
        }
    }

    private func refreshTwoAppReadinessSelectionsAfterAppRefresh() {
        let targetIDs = Set(twoAppReadinessTargets.map(\.id))
        let preferredIDs = Self.preferredTwoAppReadinessTargetIDs(in: twoAppReadinessTargets)

        if isTwoAppReadinessRunning {
            if selectedTwoAppReadinessAppAID.map({ !targetIDs.contains($0) }) == true ||
                selectedTwoAppReadinessAppBID.map({ !targetIDs.contains($0) }) == true {
                stopTwoAppReadiness(reason: .targetAppExited)
            }
            return
        }

        if selectedTwoAppReadinessAppAID.map({ !targetIDs.contains($0) }) != false {
            selectedTwoAppReadinessAppAID = preferredIDs.appAID
        }

        if selectedTwoAppReadinessAppBID.map({ !targetIDs.contains($0) }) != false ||
            selectedTwoAppReadinessTargetsUseSameProcess {
            selectedTwoAppReadinessAppBID = preferredIDs.appBID
        }
    }

    private func refreshTwoAppReadinessSelectionsAfterTargetChange(removedTargetID: String? = nil) {
        if let removedTargetID {
            if selectedTwoAppReadinessAppAID == removedTargetID {
                selectedTwoAppReadinessAppAID = nil
            }

            if selectedTwoAppReadinessAppBID == removedTargetID {
                selectedTwoAppReadinessAppBID = nil
            }
        }

        guard !isTwoAppReadinessRunning else {
            return
        }

        refreshTwoAppReadinessSelectionsAfterAppRefresh()
    }

    private func refreshHelperDiscoverySelectionAfterAppRefresh() {
        let appIDs = Set(apps.map(\.id))

        guard selectedHelperDiscoveryAppID.map({ appIDs.contains($0) }) != true else {
            return
        }

        stopHelperProcessAutoDetect(reason: .targetExited)
        selectedHelperDiscoveryAppID = Self.preferredHelperDiscoveryAppID(in: apps)
        helperProcessCandidates = []
        helperProcessDiscoveryMessage = nil
        helperProcessProbeResultsByPID = [:]
        helperProcessProbeProgressByPID = [:]
    }

    private func invalidateCachedAudioTargetsForRemovedOrChangedApps(
        previousApps: [MixerAppItem],
        refreshedApps: [MixerAppItem]
    ) {
        let refreshedAppsByID = Dictionary(uniqueKeysWithValues: refreshedApps.map { ($0.id, $0) })

        for previousApp in previousApps {
            guard let refreshedApp = refreshedAppsByID[previousApp.id] else {
                appAudioTargetResolver.invalidateCachedTarget(for: previousApp.appAudioTargetRequest)
                continue
            }

            if previousApp.processIdentifier != refreshedApp.processIdentifier {
                appAudioTargetResolver.invalidateCachedTarget(for: previousApp.appAudioTargetRequest)
            }
        }
    }

    private func refreshTwoAppReadinessEligibility() {
        twoAppReadinessEligibilityByAppID = Self.twoAppReadinessEligibility(for: apps)
    }

    private func updateExperimentalGainIfActive(for app: MixerAppItem) {
        guard isExperimentalControlActive(for: app.id) else {
            return
        }

        processTapLiveController.updateLiveControlGain(experimentalGainOption(for: app))
    }

    private func experimentalGainOption(for app: MixerAppItem) -> ProcessTapReplayGainOption {
        let scalar: Float = app.isMuted
            ? 0
            : Float(app.volume.clamped(to: AppConstants.volumeRange) / AppConstants.volumeRange.upperBound)
        let percent = Int((Double(scalar) * 100).rounded())

        return ProcessTapReplayGainOption(
            scalar: scalar,
            label: "\(percent)%"
        )
    }

    @discardableResult
    private func syncSelectedOutputDeviceWithDefault(fallbackDeviceID: OutputDeviceItem.ID?) -> Bool {
        let previousSelectedDeviceID = selectedOutputDeviceID

        if let defaultDevice = outputDevices.first(where: { $0.isSystemDefault }) {
            selectedOutputDeviceID = defaultDevice.id
        } else if let fallbackDeviceID,
                  outputDevices.contains(where: { $0.id == fallbackDeviceID }) {
            selectedOutputDeviceID = fallbackDeviceID
        } else {
            selectedOutputDeviceID = Self.preferredOutputDeviceID(in: outputDevices)
        }

        return selectedOutputDeviceID != previousSelectedDeviceID
    }

    private static func preferredProcessTapAppID(in apps: [MixerAppItem]) -> MixerAppItem.ID? {
        apps.first { $0.isEligibleForExperimentalLiveControl }?.id ?? apps.first?.id
    }

    private static func preferredHelperDiscoveryAppID(in apps: [MixerAppItem]) -> MixerAppItem.ID? {
        apps.first { app in
            HelperProcessCandidateDiscovery.isLikelyHelperResolvable(app.helperProcessDiscoveryTarget)
        }?.id ?? apps.first?.id
    }

    private static func preferredTwoAppReadinessAppIDs(
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

    private static func preferredTwoAppReadinessTargetIDs(
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

    private static func twoAppReadinessEligibility(
        for apps: [MixerAppItem]
    ) -> [MixerAppItem.ID: ProcessTapProcessEligibility] {
        Dictionary(
            uniqueKeysWithValues: apps.map { app in
                (app.id, ProcessTapCoreAudio.processTapEligibility(for: app.processIdentifier))
            }
        )
    }

    private var selectedProcessTapApp: MixerAppItem? {
        guard let selectedProcessTapAppID else {
            return nil
        }

        return apps.first { $0.id == selectedProcessTapAppID }
    }

    private func processTapTarget(for mode: ProcessTapTestMode) -> ProcessTapTarget? {
        if mode == .diagnostics, let advancedProcessTapTarget {
            return advancedProcessTapTarget.target
        }

        guard let selectedProcessTapApp else {
            return nil
        }

        return ProcessTapTarget(
            appID: selectedProcessTapApp.id,
            appName: selectedProcessTapApp.name,
            processIdentifier: selectedProcessTapApp.processIdentifier
        )
    }

    private var replayProbeTarget: ProcessTapTarget? {
        if let advancedProcessTapTarget {
            return advancedProcessTapTarget.target
        }

        guard let selectedProcessTapApp else {
            return nil
        }

        return ProcessTapTarget(
            appID: selectedProcessTapApp.id,
            appName: selectedProcessTapApp.name,
            processIdentifier: selectedProcessTapApp.processIdentifier
        )
    }

    private var replayProbeRunningDetail: String {
        if advancedProcessTapTarget != nil {
            return "Experimental: may briefly mute/replay selected helper audio. Gain \(selectedProcessTapReplayGain.percentLabel)."
        }

        return "Experimental: may briefly mute/replay selected app audio. Gain \(selectedProcessTapReplayGain.percentLabel)."
    }

    private var selectedTwoAppReadinessTargetA: TwoAppReadinessTargetOption? {
        guard let selectedTwoAppReadinessAppAID else {
            return nil
        }

        return twoAppReadinessTargets.first { $0.id == selectedTwoAppReadinessAppAID }
    }

    private var selectedTwoAppReadinessTargetB: TwoAppReadinessTargetOption? {
        guard let selectedTwoAppReadinessAppBID else {
            return nil
        }

        return twoAppReadinessTargets.first { $0.id == selectedTwoAppReadinessAppBID }
    }

    private var selectedTwoAppReadinessTargetsUseSameProcess: Bool {
        guard let targetA = selectedTwoAppReadinessTargetA,
              let targetB = selectedTwoAppReadinessTargetB else {
            return false
        }

        return targetA.processIdentifier == targetB.processIdentifier
    }

    private func validProcessIdentifier(_ processIdentifier: Int32?) -> Bool {
        guard let processIdentifier else {
            return false
        }

        return processIdentifier > 0
    }

    private var selectedHelperDiscoveryApp: MixerAppItem? {
        guard let selectedHelperDiscoveryAppID else {
            return nil
        }

        return apps.first { $0.id == selectedHelperDiscoveryAppID }
    }

    private var isAppAudioTargetResolving: Bool {
        !appAudioResolutionStateByAppID.isEmpty
    }

    private func applyRequestedSystemVolume(_ volume: Double) -> Bool {
        let clampedVolume = volume.clamped(to: AppConstants.volumeRange)
        let volumeScalar = clampedVolume / AppConstants.volumeRange.upperBound

        applySystemVolume(clampedVolume)

        let didSetVolume = systemVolumeController.setCurrentOutputVolumeScalar(volumeScalar)
        if didSetVolume {
            audioController.setSystemVolume(clampedVolume)
        }

        return didSetVolume
    }

    private func showStatus(_ text: String, style: MixerStatusMessage.Style) {
        let message = MixerStatusMessage(text: text, style: style)
        statusMessage = message
        clearStatusAfterDelay(message.id)
    }

    private func clearStatusAfterDelay(_ messageID: MixerStatusMessage.ID) {
        statusClearTask?.cancel()

        statusClearTask = Task { [weak self] in
            let delayNanoseconds = UInt64(AppConstants.statusMessageAutoClearDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanoseconds)

            await MainActor.run {
                guard self?.statusMessage?.id == messageID else {
                    return
                }

                self?.statusMessage = nil
            }
        }
    }

    private var restoredSystemOutputVolume: Double {
        let restoredVolume = lastNonZeroSystemVolume.clamped(to: AppConstants.volumeRange)
        return restoredVolume > AppConstants.volumeRange.lowerBound
            ? restoredVolume
            : AppConstants.defaultSystemOutputRestoreVolume
    }

    private func applySystemVolume(_ volume: Double) {
        let clampedVolume = volume.clamped(to: AppConstants.volumeRange)

        systemVolume = clampedVolume
        isSystemOutputMuted = clampedVolume <= AppConstants.volumeRange.lowerBound

        if clampedVolume > AppConstants.volumeRange.lowerBound {
            rememberNonZeroSystemVolume(clampedVolume)
        }
    }

    private func rememberNonZeroSystemVolume(_ volume: Double) {
        let clampedVolume = volume.clamped(to: AppConstants.volumeRange)

        if clampedVolume > AppConstants.volumeRange.lowerBound {
            lastNonZeroSystemVolume = clampedVolume
        }
    }
}

private extension MixerAppItem {
    var appAudioTargetRequest: AppAudioTargetRequest {
        AppAudioTargetRequest(
            appID: id,
            appName: name,
            processIdentifier: processIdentifier
        )
    }

    var helperProcessDiscoveryTarget: HelperProcessDiscoveryTarget {
        HelperProcessDiscoveryTarget(
            id: id,
            name: name,
            processIdentifier: processIdentifier
        )
    }
}

private extension ProcessTapTestMode {
    func runningMessage(for appName: String) -> String {
        switch self {
        case .diagnostics:
            return "Testing Process Tap for \(appName)..."
        case .muteBehaviorProbe:
            return "Running mute probe for \(appName)..."
        }
    }

    var runningDetail: String {
        switch self {
        case .diagnostics:
            return "Listening briefly for callbacks. No audio will be saved or modified."
        case .muteBehaviorProbe:
            return "This may briefly mute the selected app. No audio will be replayed or saved."
        }
    }
}
