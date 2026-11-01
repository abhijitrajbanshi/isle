import IsleKit
import SwiftUI

struct ShelfTab: View {
    @Environment(ShelfModel.self) private var shelf
    @Environment(IslandEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if engine.isDraggingFile {
                DropTargets()
            } else {
                if let summary = shelf.summary {
                    SummaryCard(summary: summary)
                }
                if shelf.items.isEmpty {
                    if shelf.summary == nil { DropZone(isTargeted: engine.isDropTargeted).frame(height: 96) }
                } else {
                    items.frame(height: 86)
                }
            }
        }
        .animation(Motion.morph, value: engine.isDraggingFile)
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

// MARK: Drop targets

/// While a file is being dragged to the notch: what to do with it.
private struct DropTargets: View {
    @Environment(ShelfModel.self) private var shelf

    var body: some View {
        HStack(spacing: 8) {
            DropTarget(symbol: "tray.and.arrow.down.fill", title: "Keep") { shelf.add($0) }
            DropTarget(symbol: "dot.radiowaves.up.forward", title: "AirDrop") { urls in
                shelf.airDrop(urls.map(ShelfModel.Item.init(url:)))
            }
            DropTarget(symbol: "photo", title: "Convert", detail: "to JPEG") { shelf.convert($0) }
            DropTarget(symbol: "text.alignleft", title: "Summarise",
                       detail: ShelfActions.canSummarise ? "on this Mac" : "needs Apple Intelligence",
                       isEnabled: ShelfActions.canSummarise) { urls in
                if let first = urls.first { shelf.summarise(first) }
            }
        }
        .frame(height: 96)
    }
}

private struct DropTarget: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var isEnabled = true
    let action: ([URL]) -> Void
    @Environment(IslandEngine.self) private var engine
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium))
            Text(title).font(.island(12, .semibold))
            if let detail {
                Text(detail).font(.island(10)).opacity(0.6).lineLimit(1)
            }
        }
        .foregroundStyle(isTargeted ? Color.black : (isEnabled ? Palette.label : Palette.tertiaryLabel))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isTargeted ? Color.white : Palette.secondaryFill))
        .scaleEffect(isTargeted ? 1.03 : 1)
        .animation(Motion.land, value: isTargeted)
        .modifier(DropHandler(isEnabled: isEnabled, isTargeted: $isTargeted) { providers in
            loadURLs(providers) { action($0) }
            engine.fileDragEnded()
        })
    }
}

/// AppKit-backed, so left out of offscreen snapshots (ImageRenderer can't draw it).
private struct DropHandler: ViewModifier {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let perform: ([NSItemProvider]) -> Void
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        if isSnapshot {
            content
        } else {
            content.onDrop(of: [.fileURL], isTargeted: isEnabled ? $isTargeted : .constant(false)) { providers in
                guard isEnabled else { return false }
                perform(providers)
                return true
            }
        }
    }
}

/// Resolves dropped file URLs, then calls back on the main actor.
func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let box = URLBox()
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { box.append(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated { completion(box.urls) }
    }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var urls: [URL] { lock.withLock { stored } }
    func append(_ url: URL) { lock.withLock { stored.append(url) } }
}

// MARK: Summary

/// A document's summary from the on-device model.
struct SummaryCard: View {
    let summary: ShelfModel.Summary
    @Environment(ShelfModel.self) private var shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.alignleft").font(.system(size: 11, weight: .semibold))
                Text(summary.file).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if !summary.isWorking {
                    if let text = summary.text {
                        CapsuleButton(title: "Copy", isQuiet: true) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
                    CapsuleButton(title: "Done", isQuiet: true) { shelf.dismissSummary() }
                }
            }
            .font(.island(12, .semibold))
            .foregroundStyle(Palette.secondaryLabel)
            .frame(height: 24)

            if let text = summary.text {
                Text(text)
                    .font(.island(13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure = summary.failure {
                Text(failure).font(.island(13)).foregroundStyle(Palette.secondaryLabel)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading it on this Mac").font(.island(13)).foregroundStyle(Palette.secondaryLabel)
                }
            }
        }
    }
}
