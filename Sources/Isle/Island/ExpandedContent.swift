import IsleKit
import SwiftUI

/// The open island. Its height is whatever the content needs: the view
/// measures itself and the engine sizes the island (and its hit area) to fit.
struct ExpandedContent: View {
    @Environment(IslandEngine.self) private var engine

    var body: some View {
        content
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if abs(engine.expandedHeight - height) > 0.5 { engine.expandedHeight = height }
            }
            .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        switch engine.tab {
        case .home: StackView()
        case .timer: Sheet(title: "Timer") { TimerTab() }
        case .shelf: Sheet(title: "Shelf") { ShelfTab() }
        }
    }
}

/// A single-purpose view opened from the stack or the menu (timer, shelf),
/// with a way back.
private struct Sheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(IslandEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Button { engine.tab = .home } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text(title)
                    }
                    .font(.island(12, .semibold))
                    .foregroundStyle(Palette.secondaryLabel)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                Spacer(minLength: engine.metrics.size.width + 24)
            }
            .frame(height: engine.metrics.size.height)
            .padding(.top, 2)
            content
        }
    }
}
