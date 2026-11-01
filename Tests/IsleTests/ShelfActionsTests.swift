import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Isle

struct ShelfActionsTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("isle-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writePNG(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    @Test func convertsImagesToJPEGBesideTheOriginal() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("photo.png")
        try writePNG(to: png)

        let first = try ShelfActions.convertToJPEG(png)
        #expect(first.lastPathComponent == "photo.jpg")
        let source = CGImageSourceCreateWithURL(first as CFURL, nil)
        #expect(source.flatMap { CGImageSourceGetType($0) as String? } == UTType.jpeg.identifier)

        // never overwrites
        #expect(try ShelfActions.convertToJPEG(png).lastPathComponent == "photo 2.jpg")
    }

    @Test func refusesToConvertNonImages() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        #expect(throws: ShelfActions.Failure.self) { try ShelfActions.convertToJPEG(text) }
    }

    @Test func readsTextDocuments() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let markdown = folder.appendingPathComponent("plan.md")
        try "# Plan\nShip Isle 2.".write(to: markdown, atomically: true, encoding: .utf8)
        #expect(try ShelfActions.text(of: markdown).contains("Ship Isle 2"))

        let empty = folder.appendingPathComponent("empty.txt")
        try "  \n".write(to: empty, atomically: true, encoding: .utf8)
        #expect(throws: ShelfActions.Failure.self) { try ShelfActions.text(of: empty) }
    }

    /// Runs the real on-device model where Apple Intelligence is available.
    @Test(.enabled(if: ShelfActions.canSummarise)) func summarisesOnDevice() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let doc = folder.appendingPathComponent("memo.txt")
        try """
        Team update. The release of version 2.0 moves to Friday because the signing certificate expired on Monday. \
        Marketing will publish the announcement on Friday morning. Support should expect questions about the new \
        agent features and the removal of the volume and brightness alerts.
        """.write(to: doc, atomically: true, encoding: .utf8)
        let summary = try await ShelfActions.summarise(doc)
        #expect(!summary.isEmpty)
        print("on-device summary:\n\(summary)")
    }
}
