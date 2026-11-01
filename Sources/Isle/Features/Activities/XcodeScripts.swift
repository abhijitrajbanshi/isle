import AppKit

/// The three scripts Xcode's Behaviors run (Build Starts / Succeeds / Fails),
/// each telling Isle in one line. Xcode has no public build events, and its
/// behaviour settings aren't something to edit behind your back, so you
/// pick these scripts in Xcode once.
enum XcodeScripts {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Isle/Xcode", isDirectory: true)
    }

    static let names = [("Build Started.sh", "started"), ("Build Succeeded.sh", "succeeded"), ("Build Failed.sh", "failed")]

    static var isInstalled: Bool {
        names.allSatisfy { FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent($0.0).path) }
    }

    /// Writes the scripts and shows them in Finder.
    static func install() throws {
        guard let helper = ClaudeConnector.helperPath else { throw ClaudeConnector.Failure.notBundled }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, event) in names {
            let url = folder.appendingPathComponent(name)
            try "#!/bin/sh\n# Isle: tells the notch about Xcode builds\nexec \"\(helper)\" xcode \(event)\n"
                .write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(names[0].0)])
    }
}
