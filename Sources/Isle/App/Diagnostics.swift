import Foundation
import os

/// Unified logging plus a small rotating file at ~/Library/Logs/Isle.log, so
/// problems can be diagnosed without Console. Only lifecycle events and
/// errors are logged; nothing per-frame or per-track.
struct Diagnostics: Sendable {
    private let logger: Logger

    init(category: String) {
        logger = Logger(subsystem: "com.avhiejeet.Isle", category: category)
    }

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        Self.append(message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        Self.append("ERROR " + message)
    }

    // MARK: File sink

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Isle.log")
    private static let maxBytes: UInt64 = 512 * 1024
    /// Serialises writes from any thread (termination handlers, pipe readers…).
    private static let queue = DispatchQueue(label: "com.avhiejeet.Isle.diagnostics", qos: .utility)

    private static func append(_ message: String) {
        let line = Data("\(Date.now.formatted(.iso8601)) \(message)\n".utf8)
        queue.async {
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64, size > maxBytes {
                let previous = fileURL.appendingPathExtension("1")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: fileURL, to: previous)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                try? line.write(to: fileURL)
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }
}
