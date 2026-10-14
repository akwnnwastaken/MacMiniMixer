import SwiftUI

struct MixerAppRowView: View {
    let app: MixerAppItem
    let isOutputActive: Bool
    let isExperimentalControlActive: Bool
    let isExperimentalControlResolving: Bool
    /// A Product Real start/stop transition is in flight for this row. While true the accessory
    /// shows a non-interactive "working" badge instead of the tappable Real button, so the user
    /// cannot spam the toggle mid-operation (the view model also ignores toggles while pending).
    let isExperimentalControlPending: Bool
    let toggleExperimentalControl: () -> Void
    @Binding var volume: Double
    @Binding var isMuted: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isMuted.toggle()
            } label: {
                appIcon
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(Text(isMuted ? "Unmute \(app.name)" : "Mute \(app.name)"))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityValue(Text(isOutputActive ? "Playing audio" : "Not playing"))

                    if isOutputActive {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .transition(.scale.combined(with: .opacity))
                            .help("Playing audio")
                            .accessibilityHidden(true)
                    }

                    Spacer(minLength: 4)

                    experimentalControlAccessory

                    Text("\(Int(volume.rounded()))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(valueStyle)
                        .frame(minWidth: AppConstants.Layout.volumeValueWidth, alignment: .trailing)
                        .accessibilityHidden(true)
                }

                VolumeSlider(
                    value: $volume,
                    scale: VolumeSliderScale(range: AppConstants.appVolumeRange, unity: AppConstants.unityAppVolume),
                    accessibilityLabel: "\(app.name) volume",
                    accessibilityHint: isExperimentalControlResolving
                        ? "Finding the audio helper for this app"
                        : isExperimentalControlActive
                            ? "Adjusts real audio level for this app. Above 100 percent boosts it."
                            : "Adjusts the volume for this app. Above 100 percent boosts it."
                )
                .disabled(isMuted || isExperimentalControlResolving)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: AppConstants.Layout.appRowApproxHeight)
        .background(rowBackground)
        .opacity(isMuted ? 0.72 : 1)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.16), value: isMuted)
        .animation(.snappy(duration: 0.16), value: isHovering)
        .animation(.snappy(duration: 0.16), value: isOutputActive)
        .animation(.snappy(duration: 0.16), value: isExperimentalControlActive)
        .animation(.snappy(duration: 0.16), value: isExperimentalControlResolving)
        .animation(.snappy(duration: 0.16), value: isExperimentalControlPending)
    }

    private var valueStyle: Color {
        if isMuted {
            return Color.secondary.opacity(0.6)
        }

        return volume > AppConstants.unityAppVolume ? .orange : .secondary
    }

    private var appIcon: some View {
        Color.clear
            .frame(width: AppConstants.Layout.rowIconSize, height: AppConstants.Layout.rowIconSize)
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

    private var mutedBadge: some View {
        ZStack {
            Circle()
                .fill(.background)

            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
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
    }

    private var rowBackgroundFill: Color {
        if isExperimentalControlActive {
            return Color.orange.opacity(isHovering ? 0.12 : 0.08)
        }

        return isHovering ? Color.primary.opacity(0.06) : Color.clear
    }

    @ViewBuilder
    private var experimentalControlAccessory: some View {
        if isExperimentalControlPending {
            pendingBadge
        } else if isExperimentalControlActive {
            realControlBadge
        } else if isExperimentalControlResolving {
            resolvingBadge
        }
    }

    /// Non-interactive badge shown while a Product Real start/stop for this row is in flight.
    private var pendingBadge: some View {
        ProgressView()
            .controlSize(.mini)
            .scaleEffect(0.55)
            .frame(width: AppConstants.Layout.rowLiveButtonSize + 6, height: AppConstants.Layout.rowBadgeHeight)
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
                .frame(width: AppConstants.Layout.rowLiveButtonSize + 6, height: AppConstants.Layout.rowBadgeHeight)
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
        .frame(width: AppConstants.Layout.rowLiveButtonSize + 36, height: AppConstants.Layout.rowBadgeHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
        )
        // Single element so the label below is not repeated on both the spinner and the text.
        .accessibilityElement(children: .ignore)
        .help("Finding the audio helper for \(app.name)")
        .accessibilityLabel(Text("Resolving real app control for \(app.name)"))
    }
}
