import SwiftUI

struct TwoAppReadinessTestView: View {
    let apps: [MixerAppItem]
    let selectedAppAID: MixerAppItem.ID?
    let selectedAppBID: MixerAppItem.ID?
    let eligibilityByAppID: [MixerAppItem.ID: ProcessTapProcessEligibility]
    let selectedGain: ProcessTapReplayGainOption
    let snapshot: ProcessTapTwoAppReadinessSnapshot
    let result: ProcessTapTwoAppReadinessResult?
    let isRunning: Bool
    let selectAppA: (MixerAppItem.ID) -> Void
    let selectAppB: (MixerAppItem.ID) -> Void
    let selectGain: (ProcessTapReplayGainOption) -> Void
    let startTest: () -> Void
    let stopAll: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 15)

                    Text("Two-App Readiness")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("Advanced")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.quaternary.opacity(0.35))
                        )

                    Spacer()

                    if isRunning {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
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
        .animation(.snappy(duration: 0.16), value: isRunning)
        .animation(.snappy(duration: 0.16), value: result)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                appPicker(
                    title: "App A",
                    selectedAppID: selectedAppAID,
                    excludedAppID: selectedAppBID,
                    selectApp: selectAppA
                )

                appPicker(
                    title: "App B",
                    selectedAppID: selectedAppBID,
                    excludedAppID: selectedAppAID,
                    selectApp: selectAppB
                )
            }

            if let readinessIssue {
                Text(readinessIssue)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text("Gain")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                gainPicker

                Spacer(minLength: 0)

                if isRunning {
                    Button {
                        stopAll()
                    } label: {
                        Label("Stop All", systemImage: "stop.fill")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
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
                        startTest()
                    } label: {
                        Label("Start 2-App Test", systemImage: "play.fill")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.48)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.orange.opacity(canStart ? 0.13 : 0.06))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(.orange.opacity(canStart ? 0.2 : 0.08), lineWidth: 1)
                            )
                    )
                }
            }

            if isRunning || !snapshot.sessions.isEmpty {
                VStack(spacing: 5) {
                    ForEach(snapshot.sessions) { session in
                        diagnosticRow(session)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let result {
                resultLine(result)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func appPicker(
        title: String,
        selectedAppID: MixerAppItem.ID?,
        excludedAppID: MixerAppItem.ID?,
        selectApp: @escaping (MixerAppItem.ID) -> Void
    ) -> some View {
        Menu {
            if eligibleApps.isEmpty {
                Text("No tap-eligible apps")
            } else {
                ForEach(eligibleApps) { app in
                    Button {
                        selectApp(app.id)
                    } label: {
                        if app.id == selectedAppID {
                            Label(app.name, systemImage: "checkmark")
                        } else {
                            Text(app.name)
                        }
                    }
                    .disabled(app.id == excludedAppID)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)

                Text(appName(for: selectedAppID))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
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
        .disabled(isRunning || eligibleApps.isEmpty)
    }

    private var gainPicker: some View {
        Menu {
            ForEach(ProcessTapReplayGainOption.options) { gain in
                Button {
                    selectGain(gain)
                } label: {
                    if gain == selectedGain {
                        Label(gain.percentLabel, systemImage: "checkmark")
                    } else {
                        Text(gain.percentLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selectedGain.percentLabel)
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
        .disabled(isRunning)
    }

    private func diagnosticRow(_ session: ProcessTapTwoAppReadinessSessionSnapshot) -> some View {
        let diagnostics = session.diagnostics

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(session.slot.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)

                Text(session.appName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(session.phase.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(session.phase.tint)
            }

            HStack(spacing: 7) {
                Text("\(diagnostics?.callbackCount ?? 0) cb")
                Text("P \(formattedLevel(diagnostics?.peakLevel ?? 0))")
                Text("R \(formattedLevel(diagnostics?.rmsLevel ?? 0))")
                Text("Q \(diagnostics?.enqueuedBufferCount ?? 0)")
                Text("D \(diagnostics?.droppedBufferCount ?? 0)")
                Text("F \(diagnostics?.totalFailureCount ?? 0)")
                Spacer(minLength: 0)
                Text(session.selectedGain.percentLabel)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)

            if let message = session.message, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(session.phase == .failed ? Color.orange : Color.secondary.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.055))
        )
    }

    private func resultLine(_ result: ProcessTapTwoAppReadinessResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: result.severity.iconSystemName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(result.severity.tint)
                    .frame(width: 13)

                Text(result.message)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 0)
            }

            if let detail = result.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(result.severity.tint.opacity(0.08))
        )
    }

    private var eligibleApps: [MixerAppItem] {
        apps.filter { app in
            eligibilityByAppID[app.id]?.isEligible == true
        }
    }

    private var canStart: Bool {
        guard let selectedAppAID,
              let selectedAppBID,
              selectedAppAID != selectedAppBID else {
            return false
        }

        return eligibleApps.contains(where: { $0.id == selectedAppAID }) &&
            eligibleApps.contains(where: { $0.id == selectedAppBID })
    }

    private var readinessIssue: String? {
        guard !isRunning else {
            return nil
        }

        guard eligibleApps.count >= 2 else {
            return "No Core Audio tap-eligible second app found"
        }

        guard let selectedAppAID,
              let selectedAppBID else {
            return "Select two tap-eligible apps"
        }

        if selectedAppAID == selectedAppBID {
            return "Choose two different apps"
        }

        if let reason = eligibilityIssue(for: selectedAppAID) ?? eligibilityIssue(for: selectedAppBID) {
            return reason
        }

        return nil
    }

    private func eligibilityIssue(for appID: MixerAppItem.ID) -> String? {
        guard apps.contains(where: { $0.id == appID }) else {
            return "Selected app is not running"
        }

        guard eligibilityByAppID[appID]?.isEligible == true else {
            return eligibilityByAppID[appID]?.reason ?? "Core Audio process unavailable"
        }

        return nil
    }

    private func appName(for appID: MixerAppItem.ID?) -> String {
        guard let appID,
              let app = apps.first(where: { $0.id == appID }) else {
            return "Select"
        }

        return app.name
    }

    private func formattedLevel(_ level: Double) -> String {
        String(format: "%.3f", level)
    }
}

private extension ProcessTapLiveSessionPhase {
    var label: String {
        switch self {
        case .starting:
            return "Starting"
        case .active:
            return "Active"
        case .stopping:
            return "Stopping"
        case .stopped:
            return "Stopped"
        case .failed:
            return "Failed"
        }
    }

    var tint: Color {
        switch self {
        case .starting, .stopping:
            return .orange
        case .active:
            return .green
        case .stopped:
            return .secondary
        case .failed:
            return .red
        }
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
}
