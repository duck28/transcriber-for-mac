import SwiftUI

// Liquid Glass needs the macOS 26 SDK (Swift 6.2 or later) at build time and macOS 26 at run time.
// Otherwise these helpers fall back to a translucent material with a hairline edge.

#if compiler(>=6.2)
@available(macOS 26, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif

extension View {
    /// Puts this view on a floating glass surface shaped like `shape`.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            materialSurface(in: shape, tint: tint)
        }
        #else
        materialSurface(in: shape, tint: tint)
        #endif
    }

    /// Puts this view on a capsule-shaped glass surface.
    func glassSurface(tint: Color? = nil, interactive: Bool = false) -> some View {
        glassSurface(in: Capsule(), tint: tint, interactive: interactive)
    }

    /// Glass buttons on macOS 26, bordered capsules before.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            borderedButtonStyle(prominent: prominent)
        }
        #else
        borderedButtonStyle(prominent: prominent)
        #endif
    }

    @ViewBuilder
    private func borderedButtonStyle(prominent: Bool) -> some View {
        if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    private func materialSurface<S: InsettableShape>(in shape: S, tint: Color?) -> some View {
        background {
            ZStack {
                shape.fill(.regularMaterial)
                if let tint { shape.fill(tint.opacity(0.15)) }
            }
            .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        }
        .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
    }
}

/// Lets neighbouring glass shapes blend into each other on macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
