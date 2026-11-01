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
        hub.inspectChanges = { _ in ChangeSummary() }
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
        #expect(hub.live.first?.state == .review)
        #expect(finished.first?.title == "isle is ready")
        hub.dismissReview("s1")
        #expect(hub.live.isEmpty)
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
        hub.inspectChanges = { _ in ChangeSummary() }
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
        // and it doesn't turn up as "ready" once you switch away
        hub.activated(7)
        #expect(hub.live.isEmpty)
    }

    @Test func lookingAtTheSessionClearsItsReview() {
        let hub = hostedHub()
        hub.activated(7)
        hub.claude(event: "UserPromptSubmit", payload: event("UserPromptSubmit"), ancestors: [42])
        hub.claude(event: "Stop", payload: event("Stop"))
        #expect(hub.live.first?.state == .review)
        hub.activated(42)   // you opened Claude
        hub.activated(7)
        #expect(hub.live.isEmpty)
    }

    @Test func goToSessionClearsItsReview() {
        let hub = hostedHub()
        hub.activated(7)
        hub.claude(event: "UserPromptSubmit", payload: event("UserPromptSubmit"), ancestors: [42])
        hub.claude(event: "Stop", payload: event("Stop"))
        let activity = hub.live[0]
        hub.focus(activity)
        #expect(hub.live.isEmpty)
    }

    // MARK: Questions, plans, always allow

    @Test func questionsAreAnsweredWithTheChosenOption() throws {
        let input: [String: Any] = ["questions": [[
            "question": "Which provider?", "header": "Payments", "multiSelect": false,
            "options": [["label": "Stripe", "description": "in the project"], ["label": "Adyen", "description": ""]],
        ]]]
        let request = ActivityHub.request(tool: "AskUserQuestion", input: input, suggestions: nil)
        guard case .question(let questions) = request.kind else { Issue.record("not a question"); return }
        #expect(questions.first?.options == ["Stripe", "Adyen"])

        let reply = ActivityHub.answer(.answers(["Which provider?": "Stripe"]), to: request)
        #expect(reply["decision"] as? String == "allow")
        let updated = try #require(reply["updatedInput"] as? [String: Any])
        #expect((updated["answers"] as? [String: String])?["Which provider?"] == "Stripe")
        #expect((updated["questions"] as? [[String: Any]])?.count == 1)   // the original input is kept
    }

    @Test func planApprovalAndKeepPlanning() {
        let request = ActivityHub.request(tool: "ExitPlanMode", input: ["plan": "# Plan\n- Add tests"], suggestions: nil)
        #expect(request.kind == .plan("# Plan\n- Add tests"))
        #expect(ActivityHub.answer(.allow, to: request)["decision"] as? String == "allow")
        let keep = ActivityHub.answer(.keepPlanning, to: request)
        #expect(keep["decision"] as? String == "deny")
        #expect((keep["message"] as? String)?.contains("keep planning") == true)
    }

    @Test func alwaysAllowUsesClaudesOwnSuggestion() {
        let suggestion: [[String: Any]] = [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                            "rules": [["toolName": "Bash", "ruleContent": "swift test:*"]]]]
        let request = ActivityHub.request(tool: "Bash", input: ["command": "swift test"], suggestions: suggestion)
        #expect(request.alwaysTitle == "Always allow swift test")
        let reply = ActivityHub.answer(.allowAlways, to: request)
        #expect((reply["updatedPermissions"] as? [[String: Any]])?.first?["destination"] as? String == "localSettings")
        // no suggestion, no button
        #expect(ActivityHub.request(tool: "Bash", input: ["command": "ls"], suggestions: nil).alwaysTitle == nil)
    }

    // MARK: Usage

    private func statusPayload(used: Double, resets: Date, weekly: Double = 20) -> [String: Any] {
        ["session_id": "s1",
         "rate_limits": ["five_hour": ["used_percentage": used, "resets_at": resets.timeIntervalSince1970],
                         "seven_day": ["used_percentage": weekly, "resets_at": resets.addingTimeInterval(86_400).timeIntervalSince1970]],
         "context_window": ["used_percentage": 42], "cost": ["total_cost_usd": 1.25, "total_lines_added": 10]]
    }

    @Test func usageForecastsTheCapAndAlertsOnce() {
        let hub = ActivityHub()
        var limits: [LimitInfo] = []
        hub.onLimit = { limits.append($0) }
        hub.claude(event: "UserPromptSubmit", payload: event("UserPromptSubmit"))
        let start = Date.now
        let resets = start.addingTimeInterval(3 * 3600)
        hub.status(statusPayload(used: 60, resets: resets), now: start)
        hub.status(statusPayload(used: 70, resets: resets), now: start.addingTimeInterval(600))
        // 10 points per 10 minutes: from 70% at minute 10, 100% at minute 40, well before the reset
        let forecast = hub.usage?.capForecast
        #expect(forecast != nil && abs(forecast!.timeIntervalSince(start.addingTimeInterval(2400))) < 5)
        #expect(hub.live.first?.meter?.contextPercent == 42)
        #expect(!hub.isNearLimit)

        hub.status(statusPayload(used: 82, resets: resets), now: start.addingTimeInterval(900))
        hub.status(statusPayload(used: 84, resets: resets), now: start.addingTimeInterval(960))
        #expect(hub.isNearLimit)
        #expect(limits.map(\.percent) == [82])   // once per threshold and window
    }

    @Test func reviewGathersChanges() async {
        let hub = ActivityHub()
        hub.inspectChanges = { _ in
            ChangeSummary(files: [.init(path: "Sources/A.swift", added: 12, removed: 3)],
                          pullRequest: URL(string: "https://github.com/o/r/pull/7"))
        }
        hub.claude(event: "UserPromptSubmit", payload: event("UserPromptSubmit"))
        hub.claude(event: "PostToolUse", payload: event("PostToolUse", tool: "Bash", input: ["command": "swift test"]))
        hub.claude(event: "Stop", payload: event("Stop", extra: ["last_assistant_message": "Added tests.\nMore detail"]))
        #expect(await eventually { hub.live.first?.review?.loaded == true })
        let review = hub.live.first?.review
        #expect(review?.summary == "Added tests.")
        #expect(review?.added == 12 && review?.files.count == 1)
        #expect(review?.pullRequest?.lastPathComponent == "7")
        #expect(hub.live.first?.lastTest?.passed == true)
    }

    @Test func describesCommandsByTheirProgram() {
        #expect(ActivityHub.program("swift test --parallel") == "swift test")
        #expect(ActivityHub.program("S=/private/tmp/x; cd /code/isle && npm run build") == "npm run")
        #expect(ActivityHub.program("FOO=1 /usr/bin/make -j8") == "make")
        #expect(ActivityHub.program("cd /tmp") == "a command")
    }

    @Test func summariesArePlainText() {
        #expect(ActivityHub.plain("The work is pushed as **45da31f** in `main`.") == "The work is pushed as 45da31f in main.")
        #expect(ActivityHub.plain("## Done: [PR](https://x.y/1)") == "Done: PR")
    }
}
