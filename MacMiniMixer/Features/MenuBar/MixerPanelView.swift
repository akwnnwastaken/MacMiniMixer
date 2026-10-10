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
            viewModel.setLiveDiagnosticsDisplayVisible(false)
            viewModel.stopTwoAppReadinessForPanelClose()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(AppConstants.appTitle)
                    .font(.headline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer()

            Button {
                isShowingOutputDevices.toggle()
            } label: {
                Image(systemName: isShowingOutputDevices ? "airplayaudio.circle.fill" : "airplayaudio")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: AppConstants.Layout.headerButtonSize, height: AppConstants.Layout.headerButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Output devices"))
            .accessibilityValue(Text(isShowingOutputDevices ? "Expanded" : "Collapsed"))
            .accessibilityHint(Text(isShowingOutputDevices ? "Hides the output device list" : "Shows the output device list"))
            .foregroundStyle(isShowingOutputDevices ? .blue : .secondary)
            .background(headerButtonBackground(isHighlighted: isShowingOutputDevices))
            .help("Output devices")

            moreMenu
        }
        .padding(.horizontal, 3)
        .padding(.top, 1)
    }

    private func headerButtonBackground(isHighlighted: Bool) -> some View {
        Circle()
            .fill(.thinMaterial.opacity(isHighlighted ? 0.95 : 0.55))
            .overlay(
                Circle()
                    .stroke(.white.opacity(isHighlighted ? 0.22 : 0.12), lineWidth: 1)
            )
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: AppConstants.Layout.headerButtonSize, height: AppConstants.Layout.headerButtonSize)
                .background(headerButtonBackground(isHighlighted: false))
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
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("System Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)

                if !viewModel.isSystemOutputVolumeWritable {
                    nonWritableVolumeBadge
                }

                Spacer()

                Text(viewModel.selectedOutputDeviceName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .accessibilityLabel(Text("Output device: \(viewModel.selectedOutputDeviceName)"))
            }

            HStack(spacing: AppConstants.Layout.rowSpacing) {
                Button {
                    viewModel.toggleSystemOutputMuted()
                } label: {
                    rowIcon(
                        systemName: viewModel.isSystemOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        isMuted: viewModel.isSystemOutputMuted
                    )
                }
                .buttonStyle(.plain)
                .help(viewModel.isSystemOutputMuted ? "Unmute system output" : "Mute system output")
                .accessibilityLabel(Text(viewModel.isSystemOutputMuted ? "Unmute system output" : "Mute system output"))

                Text("Output")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .frame(width: AppConstants.Layout.appNameWidth, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { viewModel.systemVolume },
                        set: { viewModel.setSystemVolume($0) }
                    ),
                    in: AppConstants.volumeRange,
                    step: 1,
                    onEditingChanged: { isEditing in
                        isEditingSystemOutputSlider = isEditing

                        if !isEditing {
                            viewModel.finishSystemVolumeEditing()
                        }
                    }
                )
                .accessibilityLabel(Text("System output volume"))
                .accessibilityValue(Text("\(Int(viewModel.systemVolume.rounded())) percent"))
                .accessibilityHint(Text(viewModel.isSystemOutputVolumeWritable
                    ? "Adjusts the system output volume"
                    : "This output device does not expose writable volume"))

                volumeText(viewModel.systemVolume)
            }
        }
        .sectionStyle(tintOpacity: 0.32)
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
        VStack(alignment: .leading, spacing: 7) {
            Text("Applications")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 2)

            if viewModel.visibleMixerApps.isEmpty {
                Text(viewModel.apps.isEmpty ? "No running apps found" : "No audio-relevant apps found")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: AppConstants.Layout.appListMinHeight)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: AppConstants.Layout.rowInnerSpacing) {
                        ForEach(viewModel.visibleMixerApps) { app in
                            MixerAppRowView(
                                app: app,
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
                    .padding(.trailing, 2)
                }
                .scrollIndicators(.automatic)
                .frame(height: appListHeight)
            }
        }
        .sectionStyle(tintOpacity: 0.22)
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
        .padding(AppConstants.Layout.sectionPadding)
        .background(
            RoundedRectangle(cornerRadius: AppConstants.Layout.cornerRadius, style: .continuous)
                .fill(.thinMaterial.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: AppConstants.Layout.cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                )
        )
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

    private func volumeText(_ volume: Double) -> some View {
        Text("\(Int(volume.rounded()))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: AppConstants.Layout.volumeValueWidth, alignment: .trailing)
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
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: AppConstants.Layout.panelCornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: AppConstants.Layout.panelCornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
    }

    private func rowIcon(systemName: String, isMuted: Bool) -> some View {
        ZStack {
            Circle()
                .fill(.quaternary.opacity(0.5))

            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isMuted ? .tertiary : .secondary)
        }
        .frame(width: AppConstants.Layout.rowIconSize, height: AppConstants.Layout.rowIconSize)
        .contentShape(Circle())
        .animation(.snappy(duration: 0.16), value: isMuted)
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
    func sectionStyle(tintOpacity: Double) -> some View {
        padding(AppConstants.Layout.sectionPadding)
            .background(
                RoundedRectangle(cornerRadius: AppConstants.Layout.cornerRadius, style: .continuous)
                    .fill(.thinMaterial.opacity(tintOpacity))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppConstants.Layout.cornerRadius, style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 1)
                    )
            )
    }
}
