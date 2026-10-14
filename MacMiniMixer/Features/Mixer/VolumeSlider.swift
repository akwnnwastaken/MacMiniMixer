import AppKit
import SwiftUI

/// Maps a volume to a position on the slider track (0...1) and back.
///
/// With a `unity` value (per-app volume, 0–200), 0...unity fills the first `unityFraction` of the
/// track and unity...upperBound (the boost range) the rest, so everyday levels keep most of the
/// travel. Without one (system volume) the mapping is linear.
struct VolumeSliderScale: Equatable {
    let range: ClosedRange<Double>
    let unity: Double?
    var unityFraction: Double = 2.0 / 3.0

    func fraction(for value: Double) -> Double {
        let value = value.clamped(to: range)
        guard let unity, unity > range.lowerBound, unity < range.upperBound else {
            return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        }

        if value <= unity {
            return (value - range.lowerBound) / (unity - range.lowerBound) * unityFraction
        }

        return unityFraction + (value - unity) / (range.upperBound - unity) * (1 - unityFraction)
    }

    func value(for fraction: Double) -> Double {
        let fraction = fraction.clamped(to: 0...1)
        guard let unity, unity > range.lowerBound, unity < range.upperBound else {
            return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        }

        if fraction <= unityFraction {
            return range.lowerBound + fraction / unityFraction * (unity - range.lowerBound)
        }

        return unity + (fraction - unityFraction) / (1 - unityFraction) * (range.upperBound - unity)
    }

    /// Rounds a dragged value to a whole percent and pulls it onto `unity` when it lands within
    /// `snapDistance`, so 100% is easy to hit exactly.
    func settledValue(for rawValue: Double, snapDistance: Double = 4) -> Double {
        let rounded = rawValue.rounded().clamped(to: range)
        if let unity, abs(rounded - unity) <= snapDistance {
            return unity
        }

        return rounded
    }
}

/// Thick, knobless capsule slider in the style of macOS Control Center. The fill grows from the
/// leading edge with a rounded end; near 0 that rounded end slides out of the track, so 0% shows
/// no fill at all. Past `unity` the fill turns orange and a notch marks 100%. An optional icon and title sit inside
/// the track at the leading edge and the percentage at the trailing edge; where the white fill
/// passes under them they switch to a dark color so they stay legible.
///
/// Drag or click anywhere on the track to set the value; arrow keys step by 5 when focused. With
/// `onIconTap`, a click (not a drag) on the leading icon calls it instead, e.g. to toggle mute.
/// VoiceOver sees a native `Slider`.
struct VolumeSlider: View {
    @Binding var value: Double
    let scale: VolumeSliderScale
    let accessibilityLabel: String
    var accessibilityHint: String = ""
    var height: CGFloat = 30
    var systemImage: String?
    var title: String?
    var showsValue = true
    var isMuted = false
    var onIconTap: (() -> Void)?
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false
    @State private var isHovering = false
    /// A press began on the leading icon and has not moved far enough to count as a drag yet.
    @State private var isPressingIcon = false

