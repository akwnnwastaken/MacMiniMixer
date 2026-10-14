import SwiftUI

/// Liquid Glass helpers for the mixer panel. Following Apple's guidance, glass is used for the
/// control layer only (buttons, badges); content sits on quiet platters on the panel's own glass,
/// because glass cannot sample other glass. Before macOS 26 every helper falls back to materials.
extension View {
    /// Interactive glass for a control on macOS 26+, a thin material before.
    @ViewBuilder
    func glassControl<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.thinMaterial)

                    if let tint {
                        shape.fill(tint)
                    }
                }
            }
            .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    /// A quiet content platter on the panel's glass.
    func platter(cornerRadius: CGFloat = AppConstants.Layout.cornerRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

/// Groups glass controls so they share one sampling region (and can blend) on macOS 26+.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}
