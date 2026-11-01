import Foundation

/// Adds Isle's hooks to Claude Code's user settings (`~/.claude/settings.json`)
/// and removes them again. Only ever run from the Settings button.
///
/// Every hook runs the bundled `isle hook claude`, which is a silent no-op
/// when Isle isn't running, so Claude Code is never affected by it.
enum ClaudeConnector {
    enum Failure: LocalizedError {
        case notBundled, unreadable

        var errorDescription: String? {
            switch self {
            case .notBundled: "Isle needs to run from Isle.app to connect."
            case .unreadable: "Claude Code's settings file isn't valid JSON, so Isle left it alone."
            }
        }
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The bundled `isle` command, or nil outside an app bundle (`swift run`).
    static var helperPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/isle").path
        return Bundle.main.bundleURL.pathExtension == "app" && FileManager.default.isExecutableFile(atPath: path)
            ? path : nil
    }

    /// Events Isle listens to. Only PermissionRequest waits for an answer;
    /// the rest are fire-and-forget.
    static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
                         "Notification", "PreCompact", "Stop", "SessionEnd"]
    private static let marker = "Contents/Helpers/isle\" hook claude"

    static var isConnected: Bool {
        guard let settings = try? read(), let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains(where: isOurs)
        }
    }

    static func connect() throws {
        guard let helper = helperPath else { throw Failure.notBundled }
        var settings = try read()
        try backup()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let command = "\"\(helper)\" hook claude"
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            var hook: [String: Any] = ["type": "command", "command": command]
            if event == "PermissionRequest" {
                // a little longer than the island waits, so Isle always answers or steps aside first
                hook["timeout"] = 60
            } else {
                hook["timeout"] = 5
                hook["async"] = true
            }
            groups.append(["hooks": [hook]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        // the status line carries usage limits and context; only if you don't have your own
        if settings["statusLine"] == nil || isOurStatusLine(settings["statusLine"]) {
            settings["statusLine"] = ["type": "command", "command": "\"\(helper)\" statusline", "padding": 0]
        }
        try write(settings)
    }

    /// Re-installs after an update added events, keeping your settings.
    static func upgradeIfNeeded() {
        guard let settings = try? read(), let hooks = settings["hooks"] as? [String: Any],
              (hooks["PermissionRequest"] as? [[String: Any]] ?? []).contains(where: isOurs),
              !isConnected || settings["statusLine"] == nil else { return }
        try? connect()
    }

    static var hasStatusLine: Bool {
        (try? read()).map { isOurStatusLine($0["statusLine"]) } ?? false
    }

    private static func isOurStatusLine(_ value: Any?) -> Bool {
        ((value as? [String: Any])?["command"] as? String)?.contains("Contents/Helpers/isle\" statusline") == true
    }

    static func disconnect() throws {
        var settings = try read()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        try backup()
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        if isOurStatusLine(settings["statusLine"]) { settings["statusLine"] = nil }
        try write(settings)
    }

    // MARK: File

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    private static func read() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable
        }
        return object
    }

    /// The previous file, next to it, before every change.
    private static func backup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else { return }
        let copy = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.isle-backup")
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: settingsURL, to: copy)
    }

    private static func write(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
