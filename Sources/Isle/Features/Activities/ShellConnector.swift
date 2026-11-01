import Foundation

/// Adds Isle's shell integration to ~/.zshrc (and removes it again), so
/// terminal commands that run long report to the notch. Only ever run from
/// the Settings button; keeps a backup next to the file.
enum ShellConnector {
    /// Tests point this at a scratch file.
    nonisolated(unsafe) static var fileOverride: URL?
    nonisolated(unsafe) static var helperOverride: String?

    static var zshrc: URL {
        fileOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
    }

    private static let begin = "# >>> Isle: long terminal commands report to the notch >>>"
    private static let end = "# <<< Isle <<<"

    static var isConnected: Bool {
        (try? String(contentsOf: zshrc, encoding: .utf8))?.contains(begin) == true
    }

    static func connect() throws {
        guard let helper = helperOverride ?? ClaudeConnector.helperPath else { throw ClaudeConnector.Failure.notBundled }
        var text = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        guard !text.contains(begin) else { return }
        try backup()
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += """

        \(begin)
        [[ -x "\(helper)" ]] && source <("\(helper)" shell-init zsh)
        \(end)

        """
        try text.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    static func disconnect() throws {
        guard var text = try? String(contentsOf: zshrc, encoding: .utf8),
              let start = text.range(of: begin), let finish = text.range(of: end, range: start.upperBound..<text.endIndex)
        else { return }
        try backup()
        var lower = start.lowerBound
        // the blank line Isle added before its block
        if lower > text.startIndex, text[text.index(before: lower)] == "\n" { lower = text.index(before: lower) }
        var upper = finish.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        text.removeSubrange(lower..<upper)
        try text.write(to: zshrc, atomically: true, encoding: .utf8)
    }

    private static func backup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: zshrc.path) else { return }
        let copy = zshrc.deletingLastPathComponent().appendingPathComponent(".zshrc.isle-backup")
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: zshrc, to: copy)
    }
}
