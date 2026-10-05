import SwiftUI

struct HelperProcessDiscoveryView: View {
    let apps: [MixerAppItem]
    let selectedAppID: MixerAppItem.ID?
    let candidates: [HelperProcessCandidate]
    let message: String?
    let isScanning: Bool
    let isAutoDetectRunning: Bool
    let autoDetectProgressText: String?
    let probeResultsByPID: [Int32: ProcessTapTestResult]
    let probeProgressByPID: [Int32: ProcessTapDiagnosticProgress]
    let runningProbePID: Int32?
    let advancedTarget: AdvancedProcessTapTarget?
    let selectApp: (MixerAppItem.ID) -> Void
    let scanHelpers: () -> Void
    let autoDetectHelper: () -> Void
    let probeCandidate: (Int32) -> Void
    let useCandidateAsAdvancedTarget: (Int32) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 15)

                    Text("Helper Process Discovery")
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

                    if isScanning || isAutoDetectRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.58)
                            .frame(width: 12, height: 12)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Helper Process Discovery"))
            .accessibilityValue(Text(disclosureSpokenValue))

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
        .animation(.snappy(duration: 0.16), value: isScanning)
        .animation(.snappy(duration: 0.16), value: isAutoDetectRunning)
        .animation(.snappy(duration: 0.16), value: candidates)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                appPicker

                Button {
                    scanHelpers()
                } label: {
                    Label(isScanning ? "Scanning" : "Scan Helpers", systemImage: isScanning ? "hourglass" : "magnifyingglass")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .disabled(isBusy || selectedAppID == nil)
                .opacity(isBusy || selectedAppID == nil ? 0.48 : 1)
                .accessibilityHint(Text("Lists helper processes related to the selected app"))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.accentColor.opacity(0.17), lineWidth: 1)
                        )
                )
            }

            if candidates.contains(where: \.isTapEligible) {
                autoDetectButton
            }

            if let message {
                Text(message)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(messageTint)
                    .lineLimit(2)
            }

            if let advancedTarget {
                selectedAdvancedTargetLine(advancedTarget)
            }

            if !candidates.isEmpty {
                candidateList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var autoDetectButton: some View {
        HStack(spacing: 8) {
            Button {
                autoDetectHelper()
            } label: {
                Label(
                    isAutoDetectRunning ? "Finding" : "Find audio helper",
                    systemImage: isAutoDetectRunning ? "waveform.path.ecg" : "scope"
                )
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .opacity(isBusy ? 0.48 : 1)
            .accessibilityHint(Text("Probes each eligible helper and selects the one producing audio as the Advanced target"))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.blue.opacity(0.1))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.blue.opacity(0.16), lineWidth: 1)
                    )
            )

            if isAutoDetectRunning {
                // Decorative spinner; the progress text next to it carries the state.
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.58)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)

                Text(autoDetectProgressText ?? "Testing")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var candidateList: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 5) {
                ForEach(candidates) { candidate in
                    candidateRow(
                        candidate,
                        result: probeResultsByPID[candidate.id],
                        progress: probeProgressByPID[candidate.id]
                    )
                }
            }
            .padding(.trailing, 2)
        }
        .scrollIndicators(.automatic)
        .frame(height: candidateListHeight)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.035))
        )
    }

    private var appPicker: some View {
        Menu {
            if apps.isEmpty {
                Text("No visible apps")
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
        .disabled(isBusy || apps.isEmpty)
        .accessibilityLabel(Text("Helper discovery app"))
        .accessibilityValue(Text(selectedAppSpokenValue))
    }

    private func candidateRow(
        _ candidate: HelperProcessCandidate,
        result: ProcessTapTestResult?,
        progress: ProcessTapDiagnosticProgress?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Name, eligibility, and the PID line below are summarized in the row's
                // accessibility label, so they are hidden individually to avoid repetition.
                Text(candidate.process.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                Text(candidate.eligibilityLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(candidate.isTapEligible ? Color.green : Color.orange)
                    .accessibilityHidden(true)

                if candidate.isTapEligible {
                    Button {
                        probeCandidate(candidate.id)
                    } label: {
                        Text(runningProbePID == candidate.id ? "Probing" : "Probe")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .opacity(!isBusy ? 1 : 0.55)
                    .help("Listen briefly for audio callbacks from this helper process")
                    .accessibilityLabel(Text(probeButtonSpokenLabel(candidate)))
                    .accessibilityHint(Text("Listens briefly for audio callbacks from this helper process"))

                    Button {
                        useCandidateAsAdvancedTarget(candidate.id)
                    } label: {
                        Text(isAdvancedTarget(candidate) ? "Target" : "Use")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.blue.opacity(isAdvancedTarget(candidate) ? 0.18 : 0.11))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy || isAdvancedTarget(candidate))
                    .opacity(!isBusy ? 1 : 0.55)
                    .help("Use this helper PID as the Advanced Process Tap Test target")
                    .accessibilityLabel(Text(useButtonSpokenLabel(candidate)))
                }
            }

            HStack(spacing: 7) {
                Text("PID \(candidate.process.processIdentifier)")

                if let parentProcessIdentifier = candidate.process.parentProcessIdentifier {
                    Text("PPID \(parentProcessIdentifier)")
                } else {
                    Text("PPID -")
                }

                Text(candidate.relation.label)

                Spacer(minLength: 0)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)

            if let reason = candidate.eligibility.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.72))
                    .lineLimit(1)
            }

            if let result {
                probeResultLine(result, progress: progress)
            } else if runningProbePID == candidate.id, let progress {
                probeProgressLine(progress)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(candidate.isTapEligible ? Color.green.opacity(0.07) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(candidate.isTapEligible ? Color.green.opacity(0.12) : Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        // One labelled group per candidate. `.contain` (not `.combine`) keeps the Probe/Use
        // buttons individually actionable inside the group.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(candidateSpokenSummary(candidate)))
    }

    private func probeResultLine(
        _ result: ProcessTapTestResult,
        progress: ProcessTapDiagnosticProgress?
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: result.severity == .warning ? "exclamationmark.triangle.fill" : "waveform")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(result.severity == .warning ? Color.orange : Color.green)
                .frame(width: 11)

            Text(result.message)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let progress {
                compactMetrics(progress)
            } else if let detail = result.detail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(probeResultSpokenLabel(result, progress: progress)))
    }

    private func probeProgressLine(_ progress: ProcessTapDiagnosticProgress) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.55)
                .frame(width: 11, height: 11)

            Text("Listening")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            compactMetrics(progress)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Listening: \(metricsSpokenText(progress))"))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func compactMetrics(_ progress: ProcessTapDiagnosticProgress) -> some View {
        HStack(spacing: 6) {
            Text("\(progress.callbackCount) cb")
            Text("P \(formattedLevel(progress.peakLevel))")
            Text("R \(formattedLevel(progress.rmsLevel))")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(progress.audioDetected ? Color.green.opacity(0.82) : Color.secondary.opacity(0.7))
    }

    private func selectedAdvancedTargetLine(_ target: AdvancedProcessTapTarget) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            Text("Advanced target: \(target.displayName)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(target.target.processIdentifier.map { "PID \($0)" } ?? "PID -")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.06))
        )
        .accessibilityElement(children: .combine)
    }

    private var selectedAppName: String {
        guard let selectedAppID,
              let app = apps.first(where: { $0.id == selectedAppID }) else {
            return "Select app"
        }

        return app.name
    }

    private var messageTint: Color {
        candidates.contains(where: \.isTapEligible) ? .green.opacity(0.82) : .secondary.opacity(0.72)
    }

    private var candidateListHeight: CGFloat {
        let rowHeight: CGFloat = 58
        let spacing: CGFloat = 5
        let contentHeight = CGFloat(candidates.count) * rowHeight +
            CGFloat(max(0, candidates.count - 1)) * spacing

        return min(190, max(rowHeight, contentHeight))
    }

    private var isBusy: Bool {
        isScanning || runningProbePID != nil || isAutoDetectRunning
    }

    private func formattedLevel(_ level: Double) -> String {
        String(format: "%.3f", level)
    }

    private func isAdvancedTarget(_ candidate: HelperProcessCandidate) -> Bool {
        advancedTarget?.target.processIdentifier == candidate.process.processIdentifier
    }

    private var disclosureSpokenValue: String {
        let state = isExpanded ? "Expanded" : "Collapsed"
        return isScanning || isAutoDetectRunning ? "\(state), working" : state
    }

    private var selectedAppSpokenValue: String {
        guard let selectedAppID,
              let app = apps.first(where: { $0.id == selectedAppID }) else {
            return "None selected"
        }

        return app.name
    }

    private func candidateSpokenSummary(_ candidate: HelperProcessCandidate) -> String {
        let parentText: String = candidate.process.parentProcessIdentifier.map { "parent PID \($0)" } ?? "no parent PID"
        var parts: [String] = [
            candidate.process.name,
            "PID \(candidate.process.processIdentifier)",
            parentText,
            "relation \(candidate.relation.label)",
            candidate.eligibilityLabel
        ]

        if isAdvancedTarget(candidate) {
            parts.append("current Advanced target")
        }

        return parts.joined(separator: ", ")
    }

    private func probeButtonSpokenLabel(_ candidate: HelperProcessCandidate) -> String {
        let pid = candidate.process.processIdentifier
        return runningProbePID == candidate.id ? "Probing helper PID \(pid)" : "Probe helper PID \(pid)"
    }

    private func useButtonSpokenLabel(_ candidate: HelperProcessCandidate) -> String {
        let pid = candidate.process.processIdentifier
        return isAdvancedTarget(candidate) ? "PID \(pid) is the Advanced target" : "Use PID \(pid) as Advanced target"
    }

    private func probeResultSpokenLabel(
        _ result: ProcessTapTestResult,
        progress: ProcessTapDiagnosticProgress?
    ) -> String {
        let prefix = result.severity == .warning ? "Probe warning" : "Probe result"
        var text = "\(prefix): \(result.message)"

        if let progress {
            text += ", " + metricsSpokenText(progress)
        } else if let detail = result.detail {
            text += ", " + detail
        }

        return text
    }

    private func metricsSpokenText(_ progress: ProcessTapDiagnosticProgress) -> String {
        "\(progress.callbackCount) callbacks, peak \(spokenPercent(progress.peakLevel)), RMS \(spokenPercent(progress.rmsLevel))"
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

private extension HelperProcessCandidate {
    var eligibilityLabel: String {
        isTapEligible ? "Eligible" : "Unavailable"
    }
}
