import AppKit
import IsleKit
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

    /// A summary being written, or the last one written.
    struct Summary: Equatable {
        let file: String
        var text: String?
        var failure: String?
        var isWorking: Bool { text == nil && failure == nil }
    }

    private(set) var items: [Item] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    private(set) var summary: Summary?
    /// Reports conversions and finished summaries (the "done" banner).
    @ObservationIgnored var onFinish: (FinishedInfo) -> Void = { _ in }

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

    // MARK: Actions

    /// Converts images to JPEG and keeps the results on the shelf.
    func convert(_ urls: [URL]) {
        var made: [URL] = []
        var failure: String?
        for url in urls {
            do { made.append(try ShelfActions.convertToJPEG(url)) } catch { failure = error.localizedDescription }
        }
        add(made)
        if let first = made.first {
            onFinish(FinishedInfo(title: made.count == 1 ? first.lastPathComponent : "\(made.count) JPEGs",
                                  detail: "Converted and kept on the shelf", symbol: "checkmark", succeeded: true))
        } else {
            onFinish(FinishedInfo(title: "Couldn't convert", detail: failure ?? "", symbol: "xmark", succeeded: false))
        }
    }

    func summarise(_ url: URL) {
        summary = Summary(file: url.lastPathComponent)
        Task {
            do {
                let text = try await ShelfActions.summarise(url)
                summary = Summary(file: url.lastPathComponent, text: text)
                onFinish(FinishedInfo(title: "Summary ready", detail: url.lastPathComponent,
                                      symbol: "checkmark", succeeded: true))
            } catch {
                summary = Summary(file: url.lastPathComponent, failure: error.localizedDescription)
            }
        }
    }

    func dismissSummary() { summary = nil }

    func previewSummary(_ summary: Summary) { self.summary = summary }

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
