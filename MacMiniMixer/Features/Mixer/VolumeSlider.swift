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

/// Volume slider for the mixer panel: a capsule track with an accent fill, an orange boost segment
/// past `unity` and a notch marking it, and a white knob. Drag anywhere on the track to set the
/// value; arrow keys step by 5 when focused. VoiceOver sees a native `Slider`.
struct VolumeSlider: View {
    @Binding var value: Double
    let scale: VolumeSliderScale
    let accessibilityLabel: String
    var accessibilityHint: String = ""
    var trackHeight: CGFloat = 4
    var knobSize: CGFloat = 14
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false
    @State private var isHovering = false

    private static let keyboardStep: Double = 5

    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - knobSize)
            let knobX = CGFloat(scale.fraction(for: value)) * travel
            let unityX = scale.unity.map { CGFloat(scale.fraction(for: $0)) * travel + knobSize / 2 }
            let isBoosted = scale.unity.map { value > $0 } ?? false
            // The accent fill stops at unity; the boost segment draws the rest.
            let fillEnd = isBoosted ? (unityX ?? 0) : knobX + knobSize / 2

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: trackHeight)

                Capsule(style: .continuous)
                    .fill(fillColor)
                    .frame(width: fillEnd, height: trackHeight)

                if let unityX {
                    if isBoosted {
                        Rectangle()
                            .fill(boostColor)
                            .frame(width: max(0, knobX + knobSize / 2 - unityX), height: trackHeight)
                            .offset(x: unityX)
                    }

                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.4))
                        .frame(width: 2, height: trackHeight + 6)
                        .offset(x: unityX - 1)
                }

                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 0.5))
                    .frame(width: knobSize, height: knobSize)
                    .scaleEffect(knobScale)
                    .offset(x: knobX)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(travel: travel))
        }
        .frame(height: knobSize + 4)
        .opacity(isEnabled ? 1 : 0.7)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: isHovering)
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: isDragging)
        .focusable(isEnabled)
        .onMoveCommand(perform: handleMoveCommand)
        .accessibilityRepresentation {
            Slider(value: $value, in: scale.range, step: 1) {
                Text(accessibilityLabel)
            }
            .accessibilityValue(Text(accessibilityValueText))
            .accessibilityHint(Text(accessibilityHint))
        }
    }

    private var fillColor: Color {
        isEnabled ? .accentColor : Color.secondary.opacity(0.6)
    }

    private var boostColor: Color {
        isEnabled ? .orange : Color.secondary.opacity(0.6)
    }

    private var knobScale: CGFloat {
        guard isEnabled else {
            return 1
        }

        return isDragging ? 1.12 : (isHovering ? 1.06 : 1)
    }

    private var accessibilityValueText: String {
        let percent = Int(value.rounded())
        if let unity = scale.unity, value > unity {
            return "\(percent) percent, boosted"
        }

        return "\(percent) percent"
    }

    private func dragGesture(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isEnabled else {
                    return
                }

                if !isDragging {
                    isDragging = true
                    onEditingChanged(true)
                }

                let fraction = Double((gesture.location.x - knobSize / 2) / travel)
                let newValue = scale.settledValue(for: scale.value(for: fraction))
                if let unity = scale.unity, newValue == unity, value != unity {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }

                if newValue != value {
                    value = newValue
                }
            }
            .onEnded { _ in
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
