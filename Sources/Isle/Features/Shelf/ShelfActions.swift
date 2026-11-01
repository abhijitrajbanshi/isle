import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What dropping a file on the notch can do with it, besides keeping it.
enum ShelfActions {
    enum Failure: LocalizedError {
        case notAnImage, unreadable, noText, needsAppleIntelligence

        var errorDescription: String? {
            switch self {
            case .notAnImage: "Only images can be converted"
            case .unreadable: "Couldn't read the file"
            case .noText: "There's no text to summarise"
            case .needsAppleIntelligence: "Summaries need Apple Intelligence (macOS 26 or later)"
            }
        }
    }

    // MARK: Convert

    /// Re-encodes an image (HEIC, PNG, WebP, TIFF…) as a JPEG next to the
    /// original, or in Downloads when that folder isn't writable. Keeps the
    /// orientation and colour profile.
    static func convertToJPEG(_ url: URL) throws -> URL {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else {
            throw Failure.notAnImage
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadable }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        let output = uniqueURL(for: url, extension: "jpg")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.unreadable }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return output
    }

    private static func uniqueURL(for url: URL, extension ext: String) -> URL {
        let folder = FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
            ? url.deletingLastPathComponent()
            : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = url.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    // MARK: Summarise

    /// The document's text: PDFs, plain text and Markdown, RTF, Word, HTML.
    static func text(of url: URL) throws -> String {
        let text: String?
        if url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(url: url)?.string
        } else if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .plainText) {
            text = try? String(contentsOf: url, encoding: .utf8)
        } else {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.noText }
        return text
    }

    static var canSummarise: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// A short summary from Apple's on-device model: nothing leaves the Mac.
    static func summarise(_ url: URL) async throws -> String {
        let text = try text(of: url)
        #if canImport(FoundationModels)
        if #available(macOS 26, *), SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(instructions: """
                Summarise the document for someone deciding whether to read it. \
                Reply with at most three short bullet points, each starting with "• ". \
                Plain text, no headings, no preamble.
                """)
            // the on-device model has a small context: the opening of the document
            let response = try await session.respond(to: String(text.prefix(8000)))
            return response.content
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
        }
        #endif
        throw Failure.needsAppleIntelligence
    }
}
