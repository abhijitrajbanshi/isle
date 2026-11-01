import IsleKit
import SwiftUI

struct ShelfTab: View {
    @Environment(ShelfModel.self) private var shelf
    @Environment(IslandEngine.self) private var engine

    var body: some View {
        Group {
            if shelf.items.isEmpty {
                DropZone(isTargeted: engine.isDropTargeted)
            } else {
                items
            }
        }
        // the open island sizes itself to its content; the shelf needs room to drop onto
        .frame(height: 112)
        .onAppear { shelf.pruneMissing() }
    }

    private var items: some View {
        HStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(shelf.items) { ShelfTile(item: $0) }
                }
            }
            .scrollClipDisabled()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(engine.isDropTargeted ? Palette.blue.opacity(0.12) : .clear)
                    .strokeBorder(engine.isDropTargeted ? Palette.blue : .clear, lineWidth: 1.5)
            }
            VStack(spacing: 10) {
                IslandButton(symbol: "dot.radiowaves.up.forward", label: "AirDrop all", size: 14,
                             tint: Palette.blue, fill: Palette.blue.opacity(0.18), diameter: 40) {
                    shelf.airDrop(shelf.items)
                }
                IslandButton(symbol: "trash", label: "Clear shelf", size: 13, tint: Palette.secondaryLabel,
                             fill: Palette.fill, diameter: 40) {
                    shelf.removeAll()
                }
            }
        }
        .animation(Motion.snappy, value: engine.isDropTargeted)
    }
}

private struct DropZone: View {
    let isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(isTargeted ? Palette.blue.opacity(0.13) : Palette.secondaryFill)
            .strokeBorder(isTargeted ? Palette.blue : Palette.tertiaryLabel.opacity(0.6),
                          style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 22, weight: .medium))
                        .symbolEffect(.bounce, value: isTargeted)
                    Text(isTargeted ? "Release to add" : "Drop files here")
                        .font(.island(13, .semibold))
                        .contentTransition(.opacity)
                    Text("Keep files in the notch, then drag them out or AirDrop them.")
                        .font(.island(11)).foregroundStyle(Palette.tertiaryLabel)
                }
                .foregroundStyle(isTargeted ? Palette.blue : Palette.secondaryLabel)
            }
            .scaleEffect(isTargeted ? 1.015 : 1)
            .animation(Motion.snappy, value: isTargeted)
    }
}

private struct ShelfTile: View {
    @Environment(ShelfModel.self) private var shelf
    let item: ShelfModel.Item
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: shelf.thumbnail(for: item.url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 50, height: 50)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            Text(item.name)
                .font(.island(10.5, .medium))
                .foregroundStyle(Palette.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 72)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isHovering ? Palette.secondaryFill : .clear))
        .onHover { isHovering = $0 }
        .animation(Motion.snappy, value: isHovering)
        .onTapGesture(count: 2) { shelf.open(item) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { shelf.open(item) }
            Button("Show in Finder") { shelf.reveal(item) }
            Button("AirDrop") { shelf.airDrop([item]) }
            Divider()
            Button("Remove from Shelf", role: .destructive) { shelf.remove(item) }
        }
        .help(item.url.path)
        .accessibilityLabel(item.name)
    }
}
