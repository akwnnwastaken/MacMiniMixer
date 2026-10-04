import AppKit
import SwiftUI

struct ProcessTapTestView: View {
    let apps: [MixerAppItem]
    let selectedAppID: MixerAppItem.ID?
    let result: ProcessTapTestResult?
    let progress: ProcessTapDiagnosticProgress?
    let advancedTarget: AdvancedProcessTapTarget?
    let selectedReplayGain: ProcessTapReplayGainOption
    let liveDiagnostics: ProcessTapLiveDiagnostics?
    let isTesting: Bool
    let isLiveControlActive: Bool
    let selectApp: (MixerAppItem.ID) -> Void
    let selectReplayGain: (ProcessTapReplayGainOption) -> Void
    let testProcessTap: () -> Void
    let testMuteBehavior: () -> Void
    let testReplayProbe: () -> Void
    let startLiveControl: () -> Void
    let stopLiveControl: () -> Void
    let clearAdvancedTarget: () -> Void
    let showsHeader: Bool

    @State private var isExpanded = false

    init(
        apps: [MixerAppItem],
        selectedAppID: MixerAppItem.ID?,
        result: ProcessTapTestResult?,
        progress: ProcessTapDiagnosticProgress?,
        advancedTarget: AdvancedProcessTapTarget?,
        selectedReplayGain: ProcessTapReplayGainOption,
        liveDiagnostics: ProcessTapLiveDiagnostics?,
        isTesting: Bool,
        isLiveControlActive: Bool,
        selectApp: @escaping (MixerAppItem.ID) -> Void,
        selectReplayGain: @escaping (ProcessTapReplayGainOption) -> Void,
        testProcessTap: @escaping () -> Void,
        testMuteBehavior: @escaping () -> Void,
        testReplayProbe: @escaping () -> Void,
        startLiveControl: @escaping () -> Void,
        stopLiveControl: @escaping () -> Void,
        clearAdvancedTarget: @escaping () -> Void,
        showsHeader: Bool = true
    ) {
        self.apps = apps
        self.selectedAppID = selectedAppID
        self.result = result
        self.progress = progress
        self.advancedTarget = advancedTarget
        self.selectedReplayGain = selectedReplayGain
        self.liveDiagnostics = liveDiagnostics
        self.isTesting = isTesting
        self.isLiveControlActive = isLiveControlActive
        self.selectApp = selectApp
        self.selectReplayGain = selectReplayGain
        self.testProcessTap = testProcessTap
        self.testMuteBehavior = testMuteBehavior
        self.testReplayProbe = testReplayProbe
        self.startLiveControl = startLiveControl
        self.stopLiveControl = stopLiveControl
        self.clearAdvancedTarget = clearAdvancedTarget
        self.showsHeader = showsHeader
    }

    var body: some View {
        if showsHeader {
            collapsibleBody
        } else {
            content
                .animation(.snappy(duration: 0.16), value: result)
        }
    }

