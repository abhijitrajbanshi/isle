import Foundation
import IsleKit
import Testing
@testable import Isle

@MainActor
struct TroubleTests {
    private func payload(_ name: String, session: String = "s1", tool: String? = nil, input: [String: Any] = [:]) -> [String: Any] {
        var p: [String: Any] = ["session_id": session, "cwd": "/code/\(session)", "hook_event_name": name]
        if let tool { p["tool_name"] = tool; p["tool_input"] = input }
        return p
    }

    @Test func sameFailingCommandThreeTimesLooksStuck() {
        let hub = ActivityHub()
        var notices: [NoticeInfo] = []
        hub.onNotice = { notices.append($0) }
        hub.claude(event: "UserPromptSubmit", payload: payload("UserPromptSubmit"))
        for _ in 0..<3 {
            hub.claude(event: "PostToolUseFailure", payload: payload("PostToolUseFailure", tool: "Bash", input: ["command": "npm test"]))
        }
        #expect(hub.live.first?.trouble == "“npm test” failed 3 times in a row")
        #expect(notices.count == 1)
        // it passes: no longer stuck
        hub.claude(event: "PostToolUse", payload: payload("PostToolUse", tool: "Bash", input: ["command": "npm test"]))
        #expect(hub.live.first?.trouble == nil)
    }

    @Test func repeatedCompactionLooksStuck() {
        let hub = ActivityHub()
        hub.claude(event: "UserPromptSubmit", payload: payload("UserPromptSubmit"))
        for _ in 0..<3 { hub.claude(event: "PreCompact", payload: payload("PreCompact")) }
        #expect(hub.live.first?.trouble?.hasPrefix("Compacted 3 times") == true)
        hub.claude(event: "UserPromptSubmit", payload: payload("UserPromptSubmit"))   // a new prompt starts afresh
        #expect(hub.live.first?.trouble == nil)
    }

    @Test func nearlyFullContextLooksStuck() {
        let hub = ActivityHub()
        hub.claude(event: "UserPromptSubmit", payload: payload("UserPromptSubmit"))
        hub.status(["session_id": "s1", "context_window": ["used_percentage": 93]])
        #expect(hub.live.first?.trouble == "Context 93% full")
    }

    @Test func silenceLooksStuck() async {
        let hub = ActivityHub()
        hub.silenceLimit = .milliseconds(40)
        hub.claude(event: "UserPromptSubmit", payload: payload("UserPromptSubmit"))
        #expect(await eventually { hub.live.first?.trouble?.hasPrefix("No activity") == true })
        hub.claude(event: "PreToolUse", payload: payload("PreToolUse", tool: "Read", input: ["file_path": "/a"]))
        #expect(hub.live.first?.trouble == nil)
    }

    @Test func twoSessionsEditingOneFileWarnOnce() {
        let hub = ActivityHub()
        var notices: [NoticeInfo] = []
        hub.onNotice = { notices.append($0) }
        for session in ["api", "web"] {
            hub.claude(event: "UserPromptSubmit", payload: payload("UserPromptSubmit", session: session))
        }
        let edit = { (session: String) in
            hub.claude(event: "PostToolUse", payload: self.payload("PostToolUse", session: session, tool: "Edit",
                                                                  input: ["file_path": "/code/shop/Checkout.swift"]))
        }
        edit("api"); edit("web"); edit("api"); edit("web")
        #expect(notices.count == 1)
        #expect(notices.first?.title.contains("Checkout.swift") == true)
    }

    @Test func xcodeBuildsReport() {
        let hub = ActivityHub()
        var finished: [FinishedInfo] = []
        hub.onFinish = { finished.append($0) }
        hub.xcodeStarted()
        #expect(hub.live.first?.title == "Xcode build")
        hub.xcodeFinished(succeeded: false)
        #expect(hub.live.isEmpty)
        #expect(finished.first?.title == "Build failed")
    }
}

struct DeployTests {
    @Test func readsDeploymentStatuses() {
        let preview = GitHubAPI.deploy(["environment": "Preview", "production_environment": false],
                                       latest: ["state": "success", "environment_url": "https://shop-git-x.vercel.app"])
        #expect(preview.state == .ready && preview.title == "Preview" && preview.url?.host == "shop-git-x.vercel.app")
        let production = GitHubAPI.deploy(["environment": "Production"], latest: ["state": "failure", "log_url": "https://vercel.com/x/logs"])
        #expect(production.isProduction && production.state == .failed && production.logs != nil)
        #expect(GitHubAPI.deploy(["environment": "staging"], latest: ["state": "in_progress"]).state == .building)
    }
}

@MainActor
struct ServersTests {
    @Test func parsesListeningPorts() {
        let listing = "p501\ncnode\nf20\nn*:3000\nf21\nn[::1]:3000\np502\ncControlCenter\nf10\nn*:7000\n"
        let parsed = ServersModel.parse(listing)
        #expect(parsed.map(\.port) == [3000, 3000, 7000])
        #expect(parsed.first?.program == "node")
    }

    /// A real server, found by a real scan.
    @Test func findsARealDevServer() async throws {
        let port = Int.random(in: 20000...29999)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        var found: ServersModel.Server?
        for _ in 0..<40 where found == nil {
            try await Task.sleep(for: .milliseconds(150))
            found = await ServersModel.scan().first { $0.port == port }
        }
        #expect(found?.program == "python")
        #expect(found?.pid == server.processIdentifier)
    }
}