    private static let keyboardStep: Double = 5
    private static let iconTapSlop: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let fillWidth = CGFloat(scale.fraction(for: value)) * width
            let unityX = scale.unity.map { CGFloat(scale.fraction(for: $0)) * width }

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHovering || isDragging ? 0.14 : 0.10))

                fill(width: fillWidth, unityX: unityX)

                if let unityX {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.28))
                        .frame(width: 1.5, height: height * 0.42)
                        .offset(x: unityX - 0.75)
                }

                trackContent(color: .primary, valueColor: valueColor)

                trackContent(color: Color.black.opacity(0.78), valueColor: Color.black.opacity(0.78))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: fillWidth)
                    }
            }
            .frame(width: width, height: height)
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
            .gesture(dragGesture(width: width))
        }
        .frame(height: height)
        .scaleEffect(isDragging && !reduceMotion ? 1.015 : 1)
        .opacity(isEnabled ? 1 : 0.55)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.14), value: isHovering)
        .animation(reduceMotion ? nil : .snappy(duration: 0.14), value: isDragging)
        .focusable(isEnabled)
        .modifier(FocusRingHidden())
        .onMoveCommand(perform: handleMoveCommand)
        .accessibilityRepresentation {
            Slider(value: $value, in: scale.range, step: 1) {
                Text(accessibilityLabel)
            }
            .accessibilityValue(Text(accessibilityValueText))
            .accessibilityHint(Text(accessibilityHint))
        }
    }

    /// White fill up to unity, orange boost segment after it. Its trailing end is a capsule at
    /// least as wide as the track is tall, shifted left as the fill shrinks so it leaves the track
    /// (which clips it) instead of turning into a small circle.
    private func fill(width: CGFloat, unityX: CGFloat?) -> some View {
        let normalWidth = min(width, unityX ?? width)
        let capsuleWidth = max(width, height)
        // Extra fill on the left that the offset below pushes out of the track.
        let hiddenWidth = capsuleWidth - width

        return HStack(spacing: 0) {
            Rectangle()
                .fill(fillColor)
                .frame(width: hiddenWidth + normalWidth)

            Rectangle()
                .fill(boostColor)
                .frame(width: max(0, width - normalWidth))
        }
        .frame(width: capsuleWidth, height: height, alignment: .leading)
        .clipShape(Capsule(style: .continuous))
        .offset(x: width - capsuleWidth)
    }

    private func trackContent(color: Color, valueColor: Color) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: height * 0.4, weight: .semibold))
                    .frame(width: height * 0.5)
            }

            if let title {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if showsValue {
                Text(isMuted ? "Muted" : "\(Int(value.rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(valueColor)
            }
        }
        .foregroundStyle(color)
        .padding(.leading, systemImage == nil ? height * 0.42 : height * 0.25)
        .padding(.trailing, height * 0.38)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var fillColor: Color {
        isMuted ? Color.primary.opacity(0.22) : Color.white
    }

    private var boostColor: Color {
        isMuted ? Color.primary.opacity(0.22) : Color.orange
    }

    private var valueColor: Color {
        .secondary
    }

    private var accessibilityValueText: String {
        let percent = Int(value.rounded())
        if isMuted {
            return "Muted, \(percent) percent"
        }

        if let unity = scale.unity, value > unity {
            return "\(percent) percent, boosted"
        }

        return "\(percent) percent"
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isEnabled else {
                    return
                }

                if !isDragging && !isPressingIcon,
                   onIconTap != nil, systemImage != nil, gesture.startLocation.x < height {
                    isPressingIcon = true
                }

                if isPressingIcon {
                    let moved = abs(gesture.translation.width) > Self.iconTapSlop
                        || abs(gesture.translation.height) > Self.iconTapSlop
                    guard moved else {
                        return
                    }

                    isPressingIcon = false
                }

                if !isDragging {
                    isDragging = true
                    onEditingChanged(true)
                }

                let fraction = Double(gesture.location.x / width)
                let newValue = scale.settledValue(for: scale.value(for: fraction))
                if let unity = scale.unity, newValue == unity, value != unity {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }

                if newValue != value {
                    value = newValue
                }
            }
            .onEnded { _ in
                if isPressingIcon {
                    isPressingIcon = false
                    onIconTap?()
                    return
                }

                guard isDragging else {
                    return
                }

                isDragging = false
                onEditingChanged(false)
            }
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        guard isEnabled else {
            return
        }

        let delta: Double
        switch direction {
        case .right, .up:
            delta = Self.keyboardStep
        case .left, .down:
            delta = -Self.keyboardStep
        @unknown default:
            return
        }

        onEditingChanged(true)
        value = (value + delta).clamped(to: scale.range)
        onEditingChanged(false)
    }
}

/// The slider draws its own state, so the system focus ring would only add a stray outline.
private struct FocusRingHidden: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}
