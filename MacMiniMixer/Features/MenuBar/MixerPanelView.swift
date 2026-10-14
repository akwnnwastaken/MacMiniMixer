import AppKit
import ServiceManagement
import SwiftUI

struct MixerPanelView: View {
    @ObservedObject var viewModel: MixerViewModel
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var launchAtLoginError: String?
    @State private var isShowingOutputDevices = false
    @State private var isEditingSystemOutputSlider = false
    @State private var isShowingAdvanced = false
    /// Advanced diagnostics are developer-only: the section is not built at all unless the
    /// `MacMiniMixerDeveloperMode` default is true. Read once when the panel is first created.
    @State private var isDeveloperModeEnabled = UserDefaults.standard.bool(
        forKey: AppConstants.developerModeDefaultsKey
    )

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.panelSpacing) {
            VStack(alignment: .leading, spacing: AppConstants.Layout.sectionSpacing) {
                header

                if let banner = viewModel.realControlBannerPresentation {
                    activeLiveControlBanner(banner)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let statusMessage = viewModel.statusMessage {
                    statusMessageView(statusMessage)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if isShowingOutputDevices {
                    OutputDeviceSelectorView(
                        devices: viewModel.outputDevices,
                        selectedDeviceID: viewModel.selectedOutputDeviceID,
                        selectDevice: viewModel.selectOutputDevice,
                        refreshDevices: viewModel.refreshOutputDevices
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                systemOutputSection
                appMixerSection
            }

            if isDeveloperModeEnabled {
                advancedSection
            }
        }
        .padding(AppConstants.Layout.panelPadding)
        .frame(width: AppConstants.Layout.panelWidth)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppConstants.Layout.panelCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
        .animation(.snappy(duration: 0.18), value: isShowingOutputDevices)
        .animation(.snappy(duration: 0.18), value: isShowingAdvanced)
        .animation(.snappy(duration: 0.18), value: viewModel.statusMessage)
        .animation(.snappy(duration: 0.18), value: viewModel.isProcessTapLiveControlActive)
        .onAppear {
            refreshLaunchAtLoginStatus()
            // Product live diagnostics are only published while the Advanced section is on screen.
            viewModel.setLiveDiagnosticsDisplayVisible(isShowingAdvanced)
            viewModel.refreshApplications()
            viewModel.setOutputActivityVisible(true)
            viewModel.refreshOutputDevices()
            viewModel.refreshSystemOutputVolume()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLaunchAtLoginStatus()
        }
        .alert("Could not update Launch at Login", isPresented: Binding(
            get: { launchAtLoginError != nil },
            set: { if !$0 { launchAtLoginError = nil } }
        )) {
            Button("OK", role: .cancel) { launchAtLoginError = nil }
        } message: {
            Text(launchAtLoginError ?? "")
        }
        .task {
            await runSystemVolumeRefreshLoop()
        }
        .task {
            await runOutputDeviceRefreshLoop()
        }
        .onDisappear {
            viewModel.setOutputActivityVisible(false)
            viewModel.setLiveDiagnosticsDisplayVisible(false)
            viewModel.stopTwoAppReadinessForPanelClose()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(AppConstants.appTitle)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize()
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            outputDeviceButton

            moreMenu
        }
        .frame(height: AppConstants.Layout.headerButtonSize)
    }

    /// Shows the current output device and opens the device list below the header.
    private var outputDeviceButton: some View {
        Button {
            isShowingOutputDevices.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(viewModel.selectedOutputDeviceName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isShowingOutputDevices ? Color.accentColor : .secondary)
                    .rotationEffect(.degrees(isShowingOutputDevices ? 180 : 0))
            }
            .padding(.horizontal, 11)
            .frame(height: AppConstants.Layout.headerButtonSize)
            .frame(maxWidth: AppConstants.Layout.deviceButtonMaxWidth)
            .background(chipBackground(isHighlighted: isShowingOutputDevices))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Output device")
        .accessibilityLabel(Text("Output device: \(viewModel.selectedOutputDeviceName)"))
        .accessibilityValue(Text(isShowingOutputDevices ? "Expanded" : "Collapsed"))
        .accessibilityHint(Text(isShowingOutputDevices ? "Hides the output device list" : "Shows the output device list"))
    }

    private func chipBackground(isHighlighted: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(isHighlighted ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.08))
    }

    /// Secondary actions kept out of the main panel body.
    private var moreMenu: some View {
        Menu {
            Toggle(
                "Show all apps",
                isOn: Binding(
                    get: { viewModel.showAllApps },
                    set: { viewModel.setShowAllApps($0) }
                )
            )
            .help("Show all regular running apps")
            .accessibilityLabel(Text("Show all apps"))
            .accessibilityHint(Text("When off, only audio-relevant apps are listed"))

            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval },
                    set: { setLaunchAtLogin($0) }
                )
            )
            .help("Start MacMiniMixer automatically when you log in")
            .accessibilityHint(Text("Starts MacMiniMixer automatically when you log in"))

            if launchAtLoginStatus == .requiresApproval {
                Button("Approve Launch at Login in System Settings…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit MacMiniMixer", systemImage: "power")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: AppConstants.Layout.headerButtonSize, height: AppConstants.Layout.headerButtonSize)
                .background(chipBackground(isHighlighted: false))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("More options"))
        .accessibilityHint(Text("Shows Show all apps, Launch at Login, and Quit"))
        .help("More options")
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        // macOS owns this setting; never report success using a separate saved preference.
        refreshLaunchAtLoginStatus()
    }

    private func activeLiveControlBanner(_ banner: RealControlBannerPresentation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(compactBannerText(banner))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(Text(banner.accessibilityLabel))

            Spacer(minLength: 6)

            Button {
                viewModel.stopProcessTapLiveControl()
            } label: {
                Text(banner.stopButtonTitle)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.orange.opacity(0.14))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.orange.opacity(0.24), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("Stop experimental live control")
            .accessibilityLabel(Text(banner.stopAccessibilityLabel))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: AppConstants.Layout.rowCornerRadius, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppConstants.Layout.rowCornerRadius, style: .continuous)
                        .stroke(Color.orange.opacity(0.24), lineWidth: 1)
                )
        )
    }

    /// One-line banner text: "N apps controlled" once two or more apps are confirmed (the full
    /// name list stays in the accessibility label), otherwise the presenter's own summary.
    private func compactBannerText(_ banner: RealControlBannerPresentation) -> String {
        if banner.mode == .product, banner.confirmedCount >= 2 {
            return "\(banner.confirmedCount) apps controlled"
        }

        return banner.summaryText
    }

    private var systemOutputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Output")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                if !viewModel.isSystemOutputVolumeWritable {
                    nonWritableVolumeBadge
                }

                Spacer()

                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(viewModel.systemVolume.rounded()))")
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    Text("%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(viewModel.isSystemOutputMuted ? .secondary : .primary)
                .accessibilityHidden(true)
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.toggleSystemOutputMuted()
                } label: {
                    Image(systemName: viewModel.isSystemOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(viewModel.isSystemOutputMuted ? .secondary : .primary)
                        .frame(width: AppConstants.Layout.headerButtonSize, height: AppConstants.Layout.headerButtonSize)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(viewModel.isSystemOutputMuted ? "Unmute system output" : "Mute system output")
                .accessibilityLabel(Text(viewModel.isSystemOutputMuted ? "Unmute system output" : "Mute system output"))

                VolumeSlider(
                    value: Binding(
                        get: { viewModel.systemVolume },
                        set: { viewModel.setSystemVolume($0) }
                    ),
                    scale: VolumeSliderScale(range: AppConstants.volumeRange, unity: nil),
                    accessibilityLabel: "System output volume",
                    accessibilityHint: viewModel.isSystemOutputVolumeWritable
                        ? "Adjusts the system output volume"
                        : "This output device does not expose writable volume",
                    trackHeight: 6,
                    knobSize: 20,
                    onEditingChanged: { isEditing in
                        isEditingSystemOutputSlider = isEditing

                        if !isEditing {
                            viewModel.finishSystemVolumeEditing()
                        }
                    }
                )
            }
        }
        .sectionStyle()
    }

    private var nonWritableVolumeBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))

            Text("Read-only")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .accessibilityElement(children: .ignore)
        .help("This output device does not expose a writable volume API. Use the device's own controls to change volume.")
        .accessibilityLabel(Text("Volume is read-only on this output device"))
        .accessibilityHint(Text("This device does not allow volume changes from MacMiniMixer. Use the device's own controls to change volume."))
    }

    private var appMixerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Apps")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.4)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                if !viewModel.visibleMixerApps.isEmpty {
                    Text("\(viewModel.visibleMixerApps.count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(Text("\(viewModel.visibleMixerApps.count) apps"))
                }
            }
            .padding(.horizontal, 8)

            if viewModel.visibleMixerApps.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)

                    Text(viewModel.apps.isEmpty ? "No running apps found" : "No apps are playing audio")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    if !viewModel.apps.isEmpty && !viewModel.showAllApps {
                        Button("Show all apps") {
                            viewModel.setShowAllApps(true)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: AppConstants.Layout.appListMinHeight)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: AppConstants.Layout.rowInnerSpacing) {
                        ForEach(viewModel.visibleMixerApps) { app in
                            MixerAppRowView(
                                app: app,
                                isOutputActive: viewModel.activeOutputAppIDs.contains(app.id),
                                isExperimentalControlActive: viewModel.isExperimentalControlActive(for: app.id),
                                isExperimentalControlResolving: viewModel.isResolvingExperimentalControl(for: app.id),
                                isExperimentalControlPending: viewModel.isExperimentalControlPending(for: app.id),
                                toggleExperimentalControl: {
                                    viewModel.toggleExperimentalControl(for: app.id)
                                },
                                volume: Binding(
                                    get: { viewModel.volume(for: app.id) },
                                    set: { viewModel.setAppVolume($0, for: app.id) }
                                ),
                                isMuted: Binding(
                                    get: { viewModel.isMuted(for: app.id) },
                                    set: { viewModel.setMuted($0, for: app.id) }
                                )
                            )
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: appListHeight)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: isShowingAdvanced ? 8 : 0) {
            Button {
                let showsAdvanced = !isShowingAdvanced
                withAnimation(.snappy(duration: 0.16)) {
                    isShowingAdvanced = showsAdvanced
                }
                viewModel.setLiveDiagnosticsDisplayVisible(showsAdvanced)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 15)

                    Text("Advanced")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isShowingAdvanced ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Advanced"))
            .accessibilityValue(Text(isShowingAdvanced ? "Expanded" : "Collapsed"))
            .accessibilityHint(Text(isShowingAdvanced
                ? "Hides the experimental diagnostic tools"
                : "Shows the experimental diagnostic tools"))

            if isShowingAdvanced {
                VStack(alignment: .leading, spacing: 8) {
                    ProcessTapTestView(
                        apps: viewModel.apps,
                        selectedAppID: viewModel.selectedProcessTapAppID,
                        result: viewModel.processTapTestResult,
                        progress: viewModel.processTapDiagnosticProgress,
                        advancedTarget: viewModel.advancedProcessTapTarget,
                        selectedReplayGain: viewModel.selectedProcessTapReplayGain,
                        liveDiagnostics: viewModel.processTapLiveDiagnostics,
                        isTesting: viewModel.isProcessTapTesting,
                        isLiveControlActive: viewModel.isProcessTapLiveControlActive,
                        selectApp: viewModel.selectProcessTapApp,
                        selectReplayGain: viewModel.selectProcessTapReplayGain,
                        testProcessTap: viewModel.testSelectedProcessTapApp,
                        testMuteBehavior: viewModel.testSelectedProcessTapMuteProbe,
                        testReplayProbe: viewModel.testSelectedProcessTapReplayProbe,
                        startLiveControl: viewModel.startProcessTapLiveControl,
                        stopLiveControl: viewModel.stopProcessTapLiveControl,
                        clearAdvancedTarget: viewModel.clearAdvancedProcessTapTarget,
                        showsHeader: false
                    )

                    HelperProcessDiscoveryView(
                        apps: viewModel.apps,
                        selectedAppID: viewModel.selectedHelperDiscoveryAppID,
                        candidates: viewModel.helperProcessCandidates,
                        message: viewModel.helperProcessDiscoveryMessage,
                        isScanning: viewModel.isHelperProcessDiscoveryScanning,
                        isAutoDetectRunning: viewModel.isHelperProcessAutoDetectRunning,
                        autoDetectProgressText: viewModel.helperProcessAutoDetectProgressText,
                        probeResultsByPID: viewModel.helperProcessProbeResultsByPID,
                        probeProgressByPID: viewModel.helperProcessProbeProgressByPID,
                        runningProbePID: viewModel.helperProcessProbeRunningPID,
                        advancedTarget: viewModel.advancedProcessTapTarget,
                        selectApp: viewModel.selectHelperDiscoveryApp,
                        scanHelpers: viewModel.scanHelperProcesses,
                        autoDetectHelper: viewModel.autoDetectHelperProcessCandidate,
                        probeCandidate: viewModel.probeHelperProcessCandidate,
                        useCandidateAsAdvancedTarget: viewModel.useHelperCandidateAsAdvancedTarget
                    )

                    TwoAppReadinessTestView(
                        targets: viewModel.twoAppReadinessTargets,
                        selectedAppAID: viewModel.selectedTwoAppReadinessAppAID,
                        selectedAppBID: viewModel.selectedTwoAppReadinessAppBID,
                        selectedGain: viewModel.selectedTwoAppReadinessGain,
                        selectedDuration: viewModel.selectedTwoAppReadinessDuration,
                        snapshot: viewModel.twoAppReadinessSnapshot,
                        result: viewModel.twoAppReadinessResult,
                        isRunning: viewModel.isTwoAppReadinessRunning,
                        selectAppA: viewModel.selectTwoAppReadinessAppA,
                        selectAppB: viewModel.selectTwoAppReadinessAppB,
                        selectGain: viewModel.selectTwoAppReadinessGain,
                        selectDuration: viewModel.selectTwoAppReadinessDuration,
                        startTest: viewModel.startTwoAppReadinessTest,
                        stopAll: viewModel.stopTwoAppReadinessTest
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sectionStyle()
    }

    private var appListHeight: CGFloat {
        let appCount = CGFloat(viewModel.visibleMixerApps.count)
        let rowHeights = appCount * AppConstants.Layout.appRowApproxHeight
        let rowSpacings = max(0, appCount - 1) * AppConstants.Layout.rowInnerSpacing
        let contentHeight = rowHeights + rowSpacings

        return min(
            AppConstants.Layout.appListMaxHeight,
            max(AppConstants.Layout.appListMinHeight, contentHeight)
        )
    }

    private func refreshSystemOutputVolumeIfIdle() {
        guard !isEditingSystemOutputSlider else {
            return
        }

        viewModel.refreshSystemOutputVolume()
    }

    private func runSystemVolumeRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(
                nanoseconds: UInt64(AppConstants.systemVolumeRefreshInterval * 1_000_000_000)
            )

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                refreshSystemOutputVolumeIfIdle()
                viewModel.refreshOutputActivity()
            }
        }
    }

    private func runOutputDeviceRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(
                nanoseconds: UInt64(AppConstants.outputDeviceRefreshInterval * 1_000_000_000)
            )

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                viewModel.refreshOutputDevices()
            }
        }
    }

    private func statusMessageView(_ message: MixerStatusMessage) -> some View {
        HStack(spacing: 7) {
            Image(systemName: message.style.iconSystemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(message.style.tint)
                .frame(width: 14)
                .accessibilityHidden(true)

            // The icon is hidden; its severity is spoken as a prefix instead. The label also keeps
            // the full message even when the visible single line is truncated.
            Text(message.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(Text(statusSpokenLabel(message)))

            Spacer(minLength: 0)

            if let action = message.action {
                statusActionButton(action)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(message.style.tint.opacity(0.22), lineWidth: 1)
                )
        )
    }

    private func statusActionButton(_ action: MixerStatusMessage.Action) -> some View {
        Button {
            perform(action)
        } label: {
            Text(action.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.blue.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
        .accessibilityHint(Text("Opens Privacy and Security settings to grant System Audio Recording"))
    }

    private func statusSpokenLabel(_ message: MixerStatusMessage) -> String {
        "\(message.style.spokenName): \(message.text)"
    }

    private func perform(_ action: MixerStatusMessage.Action) {
        switch action {
        case .openSystemAudioRecordingSettings:
            if let url = ProcessTapPermissionMessage.systemAudioRecordingSettingsURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: AppConstants.Layout.panelCornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: AppConstants.Layout.panelCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

private extension MixerStatusMessage.Style {
    var iconSystemName: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        }
    }

    /// Spoken severity for the status banner, replacing the hidden icon.
    var spokenName: String {
        switch self {
        case .info:
            return "Info"
        case .success:
            return "Success"
        case .warning:
            return "Warning"
        }
    }
}

private extension View {
    /// Card used for the Output section and the Advanced tools.
    func sectionStyle() -> some View {
        padding(AppConstants.Layout.sectionPadding)
            .background(
                RoundedRectangle(cornerRadius: AppConstants.Layout.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
    }
}
