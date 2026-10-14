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

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isMuted.toggle()
            } label: {
                appIcon
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(Text(isMuted ? "Unmute \(app.name)" : "Mute \(app.name)"))
            .accessibilityValue(Text(isOutputActive ? "Playing audio" : "Not playing"))

            VolumeSlider(
                value: $volume,
                scale: VolumeSliderScale(range: AppConstants.appVolumeRange, unity: AppConstants.unityAppVolume),
                accessibilityLabel: "\(app.name) volume",
                accessibilityHint: isExperimentalControlResolving
                    ? "Finding the audio helper for this app"
                    : isExperimentalControlActive
                        ? "Adjusts real audio level for this app. Above 100 percent boosts it."
                        : "Adjusts the volume for this app. Above 100 percent boosts it.",
                height: AppConstants.Layout.appSliderHeight,
                title: app.name,
                isMuted: isMuted
            )
            .disabled(isMuted || isExperimentalControlResolving)

            experimentalControlAccessory
        }
        .animation(.snappy(duration: 0.16), value: isMuted)
        .animation(.snappy(duration: 0.16), value: isOutputActive)
        .animation(.snappy(duration: 0.16), value: isExperimentalControlActive)
        .animation(.snappy(duration: 0.16), value: isExperimentalControlResolving)
        .animation(.snappy(duration: 0.16), value: isExperimentalControlPending)
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
            .overlay(alignment: .topTrailing) {
                if isOutputActive && !isMuted {
                    playingDot
                }
            }
            .contentShape(Circle())
    }

    /// Shown while Core Audio reports the app producing output.
    private var playingDot: some View {
        Circle()
            .fill(Color.green)
            .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .frame(width: 8, height: 8)
            .offset(x: 1, y: -1)
            .transition(.scale.combined(with: .opacity))
            .help("Playing audio")
            .accessibilityHidden(true)
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

    /// Non-interactive indicator shown while a Product Real start/stop for this row is in flight.
    private var pendingBadge: some View {
        ProgressView()
            .controlSize(.mini)
            .scaleEffect(0.6)
            .frame(width: AppConstants.Layout.rowIndicatorSize, height: AppConstants.Layout.rowIndicatorSize)
            .help("Real app control is changing for \(app.name)…")
            .accessibilityLabel(Text("Real app control is changing for \(app.name)"))
    }

    /// Small orange indicator while this app is under Real control; clicking it stops that control.
    private var realControlBadge: some View {
        Button(action: toggleExperimentalControl) {
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: AppConstants.Layout.rowIndicatorSize, height: AppConstants.Layout.rowIndicatorSize)
                .glassControl(in: Circle(), tint: Color.orange.opacity(0.22))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Real control is on for \(app.name). Click to stop.")
        .accessibilityLabel(Text("Stop Real App Control for \(app.name)"))
    }

    private var resolvingBadge: some View {
        ProgressView()
            .controlSize(.mini)
            .scaleEffect(0.6)
            .tint(.orange)
            .frame(width: AppConstants.Layout.rowIndicatorSize, height: AppConstants.Layout.rowIndicatorSize)
            .help("Finding the audio helper for \(app.name)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Resolving real app control for \(app.name)"))
    }
}
