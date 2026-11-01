import Foundation
import IsleKit
import Testing
@testable import Isle

@MainActor
struct ShellCommandTests {
    private func hub() -> ActivityHub {
        let hub = ActivityHub()
        hub.longCommand = .milliseconds(30)
        return hub
    }

    @Test func shortCommandsNeverShow() async {
        let hub = hub()
        var finished = 0
        hub.onFinish = { _ in finished += 1 }
        hub.shellStarted(id: "1", command: "ls -la", cwd: "/tmp")
        hub.shellEnded(id: "1", status: 0)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(hub.live.isEmpty)
        #expect(finished == 0)
    }

    @Test func longCommandsShowThenReport() async {
        let hub = hub()
        var finished: [FinishedInfo] = []
        hub.onFinish = { finished.append($0) }
        hub.shellStarted(id: "2", command: "npm test", cwd: "/Users/me/shop")
        #expect(await eventually { hub.live.first?.title == "npm test" })
        #expect(hub.live.first?.detail == "shop")
        hub.shellEnded(id: "2", status: 1)
        #expect(hub.live.isEmpty)
        #expect(finished.first?.succeeded == false)
        #expect(finished.first?.detail.contains("exit 1") == true)
    }

    @Test func ctrlCIsNotAFailure() async {
        let hub = hub()
        var finished = 0
        hub.onFinish = { _ in finished += 1 }
        hub.shellStarted(id: "3", command: "make", cwd: "/tmp")
        #expect(await eventually { !hub.live.isEmpty })
        hub.shellEnded(id: "3", status: 130)
        #expect(finished == 0)
    }

    @Test(arguments: ["vim notes.md", "ssh box", "EDITOR=vim git commit --amend && vim x", "sudo htop",
                      "tail -f app.log", "npm run dev --watch", "claude"])
    func interactiveProgramsAreIgnored(_ command: String) {
        #expect(ActivityHub.isInteractive(command))
    }

    @Test(arguments: ["npm install", "swift build", "FOO=1 make release", "time cargo test", "docker compose build"])
    func buildsAndScriptsAreTracked(_ command: String) {
        #expect(!ActivityHub.isInteractive(command))
    }
}

@MainActor
struct ShellConnectorTests {
    @Test func connectsAndDisconnectsWithoutTouchingTheRest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("isle-zsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            ShellConnector.fileOverride = nil
            ShellConnector.helperOverride = nil
        }
        let rc = folder.appendingPathComponent(".zshrc")
        let original = "export PATH=$HOME/bin:$PATH\nalias gs='git status'\n"
        try original.write(to: rc, atomically: true, encoding: .utf8)
        ShellConnector.fileOverride = rc
        ShellConnector.helperOverride = "/Applications/Isle.app/Contents/Helpers/isle"

        try ShellConnector.connect()
        #expect(ShellConnector.isConnected)
        try ShellConnector.connect()   // twice is still once
        let connected = try String(contentsOf: rc, encoding: .utf8)
        #expect(connected.components(separatedBy: "shell-init zsh").count == 2)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".zshrc.isle-backup").path))

        try ShellConnector.disconnect()
        #expect(!ShellConnector.isConnected)
        #expect(try String(contentsOf: rc, encoding: .utf8) == original)
    }
}
