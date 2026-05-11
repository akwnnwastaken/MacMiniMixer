import SwiftUI

struct HelperProcessDiscoveryView: View {
    let apps: [MixerAppItem]
    let selectedAppID: MixerAppItem.ID?
    let candidates: [HelperProcessCandidate]
    let message: String?
    let isScanning: Bool
    let probeResultsByPID: [Int32: ProcessTapTestResult]
    let probeProgressByPID: [Int32: ProcessTapDiagnosticProgress]
    let runningProbePID: Int32?
    let selectApp: (MixerAppItem.ID) -> Void
    let scanHelpers: () -> Void
    let probeCandidate: (Int32) -> Void

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

                    if isScanning {
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
                .disabled(isScanning || runningProbePID != nil || selectedAppID == nil)
                .opacity(isScanning || runningProbePID != nil || selectedAppID == nil ? 0.48 : 1)
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

            if let message {
                Text(message)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(messageTint)
                    .lineLimit(2)
            }

            if !candidates.isEmpty {
                candidateList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
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
        .disabled(isScanning || runningProbePID != nil || apps.isEmpty)
    }

    private func candidateRow(
        _ candidate: HelperProcessCandidate,
        result: ProcessTapTestResult?,
        progress: ProcessTapDiagnosticProgress?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(candidate.process.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(candidate.eligibilityLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(candidate.isTapEligible ? Color.green : Color.orange)

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
                    .disabled(runningProbePID != nil || isScanning)
                    .opacity(runningProbePID == nil && !isScanning ? 1 : 0.55)
                    .help("Listen briefly for audio callbacks from this helper process")
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

    private func formattedLevel(_ level: Double) -> String {
        String(format: "%.3f", level)
    }
}

private extension HelperProcessCandidate {
    var eligibilityLabel: String {
        isTapEligible ? "Eligible" : "Unavailable"
    }
}
