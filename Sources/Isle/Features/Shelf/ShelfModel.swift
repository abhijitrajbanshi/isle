import AppKit
import Observation
import QuickLookThumbnailing

/// Files parked in the notch, persisted across launches.
@MainActor
@Observable
final class ShelfModel {
    struct Item: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        var name: String { url.lastPathComponent }
    }

    private(set) var items: [Item] = []
    private(set) var thumbnails: [URL: NSImage] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "shelf.paths"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = (defaults.stringArray(forKey: Self.key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(Item.init(url:))
        items.forEach { loadThumbnail(for: $0.url) }
    }

    func add(_ urls: [URL]) {
        // de-duplicate against the shelf *and* within the batch, keeping order
        var seen = Set(items.map(\.url))
        let fresh = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL).inserted }
            .map { Item(url: $0.standardizedFileURL) }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh)
        fresh.forEach { loadThumbnail(for: $0.url) }
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0 == item }
        thumbnails[item.url] = nil
        save()
    }

    func removeAll() {
        items.removeAll()
        thumbnails.removeAll()
        save()
    }

    /// Drops items whose files were deleted or moved since they were shelved.
    func pruneMissing() {
        let missing = items.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        guard !missing.isEmpty else { return }
        missing.forEach { thumbnails[$0.url] = nil }
        items.removeAll { missing.contains($0) }
        save()
    }

    func open(_ item: Item) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: Item) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func airDrop(_ items: [Item]) {
        let urls = items.map(\.url)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return }
        service.perform(withItems: urls)
    }

    func thumbnail(for url: URL) -> NSImage {
        thumbnails[url] ?? NSWorkspace.shared.icon(forFile: url.path)
    }

    private func loadThumbnail(for url: URL) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 104, height: 104),
                                                   scale: 2, representationTypes: .thumbnail)
        Task {
            guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            else { return }
            thumbnails[url] = image
        }
    }

    private func save() {
        defaults.set(items.map(\.url.path), forKey: Self.key)
    }
}
