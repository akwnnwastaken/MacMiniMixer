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
            viewModel.cancelPendingWorkForPanelClose()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(AppConstants.appTitle)
                .font(.system(size: 15, weight: .bold))
                .fixedSize()
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    if let banner = viewModel.realControlBannerPresentation {
                        realControlIndicator(banner)
                            .transition(.scale.combined(with: .opacity))
                    }

                    outputDeviceButton
                    moreMenu
                    quitButton
                }
            }
        }
        .padding(.leading, 4)
        .frame(height: AppConstants.Layout.headerButtonSize)
    }

    /// Opens the output device list below the header.
    private var outputDeviceButton: some View {
        Button {
            isShowingOutputDevices.toggle()
        } label: {
            Image(systemName: "airplayaudio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isShowingOutputDevices ? Color.accentColor : .primary)
                .frame(width: AppConstants.Layout.headerButtonSize, height: AppConstants.Layout.headerButtonSize)
                .glassControl(
                    in: Circle(),
                    tint: isShowingOutputDevices ? Color.accentColor.opacity(0.22) : nil
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Output device")
        .accessibilityLabel(Text("Output device: \(viewModel.selectedOutputDeviceName)"))
        .accessibilityValue(Text(isShowingOutputDevices ? "Expanded" : "Collapsed"))
        .accessibilityHint(Text(isShowingOutputDevices ? "Hides the output device list" : "Shows the output device list"))
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
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: AppConstants.Layout.headerButtonSize, height: AppConstants.Layout.headerButtonSize)
                .glassControl(in: Circle())
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("More options"))
        .accessibilityHint(Text("Shows Show all apps and Launch at Login"))
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

    /// Small orange indicator in the header while any app is under Real control. Hovering shows
    /// which apps; clicking stops Real control (all apps), like the former banner's Stop button.
    private func realControlIndicator(_ banner: RealControlBannerPresentation) -> some View {
        Button {
            viewModel.stopProcessTapLiveControl()
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: AppConstants.Layout.headerButtonSize, height: AppConstants.Layout.headerButtonSize)
                .glassControl(in: Circle(), tint: Color.orange.opacity(0.22))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(compactBannerText(banner)). Click to \(banner.stopButtonTitle.lowercased()).")
        .accessibilityLabel(Text(banner.stopAccessibilityLabel))
        .accessibilityValue(Text(banner.accessibilityLabel))
    }

    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: AppConstants.Layout.headerButtonSize, height: AppConstants.Layout.headerButtonSize)
                .glassControl(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Quit MacMiniMixer")
        .accessibilityLabel(Text("Quit MacMiniMixer"))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Output")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                if !viewModel.isSystemOutputVolumeWritable {
                    nonWritableVolumeBadge
                }

                Spacer(minLength: 8)

                Button {
                    isShowingOutputDevices.toggle()
                } label: {
                    Text(viewModel.selectedOutputDeviceName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help("Choose output device")
                .accessibilityLabel(Text("Output device: \(viewModel.selectedOutputDeviceName)"))
            }
            .padding(.horizontal, 4)

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
                height: AppConstants.Layout.outputSliderHeight,
                systemImage: viewModel.isSystemOutputMuted ? "speaker.slash.fill" : systemVolumeSymbol,
                isMuted: viewModel.isSystemOutputMuted,
                onIconTap: { viewModel.toggleSystemOutputMuted() },
                onEditingChanged: { isEditing in
                    isEditingSystemOutputSlider = isEditing

                    if !isEditing {
                        viewModel.finishSystemVolumeEditing()
                    }
                }
            )
            .help(viewModel.isSystemOutputMuted ? "Click the speaker to unmute" : "Click the speaker to mute")
            .accessibilityAction(named: Text(viewModel.isSystemOutputMuted ? "Unmute" : "Mute")) {
                viewModel.toggleSystemOutputMuted()
            }
        }
        .padding(AppConstants.Layout.sectionPadding)
        .platter()
    }

    private var systemVolumeSymbol: String {
        switch viewModel.systemVolume {
        case ..<1:
            return "speaker.fill"
        case ..<34:
            return "speaker.wave.1.fill"
        case ..<67:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.3.fill"
        }
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
        VStack(alignment: .leading, spacing: 10) {
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
            .padding(.horizontal, 4)

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
        .padding(AppConstants.Layout.sectionPadding)
        .platter()
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
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .platter()
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
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: AppConstants.Layout.cornerRadius, style: .continuous)
                .fill(message.style.tint.opacity(0.12))
        )
    }

    private func statusActionButton(_ action: MixerStatusMessage.Action) -> some View {
        Button {
            perform(action)
        } label: {
            Text(action.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .glassControl(in: Capsule(style: .continuous), tint: Color.blue.opacity(0.18))
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

    /// On macOS 26+ the menu bar window is Liquid Glass already; the panel adds nothing over it.
    @ViewBuilder
    private var panelBackground: some View {
        if #available(macOS 26, *) {
            Color.clear
        } else {
            RoundedRectangle(cornerRadius: AppConstants.Layout.panelCornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppConstants.Layout.panelCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
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
