import AppKit
import SwiftUI

/// What the island is made of.
enum IslandStyle: String, CaseIterable, Identifiable {
    /// Pure black, continuous with the hardware notch (Apple's choice for the island).
    case black
    /// Liquid Glass.
    case glass

    var id: Self { self }

    var title: String {
        switch self {
        case .black: "Black"
        case .glass: "Liquid Glass"
        }
    }
}

/// The island's material, filling `shape`: opaque black, continuous with
/// the hardware notch (or Liquid Glass, if chosen in Settings).
struct IslandSurface<S: Shape>: View {
    let shape: S
    let style: IslandStyle
    /// Glass only: drop the material so just the content shows (compact
    /// activities beside the notch); it fades back in when the island grows.
    var bare = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // Reduce Transparency replaces glass with an opaque surface, as system glass does
        if style == .black || reduceTransparency {
            shape.fill(.black)
                // Increase Contrast: an outline keeps the island distinct on a dark menu bar
                .overlay { if contrast == .increased { shape.stroke(.white.opacity(0.5), lineWidth: 1) } }
        } else {
            glass.opacity(bare ? 0 : 1)
        }
    }

    @ViewBuilder private var glass: some View {
        #if compiler(>=6.2) // Liquid Glass needs the macOS 26 SDK (Xcode 26)
        if #available(macOS 26, *) {
            Rectangle()
                .fill(.clear)
                // regular (frosted) glass with a dark tint keeps white content legible
                .glassEffect(.regular.tint(.black.opacity(0.32)), in: shape)
        } else {
            frosted
        }
        #else
        frosted
        #endif
    }

    /// Pre-macOS 26 (or pre-Xcode 26 builds): the desktop blurred through the panel.
    private var frosted: some View {
        BehindWindowBlur()
            .overlay(shape.fill(.black.opacity(0.35)))
            .clipShape(shape)
            .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// Pre-macOS 26 fallback: the desktop blurred through the transparent panel.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
