import SwiftUI

struct MixerAppRowView: View {
    let app: MixerAppItem
    let isExperimentalControlActive: Bool
    let isExperimentalControlResolving: Bool
    /// A Product Real start/stop transition is in flight for this row. While true the accessory
    /// shows a non-interactive "working" badge instead of the tappable Real button, so the user
    /// cannot spam the toggle mid-operation (the view model also ignores toggles while pending).
    let isExperimentalControlPending: Bool
    let toggleExperimentalControl: () -> Void
    @Binding var volume: Double
    @Binding var isMuted: Bool

    var body: some View {
        HStack(spacing: AppConstants.Layout.rowSpacing) {
            Button {
                isMuted.toggle()
            } label: {
                appIcon
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(Text(isMuted ? "Unmute \(app.name)" : "Mute \(app.name)"))

            Text(app.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(width: AppConstants.Layout.appNameWidth, alignment: .leading)

            Slider(value: $volume, in: AppConstants.volumeRange, step: 1)
                .disabled(isMuted || isExperimentalControlResolving)
                .accessibilityLabel(Text("\(app.name) volume"))
                .accessibilityValue(Text("\(Int(volume.rounded())) percent"))
                .accessibilityHint(Text(isExperimentalControlResolving
                    ? "Finding the audio helper for this app"
                    : isExperimentalControlActive
                        ? "Adjusts real audio level for this app"
                        : "Adjusts the volume for this app"))

            Text("\(Int(volume.rounded()))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isMuted ? .tertiary : .secondary)
                .frame(width: AppConstants.Layout.volumeValueWidth, alignment: .trailing)

            experimentalControlAccessory
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowBackground)
        .opacity(isMuted ? 0.68 : 1)
        .animation(.snappy(duration: 0.16), value: isMuted)
        .animation(.snappy(duration: 0.16), value: isExperimentalControlActive)
        .animation(.snappy(duration: 0.16), value: isExperimentalControlResolving)
        .animation(.snappy(duration: 0.16), value: isExperimentalControlPending)
    }

    private var appIcon: some View {
        Color.clear
            .frame(width: AppConstants.Layout.rowIconSize, height: AppConstants.Layout.rowIconSize)
            .background {
                iconBubble
            }
            .overlay {
                appIconImage
                    .frame(
                        width: iconArtworkSize,
                        height: iconArtworkSize,
                        alignment: .center
                    )
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if isMuted {
                    mutedBadge
                }
            }
            .contentShape(Circle())
    }

    private var iconBubble: some View {
        ZStack {
            Circle()
                .fill(isMuted ? Color.red.opacity(0.14) : Color.white.opacity(0.12))
        }
        .frame(width: AppConstants.Layout.rowIconSize, height: AppConstants.Layout.rowIconSize)
    }

    private var mutedBadge: some View {
        ZStack {
            Circle()
                .fill(Color.red)

            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: AppConstants.Layout.rowIconMuteBadgeSize, height: AppConstants.Layout.rowIconMuteBadgeSize)
        .offset(x: 1, y: 1)
        .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder
    private var appIconImage: some View {
        switch app.icon {
        case .systemSymbol(let systemName):
            Image(systemName: systemName)
                .font(.system(size: AppConstants.Layout.rowIconSymbolSize, weight: .semibold))
                .foregroundStyle(isMuted ? .tertiary : .secondary)

        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .saturation(isMuted ? 0.15 : 1)
                .opacity(isMuted ? 0.65 : 1)
        }
    }

    private var iconArtworkSize: CGFloat {
        switch app.icon {
        case .systemSymbol:
            AppConstants.Layout.rowIconSymbolFrameSize
        case .image:
            AppConstants.Layout.rowIconImageArtworkSize
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: AppConstants.Layout.rowCornerRadius, style: .continuous)
            .fill(rowBackgroundFill)
            .overlay(
                RoundedRectangle(cornerRadius: AppConstants.Layout.rowCornerRadius, style: .continuous)
                    .stroke(rowStrokeColor, lineWidth: 1)
            )
    }

    private var rowBackgroundFill: Color {
        if isExperimentalControlActive {
            return Color.orange.opacity(0.1)
        }

        return isMuted ? Color.red.opacity(0.065) : Color.white.opacity(0.045)
    }

    private var rowStrokeColor: Color {
        if isExperimentalControlActive {
            return Color.orange.opacity(0.26)
        }

        return isMuted ? Color.red.opacity(0.16) : Color.white.opacity(0.075)
    }

    @ViewBuilder
    private var experimentalControlAccessory: some View {
        if isExperimentalControlPending {
            pendingBadge
        } else if isExperimentalControlActive {
            realControlBadge
        } else if isExperimentalControlResolving {
            resolvingBadge
        } else {
            Color.clear
                .frame(width: AppConstants.Layout.rowLiveButtonSize, height: AppConstants.Layout.rowLiveButtonSize)
        }
    }

    /// Non-interactive badge shown while a Product Real start/stop for this row is in flight.
    private var pendingBadge: some View {
        ProgressView()
            .controlSize(.mini)
            .scaleEffect(0.55)
            .frame(width: AppConstants.Layout.rowLiveButtonSize + 6, height: AppConstants.Layout.rowLiveButtonSize)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(0.1))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                    )
            )
            .help("Real app control is changing for \(app.name)…")
            .accessibilityLabel(Text("Real app control is changing for \(app.name)"))
    }

    private var realControlBadge: some View {
        Button(action: toggleExperimentalControl) {
            Text("Real")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: AppConstants.Layout.rowLiveButtonSize + 6, height: AppConstants.Layout.rowLiveButtonSize)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.orange.opacity(0.14))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .help("Stop experimental real app control for \(app.name)")
        .accessibilityLabel(Text("Stop Real App Control"))
    }

    private var resolvingBadge: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.55)
                .frame(width: 10, height: 10)

            Text("Resolving")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.orange.opacity(0.88))
        }
        .frame(width: AppConstants.Layout.rowLiveButtonSize + 36, height: AppConstants.Layout.rowLiveButtonSize)
        .background(
            Capsule(style: .continuous)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
        )
        .help("Finding the audio helper for \(app.name)")
        .accessibilityLabel(Text("Resolving real app control for \(app.name)"))
    }
}
