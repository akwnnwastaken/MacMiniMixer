import AppKit
import SwiftUI

struct MixerPanelView: View {
    @ObservedObject var viewModel: MixerViewModel
    @State private var isShowingOutputDevices = false
    @State private var isEditingSystemOutputSlider = false
    @State private var isShowingAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.panelSpacing) {
            VStack(alignment: .leading, spacing: AppConstants.Layout.sectionSpacing) {
                header

                if viewModel.isProcessTapLiveControlActive {
                    activeLiveControlBanner
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

            advancedSection

            quitButton
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
            viewModel.refreshApplications()
            viewModel.refreshOutputDevices()
            viewModel.refreshSystemOutputVolume()
        }
        .task {
            await runSystemVolumeRefreshLoop()
        }
        .task {
            await runOutputDeviceRefreshLoop()
        }
        .onDisappear {
            viewModel.stopTwoAppReadinessForPanelClose()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(AppConstants.appTitle)
                    .font(.headline.weight(.semibold))
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
            .foregroundStyle(isShowingOutputDevices ? .blue : .secondary)
            .background(
                Circle()
                    .fill(.thinMaterial.opacity(isShowingOutputDevices ? 0.95 : 0.55))
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(isShowingOutputDevices ? 0.22 : 0.12), lineWidth: 1)
                    )
            )
            .help("Output devices")
        }
        .padding(.horizontal, 3)
        .padding(.top, 1)
    }

    private var activeLiveControlBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18)

            Text("Real control: \(viewModel.activeLiveControlAppName ?? "Active")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 6)

            Button {
                viewModel.stopProcessTapLiveControl()
            } label: {
                Text("Stop")
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
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.orange.opacity(0.24), lineWidth: 1)
                )
        )
    }

    private var systemOutputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("System Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(viewModel.selectedOutputDeviceName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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

                volumeText(viewModel.systemVolume)
            }
        }
        .sectionStyle(tintOpacity: 0.32)
    }

    private var appMixerSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Applications")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle(
                    "Show all",
                    isOn: Binding(
                        get: { viewModel.showAllApps },
                        set: { viewModel.setShowAllApps($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .help("Show all regular running apps")
            }
            .padding(.horizontal, 2)

            experimentalRealAppControlStrip

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

    private var experimentalRealAppControlStrip: some View {
        HStack(spacing: 7) {
            Toggle(
                "Real app control",
                isOn: Binding(
                    get: { viewModel.isExperimentalRealAppControlEnabled },
                    set: { viewModel.setExperimentalRealAppControlEnabled($0) }
                )
            )
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.caption.weight(.semibold))
            .foregroundStyle(viewModel.isExperimentalRealAppControlEnabled ? .orange : .secondary)

            Text("Exp")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange.opacity(0.9))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(viewModel.isExperimentalRealAppControlEnabled ? 0.1 : 0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.orange.opacity(viewModel.isExperimentalRealAppControlEnabled ? 0.22 : 0.08), lineWidth: 1)
                )
        )
        .help("When enabled, adjusting one eligible app row starts real experimental control for that app.")
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: isShowingAdvanced ? 8 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.16)) {
                    isShowingAdvanced.toggle()
                }
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
                        snapshot: viewModel.twoAppReadinessSnapshot,
                        result: viewModel.twoAppReadinessResult,
                        isRunning: viewModel.isTwoAppReadinessRunning,
                        selectAppA: viewModel.selectTwoAppReadinessAppA,
                        selectAppB: viewModel.selectTwoAppReadinessAppB,
                        selectGain: viewModel.selectTwoAppReadinessGain,
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

    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit MacMiniMixer", systemImage: "power")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(.caption.weight(.medium))
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(.quaternary.opacity(0.45))
        )
        .contentShape(Capsule(style: .continuous))
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

            Text(message.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
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
