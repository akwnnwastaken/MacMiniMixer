import AppKit
import Foundation

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
    private var lastNonZeroSystemVolume: Double
    private var lastSliderVolumeSetSucceeded: Bool?
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
        processTapLiveController: ProcessTapLiveControlling
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

        let initialSystemVolume = audioController.systemVolume.clamped(to: AppConstants.volumeRange)
        let initialApps = applicationLister.listApplications()
        self.systemVolume = initialSystemVolume
        self.isSystemOutputMuted = initialSystemVolume <= AppConstants.volumeRange.lowerBound
        self.lastNonZeroSystemVolume = initialSystemVolume > AppConstants.volumeRange.lowerBound
            ? initialSystemVolume
            : AppConstants.defaultSystemOutputRestoreVolume
        self.apps = initialApps
        self.selectedProcessTapAppID = Self.preferredProcessTapAppID(in: initialApps)
        self.selectedProcessTapReplayGain = .defaultOption

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
    }

    var selectedOutputDeviceName: String {
        outputDevices.first { $0.id == selectedOutputDeviceID }?.name ?? "Output"
    }

    var visibleMixerApps: [MixerAppItem] {
        if showAllApps {
            return apps
        }

        return apps.filter { app in
            app.isLikelyAudioRelevant || isActiveLiveControlTarget(app.id)
        }
    }

    func setShowAllApps(_ showAllApps: Bool) {
        self.showAllApps = showAllApps
    }

    func setExperimentalRealAppControlEnabled(_ isEnabled: Bool) {
        isExperimentalRealAppControlEnabled = isEnabled

        if !isEnabled, isProcessTapLiveControlActive {
            stopProcessTapLiveControl()
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
            stopProcessTapLiveControl(reason: .outputDeviceChanged)
        }

        if didSelectionChange || refreshedDefaultDeviceID != previousDefaultDeviceID {
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
        guard !isProcessTapLiveControlActive else {
            return
        }

        guard apps.contains(where: { $0.id == appID }) else {
            return
        }

        selectedProcessTapAppID = appID
        processTapTestResult = nil
        processTapDiagnosticProgress = nil
    }

    func testSelectedProcessTapApp() {
        startProcessTapTest(mode: .diagnostics)
    }

    func testSelectedProcessTapMuteProbe() {
        startProcessTapTest(mode: .muteBehaviorProbe)
    }

    func selectProcessTapReplayGain(_ gain: ProcessTapReplayGainOption) {
        guard !isProcessTapTesting, !isProcessTapLiveControlActive else {
            return
        }

        selectedProcessTapReplayGain = gain
        processTapTestResult = nil
        processTapDiagnosticProgress = nil
    }

    func testSelectedProcessTapReplayProbe() {
        guard !isProcessTapTesting, !isProcessTapLiveControlActive else {
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
        processTapTestResult = ProcessTapTestResult(
            outcome: .replayProbeRunning,
            message: "Replay testing \(app.name)...",
            detail: "Experimental: may briefly mute/replay selected app audio. Gain \(selectedProcessTapReplayGain.percentLabel).",
            severity: .info
        )
        processTapDiagnosticProgress = ProcessTapDiagnosticProgress(
            callbackCount: 0,
            peakLevel: 0,
            rmsLevel: 0,
            audioDetected: false
        )
        isProcessTapTesting = true

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
            }
        }
    }

    func startProcessTapLiveControl() {
        guard !isProcessTapTesting, !isProcessTapLiveControlActive else {
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
                if result.message == "Live control is not active" {
                    handleLiveControlStopped(result, diagnostics: processTapLiveDiagnostics)
                }
            }
        }
    }

    func stopProcessTapLiveControlForTermination() {
        _ = processTapLiveController.stopLiveControlNow(reason: .appTerminating)
        isProcessTapLiveControlActive = false
        isProcessTapTesting = false
        activeExperimentalAppID = nil
        activeLiveControlAppName = nil
    }

    func isExperimentalControlActive(for appID: MixerAppItem.ID) -> Bool {
        activeExperimentalAppID == appID && isProcessTapLiveControlActive
    }

    func isExperimentalControlBusy(for appID: MixerAppItem.ID) -> Bool {
        if activeExperimentalAppID == appID {
            return isProcessTapTesting
        }

        return isProcessTapTesting || isProcessTapLiveControlActive
    }

    func isExperimentalControlEligible(for appID: MixerAppItem.ID) -> Bool {
        apps.first { $0.id == appID }?.isEligibleForExperimentalLiveControl ?? false
    }

    func toggleExperimentalControl(for appID: MixerAppItem.ID) {
        if isExperimentalControlActive(for: appID) {
            stopProcessTapLiveControl()
            return
        }

        startExperimentalControl(for: appID)
    }

    private func startProcessTapTest(mode: ProcessTapTestMode) {
        guard !isProcessTapTesting, !isProcessTapLiveControlActive else {
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
        processTapTestResult = ProcessTapTestResult(
            outcome: .streamDiagnosticsRunning,
            message: mode.runningMessage(for: app.name),
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

        if let activeExperimentalAppID,
           !apps.contains(where: { $0.id == activeExperimentalAppID }) {
            stopProcessTapLiveControl(reason: .targetAppExited)
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

        guard app.isEligibleForExperimentalLiveControl else {
            showStatus("This app is not available for real app control", style: .warning)
            return
        }

        if isExperimentalControlActive(for: app.id) {
            return
        }

        if isProcessTapLiveControlActive || isProcessTapTesting {
            showStatus("Stop active live control first", style: .warning)
            return
        }

        startExperimentalControl(for: app.id)
    }

    private func startExperimentalControl(for appID: MixerAppItem.ID) {
        guard !isProcessTapTesting else {
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
        let gain = experimentalGainOption(for: app)

        activeExperimentalAppID = appID
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
                    activeExperimentalAppID = appID
                    activeLiveControlAppName = app.name
                } else {
                    activeExperimentalAppID = nil
                    activeLiveControlAppName = nil
                    processTapLiveDiagnostics = nil
                    processTapDiagnosticProgress = nil
                    showStatus("Could not start live control for this app", style: .warning)
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
        processTapTestResult = result
        processTapLiveDiagnostics = diagnostics
        processTapDiagnosticProgress = diagnostics?.progress
        isProcessTapLiveControlActive = false
        isProcessTapTesting = false
        activeExperimentalAppID = nil
        activeLiveControlAppName = nil
        showLiveControlWarningIfNeeded(for: result)
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
        default:
            break
        }
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

    private var selectedProcessTapApp: MixerAppItem? {
        guard let selectedProcessTapAppID else {
            return nil
        }

        return apps.first { $0.id == selectedProcessTapAppID }
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
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