    private var collapsibleBody: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Text("Process Tap Test")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("Experimental")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.quaternary.opacity(0.35))
                        )

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Process Tap Test, experimental"))
            .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))

            if isExpanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(AppConstants.Layout.sectionPadding)
        .background(
            RoundedRectangle(cornerRadius: AppConstants.Layout.cornerRadius, style: .continuous)
                .fill(.thinMaterial.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: AppConstants.Layout.cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
        )
        .animation(.snappy(duration: 0.16), value: result)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                appPicker

                Button {
                    testProcessTap()
                } label: {
                    Label(testButtonTitle, systemImage: isTesting ? "hourglass" : "play.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .disabled(controlsDisabled || (apps.isEmpty && advancedTarget == nil))
                .accessibilityHint(Text(testButtonSpokenHint))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                        )
                )
            }

            if let advancedTarget {
                advancedTargetRow(advancedTarget)
            }

            HStack(spacing: 8) {
                Label("Mute Probe may briefly mute the selected app.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.88))
                    .lineLimit(2)

                Spacer(minLength: 0)

                Button {
                    testMuteBehavior()
                } label: {
                    Label("Mute Probe", systemImage: "speaker.slash.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .disabled(visibleAppControlsDisabled)
                .opacity(visibleAppControlsDisabled ? 0.52 : 1)
                .accessibilityHint(Text("Briefly mutes the selected app to test Process Tap mute behavior"))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(.orange.opacity(0.13))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(.orange.opacity(0.2), lineWidth: 1)
                        )
                )
            }

            HStack(spacing: 8) {
                Label(replayWarningText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.82))
                    .lineLimit(2)

                Spacer(minLength: 0)

                Button {
                    testReplayProbe()
                } label: {
                    Label("Replay Probe", systemImage: "speaker.wave.2.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .disabled(replayControlsDisabled)
                .opacity(replayControlsDisabled ? 0.52 : 1)
                .accessibilityHint(Text(replayProbeSpokenHint))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(.red.opacity(0.11))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(.red.opacity(0.18), lineWidth: 1)
                        )
                )
            }

            HStack(spacing: 7) {
                // Visual caption only; the picker itself carries the "Replay gain" label.
                Text("Replay gain")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                replayGainPicker
            }

            liveControlRow

            if (isTesting || isLiveControlActive), let progress {
                levelMeter(progress)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let liveDiagnostics {
                liveDiagnosticsLine(liveDiagnostics)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let result {
                resultLine(result)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var appPicker: some View {
        Menu {
            if apps.isEmpty {
                Text("No apps available")
            } else {
                ForEach(apps) { app in
                    Button {
                        selectApp(app.id)
                    } label: {
                        if app.id == selectedAppID {
                            Label(app.name, systemImage: "checkmark")
                        } else {
                            Text(app.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedAppName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(apps.isEmpty || controlsDisabled)
        .accessibilityLabel(Text("Process Tap Test app"))
        .accessibilityValue(Text(selectedAppSpokenValue))
    }

    private var liveControlRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                "Experimental: captures selected app audio, suppresses original output, and replays processed audio.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption2)
            .foregroundStyle(.purple.opacity(0.82))
            .lineLimit(2)

            HStack(spacing: 8) {
                if isLiveControlActive {
                    Label("Live active", systemImage: "record.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("Live control is active"))
                } else {
                    Label("Live control", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Live control is not active"))
                }

                Spacer(minLength: 0)

                if isLiveControlActive {
                    Button {
                        stopLiveControl()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Stop live control"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.red.opacity(0.14))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(.red.opacity(0.22), lineWidth: 1)
                            )
                    )
                } else {
                    Button {
                        startLiveControl()
                    } label: {
                        Label("Start Live Control", systemImage: "play.circle.fill")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(visibleAppControlsDisabled)
                    .opacity(visibleAppControlsDisabled ? 0.52 : 1)
                    .accessibilityHint(Text("Experimental. Replays the selected app's audio at the replay gain until stopped"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.purple.opacity(isTesting || apps.isEmpty ? 0.06 : 0.13))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(.purple.opacity(isTesting || apps.isEmpty ? 0.08 : 0.2), lineWidth: 1)
                            )
                    )
                }
            }
        }
    }

    private var replayGainPicker: some View {
        Menu {
            ForEach(ProcessTapReplayGainOption.options) { gain in
                Button {
                    selectReplayGain(gain)
                } label: {
                    if gain == selectedReplayGain {
                        Label(gain.percentLabel, systemImage: "checkmark")
                    } else {
                        Text(gain.percentLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selectedReplayGain.percentLabel)
                    .font(.caption2.monospacedDigit().weight(.semibold))

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(replayControlsDisabled)
        .accessibilityLabel(Text("Replay gain"))
        .accessibilityValue(Text(selectedReplayGain.percentLabel))
        .accessibilityHint(Text("Gain used by Replay Probe and Live Control"))
    }

    private var controlsDisabled: Bool {
        isTesting || isLiveControlActive
    }

    private var visibleAppControlsDisabled: Bool {
        controlsDisabled || apps.isEmpty || advancedTarget != nil
    }

    private var replayControlsDisabled: Bool {
        controlsDisabled || (apps.isEmpty && advancedTarget == nil)
    }

    private var testButtonTitle: String {
        if isTesting {
            return "Testing"
        }

        return advancedTarget == nil ? "Test" : "Test Target"
    }

    private var replayWarningText: String {
        advancedTarget == nil
            ? "Replay Probe may briefly mute/replay selected app audio."
            : "Replay Probe may briefly mute/replay selected helper audio."
    }

    private var selectedAppName: String {
        apps.first { $0.id == selectedAppID }?.name ?? "Select app"
    }

    private var selectedAppSpokenValue: String {
        apps.first { $0.id == selectedAppID }?.name ?? "None selected"
    }

    private var testButtonSpokenHint: String {
        advancedTarget == nil
            ? "Runs a short Process Tap diagnostic on the selected app"
            : "Runs a short Process Tap diagnostic on the Advanced target"
    }

    private var replayProbeSpokenHint: String {
        advancedTarget == nil
            ? "Briefly mutes the selected app and replays its captured audio at the replay gain"
            : "Briefly mutes the selected helper and replays its captured audio at the replay gain"
    }

    private func advancedTargetRow(_ target: AdvancedProcessTapTarget) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "scope")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 13)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Advanced target: \(target.displayName)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(target.detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            Button {
                clearAdvancedTarget()
            } label: {
                Text("Clear")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.055))
                    )
            }
            .buttonStyle(.plain)
            .disabled(controlsDisabled)
            .accessibilityLabel(Text("Clear Advanced target"))
            .accessibilityHint(Text("Tests the selected app instead of the helper process"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.blue.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private func levelMeter(_ progress: ProcessTapDiagnosticProgress) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Live level")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text("\(progress.callbackCount) callbacks")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.55),
                                    progress.audioDetected ? .green.opacity(0.75) : Color.accentColor.opacity(0.75)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * meterFillFraction(for: progress))
                }
            }
            .frame(height: 7)
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                Text("Peak \(formattedLevel(progress.peakLevel))")
                Text("RMS \(formattedLevel(progress.rmsLevel))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
        )
        .animation(.linear(duration: 0.08), value: progress)
        // One meter element: the decorative bar is hidden and the visible metric texts are
        // replaced by a spoken value ("Peak 42 percent, RMS 10 percent, ...").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Live level"))
        .accessibilityValue(Text(levelMeterSpokenValue(progress)))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func resultLine(_ result: ProcessTapTestResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: result.severity.iconSystemName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(result.severity.tint)
                    .frame(width: 13)
                    .accessibilityHidden(true)

                Text(result.message)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityLabel(Text("\(result.severity.spokenName): \(result.message)"))

                Spacer(minLength: 0)
            }

            if let detail = result.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .padding(.leading, 20)
            }

            if result.suggestsSystemAudioRecordingSettings {
                openSystemSettingsButton
                    .padding(.leading, 20)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(result.severity.tint.opacity(0.08))
        )
    }

    private var openSystemSettingsButton: some View {
        Button {
            if let url = ProcessTapPermissionMessage.systemAudioRecordingSettingsURL {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label("Open System Settings", systemImage: "gearshape")
                .font(.caption2.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
        .help("Open Privacy & Security so you can enable System Audio Recording")
        .accessibilityHint(Text("Opens Privacy and Security settings to grant System Audio Recording"))
    }

    private func liveDiagnosticsLine(_ diagnostics: ProcessTapLiveDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text("Queued \(diagnostics.enqueuedBufferCount)")
                Text("Drops \(diagnostics.droppedBufferCount)")
                Text("Fail \(diagnostics.totalFailureCount)")
                Spacer(minLength: 0)
                Text(diagnostics.selectedGain.percentLabel)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(liveDiagnosticsSpokenLabel(diagnostics)))

            // Neutral waiting/no-audio state: the tapped app has not produced real audio yet, so a
            // drained queue is idle, not starvation. Shown instead of misreading it as a problem.
            if let realAudioStatusText = diagnostics.realAudioStatusText {
                Text(realAudioStatusText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(Text(realAudioStatusText))
            }

            // Second line: diagnostic-only jitter/starvation signals (drops/fail do not catch
            // these). Reliable live visibility instead of the truncation-prone stop-result detail.
            Text(diagnostics.timingSummaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(Text("Max callback gap \(String(format: "%.1f", diagnostics.maxCallbackGapMilliseconds)) milliseconds, late callbacks \(diagnostics.lateCallbackCount), output starvation \(diagnostics.outputStarvationCount)"))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.purple.opacity(0.06))
        )
    }

    private func meterFillFraction(for progress: ProcessTapDiagnosticProgress) -> CGFloat {
        let displayLevel = max(progress.peakLevel, progress.rmsLevel * 2.5)
        return CGFloat(min(1, max(0, displayLevel)))
    }

    private func formattedLevel(_ level: Double) -> String {
        String(format: "%.3f", level)
    }

    private func levelMeterSpokenValue(_ progress: ProcessTapDiagnosticProgress) -> String {
        let audioText = progress.audioDetected ? "audio detected" : "no audio detected"
        return "Peak \(spokenPercent(progress.peakLevel)), RMS \(spokenPercent(progress.rmsLevel)), \(progress.callbackCount) callbacks, \(audioText)"
    }

    private func liveDiagnosticsSpokenLabel(_ diagnostics: ProcessTapLiveDiagnostics) -> String {
        "\(diagnostics.enqueuedBufferCount) buffers queued, \(diagnostics.droppedBufferCount) drops, \(diagnostics.totalFailureCount) failures, gain \(diagnostics.selectedGain.percentLabel)"
    }

    /// Spoken form of a 0...1 linear level, e.g. "42 percent". Small non-zero levels read as
    /// "less than 1 percent" instead of rounding down to zero.
    private func spokenPercent(_ level: Double) -> String {
        let percent = min(max(level, 0), 1) * 100
        if percent > 0, percent < 1 {
            return "less than 1 percent"
        }

        return "\(Int(percent.rounded())) percent"
    }
}

private extension ProcessTapTestResult.Severity {
    var iconSystemName: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info:
            return .blue
        case .warning:
            return .orange
        }
    }

    /// Spoken severity for result lines, replacing the hidden icon.
    var spokenName: String {
        switch self {
        case .info:
            return "Info"
        case .warning:
            return "Warning"
        }
    }
}
