import Foundation
import IsleKit
import Testing
@testable import Isle

@MainActor
struct ActivityHubTests {
    private func event(_ name: String, tool: String? = nil, input: [String: Any] = [:],
                       extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/code/isle", "hook_event_name": name]
        if let tool { payload["tool_name"] = tool; payload["tool_input"] = input }
        return payload.merging(extra) { $1 }
    }

    @Test func agentLifecycle() {
        let hub = ActivityHub()
        var finished: [FinishedInfo] = []
        hub.onFinish = { finished.append($0) }

        hub.claude(event: "UserPromptSubmit", payload: event("UserPromptSubmit"))
        #expect(hub.live.first?.title == "isle")
        #expect(hub.live.first?.state == .working)

        hub.claude(event: "PreToolUse", payload: event("PreToolUse", tool: "Edit",
                                                       input: ["file_path": "/x/IslandView.swift"]))
        #expect(hub.live.first?.detail == "Editing IslandView.swift")

        hub.claude(event: "Notification", payload: event("Notification", extra: ["notification_type": "idle_prompt"]))
        #expect(hub.live.first?.state == .yourTurn)

        hub.claude(event: "Stop", payload: event("Stop"))
        #expect(hub.live.isEmpty)
        #expect(finished.first?.title == "isle is ready")
    }

    @Test func permissionRequestWaitsForTheIsland() async {
        let hub = ActivityHub()
        hub.claude(event: "UserPromptSubmit", payload: event("UserPromptSubmit"))
        let request = hub.claude(event: "PermissionRequest",
                                 payload: event("PermissionRequest", tool: "Bash", input: ["command": "swift test"]))
        #expect(request?.subject == "swift test")
        #expect(request?.question == "Run this command?")
        #expect(hub.needsYou != nil)

        guard let request else { return }
        async let decision = hub.awaitDecision(request)
        await Task.yield()
        hub.decide(request, .allow)
        #expect(await decision == .allow)
        #expect(hub.needsYou == nil)
        #expect(hub.live.first?.detail == "Running swift test")
    }

    @Test func withdrawnRequestFallsBackToClaude() async {
        let hub = ActivityHub()
        let request = hub.claude(event: "PermissionRequest",
                                 payload: event("PermissionRequest", tool: "WebFetch", input: ["url": "https://a.b"]))
        guard let request else { Issue.record("no request"); return }
        async let decision = hub.awaitDecision(request)
        await Task.yield()
        hub.withdraw(request.id)
        #expect(await decision == nil)
        #expect(hub.needsYou == nil)
    }

    @Test func requestsOutrankWorkingAgents() {
        let hub = ActivityHub()
        hub.claude(event: "UserPromptSubmit", payload: event("UserPromptSubmit", extra: ["session_id": "a"]))
        hub.claude(event: "PermissionRequest",
                   payload: event("PermissionRequest", tool: "Bash", input: ["command": "ls"], extra: ["session_id": "b"]))
        #expect(hub.live.first?.id == "b")
    }

    @Test func tasksReportProgressAndFinish() {
        let hub = ActivityHub()
        var finished: [FinishedInfo] = []
        hub.onFinish = { finished.append($0) }
        hub.task(id: "t", title: "Build", detail: nil, progress: 1.4)
        #expect(hub.live.first?.progress == 1)
        hub.taskFinished(id: "t", succeeded: false, detail: nil)
        #expect(hub.live.isEmpty)
        #expect(finished.first?.succeeded == false)
    }

    @Test func handlesSocketMessages() async throws {
        let hub = ActivityHub()
        let line = try JSONSerialization.data(withJSONObject: ["kind": "task", "op": "start", "id": "x", "title": "Render"])
        let reply = await hub.handle(line)
        #expect(String(decoding: reply, as: UTF8.self).contains("true"))
        #expect(hub.live.first?.title == "Render")
    }

    // MARK: The session's own app in front

    private func hostedHub() -> ActivityHub {
        let hub = ActivityHub()
        hub.resolveHost = { $0.first }   // the first ancestor is "the app"
        return hub
    }

    @Test func hidesSessionWhileItsAppIsInFront() {
        let hub = hostedHub()
        hub.claude(event: "UserPromptSubmit", payload: event("UserPromptSubmit"), ancestors: [42])
        hub.activated(42)
        #expect(hub.live.isEmpty)
        hub.activated(7)
        #expect(hub.live.count == 1)
    }

    @Test func appInFrontAsksForItself() {
        let hub = hostedHub()
        var opened = false
        hub.onRequest = { opened = true }
        hub.activated(42)
        let request = hub.claude(event: "PermissionRequest",
                                 payload: event("PermissionRequest", tool: "Bash", input: ["command": "ls"]),
                                 ancestors: [42])
        #expect(request == nil)
        #expect(!opened)
        #expect(hub.needsYou == nil)
    }

    @Test func switchingToTheAppHandsTheRequestBack() async {
        let hub = hostedHub()
        hub.activated(7)
        let request = hub.claude(event: "PermissionRequest",
                                 payload: event("PermissionRequest", tool: "Bash", input: ["command": "ls"]),
                                 ancestors: [42])
        guard let request else { Issue.record("no request"); return }
        async let decision = hub.awaitDecision(request)
        await Task.yield()
        hub.activated(42)
        #expect(await decision == nil)
    }

    @Test func noDoneBannerWhenYouWatchedItFinish() {
        let hub = hostedHub()
        var finished = 0
        hub.onFinish = { _ in finished += 1 }
        hub.claude(event: "UserPromptSubmit", payload: event("UserPromptSubmit"), ancestors: [42])
        hub.activated(42)
        hub.claude(event: "Stop", payload: event("Stop"))
        #expect(finished == 0)
    }
}
