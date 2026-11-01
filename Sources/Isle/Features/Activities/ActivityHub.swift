import AppKit
import IsleKit
import Observation

/// Everything you're waiting on: AI agents (Claude Code) and tasks posted
/// through the `isle` command (builds, scripts, downloads).
///
/// Fed by `ActivityServer`; nothing here polls. Elapsed times are drawn by
/// the views from `started`.
@MainActor
@Observable
final class ActivityHub {
    struct Activity: Identifiable, Equatable {
        enum Kind: Equatable { case agent, task }
        enum State: Equatable {
            case working
            /// Blocked on you: a permission request, a question or a plan.
            case needsYou
            /// Finished its turn and waiting for your next prompt.
            case yourTurn
            /// Finished, with changes to look at.
            case review
        }

        let id: String
        let kind: Kind
        /// The project (agents) or the task's name.
        var title: String
        /// What it's doing right now: "Editing IslandView.swift".
        var detail: String
        var state: State
        var progress: Double?
        var started: Date
        var request: PermissionRequest?
        /// The app running this session (Claude, a terminal, an editor).
        var host: pid_t? = nil
        /// The session's folder.
        var cwd: String = ""
        /// From Claude Code's status line.
        var meter: Meter? = nil
        /// The last test command it ran, and whether it passed.
        var lastTest: TestRun? = nil
        var review: Review? = nil
    }

    struct Meter: Equatable {
        var contextPercent: Double?
        var costUSD: Double?
        var linesAdded: Int?
        var linesRemoved: Int?
        var model: String?
    }

    struct TestRun: Equatable {
        var command: String
        var passed: Bool
    }

    /// What a finished session changed, for review.
    struct Review: Equatable {
        struct File: Equatable, Identifiable {
            var id: String { path }
            let path: String
            let added: Int
            let removed: Int
        }

        var summary: String
        var minutes: Int
        var files: [File] = []
        var added: Int = 0
        var removed: Int = 0
        var pullRequest: URL? = nil
        var loaded = false
    }

    /// Something an agent is blocked on.
    struct PermissionRequest: Equatable, Identifiable {
        enum Kind: Equatable {
            case permission
            /// AskUserQuestion: pick an option (per question).
            case question([Question])
            /// ExitPlanMode: approve the plan, or keep planning.
            case plan(String)
        }

        struct Question: Equatable {
            let text: String
            let header: String
            let options: [String]
            let multiSelect: Bool
        }

        let id: UUID
        /// "Run this command?", "Edit this file?"
        let question: String
        /// The command, file path or URL in question.
        let subject: String
        let tool: String
        var kind: Kind = .permission
        /// Claude's own "don't ask again" suggestion, as a button title.
        var alwaysTitle: String? = nil
        /// The tool's input, sent back with an answer.
        var inputJSON: Data? = nil
        var suggestionsJSON: Data? = nil
    }

    enum Decision: Equatable {
        case allow, deny
        /// Allow, and add Claude's suggested rule so it doesn't ask again.
        case allowAlways
        /// Answers to AskUserQuestion, by question text.
        case answers([String: String])
        /// Decline a plan and keep planning.
        case keepPlanning
    }

    /// Your Claude plan's limits, from the status line.
    struct Usage: Equatable {
        struct Window: Equatable {
            var used: Double
            var resetsAt: Date
        }

        var fiveHour: Window?
        var weekly: Window?
        var updated: Date
        /// When the 5-hour window runs out at the current pace, if before it resets.
        var capForecast: Date?
    }

    private(set) var activities: [Activity] = []
    private(set) var usage: Usage?
    /// Called when an agent or task finishes, to show the "done" banner.
    @ObservationIgnored var onFinish: (FinishedInfo) -> Void = { _ in }
    /// Called when an agent starts waiting on a decision.
    @ObservationIgnored var onRequest: () -> Void = {}
    /// Called when usage crosses 80% or 95% of a window.
    @ObservationIgnored var onLimit: (LimitInfo) -> Void = { _ in }
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    /// Gathers a finished session's changes (git, gh); replaceable in tests.
    @ObservationIgnored var inspectChanges: @Sendable (String) async -> ChangeSummary = { await ChangeSummary.inspect($0) }
    @ObservationIgnored private var hosts: [String: pid_t] = [:]
    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<Decision?, Never>] = [:]
    /// 5-hour usage samples for the forecast, in the current window.
    @ObservationIgnored private var samples: [(date: Date, used: Double)] = []
    @ObservationIgnored private var alerted: Set<String> = []
    /// The app in front. A session whose own app is in front isn't shown:
    /// you're already looking at it (the iPhone hides an app's Live
    /// Activity while the app is open, for the same reason).
    private(set) var frontmost: pid_t?
    /// Picks the hosting app from a hook's ancestor processes.
    @ObservationIgnored var resolveHost: ([pid_t]) -> pid_t? = { chain in
        chain.first { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }
    }

    /// Follows the frontmost app; event-driven.
    func start() {
        frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.activated(pid) }
        }
    }

    func activated(_ pid: pid_t?) {
        frontmost = pid
        // you switched to the session's own app: let it ask you itself
        for activity in activities where activity.request != nil && isInFront(activity) {
            if let request = activity.request { withdraw(request.id) }
        }
    }

    func isInFront(_ activity: Activity) -> Bool {
        activity.host != nil && activity.host == frontmost
    }

    /// Live: shown in the notch. Most urgent first.
    var live: [Activity] {
        guard isEnabled() else { return [] }
        return activities.filter { !isInFront($0) }.sorted { rank($0) < rank($1) }
    }

    var hasAgent: Bool { live.contains { $0.kind == .agent } }
    var hasTask: Bool { live.contains { $0.kind == .task } }
    var needsYou: Activity? { live.first { $0.state == .needsYou } }

    /// Usage worth showing beside the notch: a window at 80% or more.
    var isNearLimit: Bool {
        guard isEnabled(), let usage else { return false }
        return (usage.fiveHour?.used ?? 0) >= 80 || (usage.weekly?.used ?? 0) >= 90
    }

    private func rank(_ a: Activity) -> Int {
        switch a.state {
        case .needsYou: 0
        case .review: 1
        case .working: 2
        case .yourTurn: 3
        }
    }

    // MARK: Decisions

    /// Resolves a pending request from the island.
    func decide(_ request: PermissionRequest, _ decision: Decision) {
        waiting.removeValue(forKey: request.id)?.resume(returning: decision)
        guard let index = activities.firstIndex(where: { $0.request?.id == request.id }) else { return }
        activities[index].request = nil
        activities[index].state = .working
        switch decision {
        case .allow, .allowAlways: activities[index].detail = Self.doing(tool: request.tool, subject: request.subject)
        case .answers: activities[index].detail = "Thinking"
        case .keepPlanning: activities[index].detail = "Planning"
        case .deny: activities[index].detail = "Denied \(request.tool)"
        }
    }

    /// Waits for the island's answer; nil when the request is answered
    /// elsewhere (the terminal) or the agent moves on.
    func awaitDecision(_ request: PermissionRequest) async -> Decision? {
        await withCheckedContinuation { waiting[request.id] = $0 }
    }

    /// Drops a request that is no longer pending (timed out, answered in the terminal).
    func withdraw(_ id: UUID) {
        waiting.removeValue(forKey: id)?.resume(returning: nil)
        guard let index = activities.firstIndex(where: { $0.request?.id == id }) else { return }
        activities[index].request = nil
        if activities[index].state == .needsYou { activities[index].state = .working }
    }

    /// You've looked at a finished session's changes.
    func dismissReview(_ id: String) {
        activities.removeAll { $0.id == id && $0.state == .review }
    }

    /// Brings the session's app to the front.
    func focus(_ activity: Activity) {
        guard let host = activity.host else { return }
        NSRunningApplication(processIdentifier: host)?.activate()
    }

    // MARK: Claude Code hook events

    /// Applies one Claude Code hook event. Returns the request it raised, if
    /// any, for the server to wait on.
    @discardableResult
    func claude(event: String, payload: [String: Any], ancestors: [pid_t] = []) -> PermissionRequest? {
        guard let session = payload["session_id"] as? String else { return nil }
        if !ancestors.isEmpty, let host = resolveHost(ancestors) { hosts[session] = host }
        let cwd = payload["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent
        let tool = payload["tool_name"] as? String ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]

        switch event {
        case "UserPromptSubmit":
            upsert(session, title: project, cwd: cwd) {
                $0.state = .working
                $0.detail = "Thinking"
                $0.started = .now
                $0.review = nil
                $0.lastTest = nil
            }
        case "PreToolUse":
            upsert(session, title: project, cwd: cwd) {
                if $0.state != .needsYou { $0.state = .working }
                $0.detail = Self.doing(tool: tool, subject: Self.subject(tool: tool, input: input))
            }
        case "PostToolUse", "PostToolUseFailure":
            if tool == "Bash", let command = input["command"] as? String, Self.isTest(command) {
                upsert(session, title: project, cwd: cwd) {
                    $0.lastTest = TestRun(command: command, passed: event == "PostToolUse" && !Self.failed(payload))
                }
            }
        case "PermissionRequest":
            let request = Self.request(tool: tool, input: input, suggestions: payload["permission_suggestions"])
            upsert(session, title: project, cwd: cwd) {
                // a newer request replaces one still showing
                if let old = $0.request { self.withdraw(old.id) }
                $0.state = .needsYou
                $0.request = request
            }
            // the session's app is in front: it shows its own prompt, at once
            if let activity = activities.first(where: { $0.id == session }), isInFront(activity) {
                withdraw(request.id)
                return nil
            }
            onRequest()
            return request
        case "Notification":
            // the permission prompt itself arrives as PermissionRequest; idle_prompt is "your turn"
            let type = payload["notification_type"] as? String ?? ""
            let message = payload["message"] as? String ?? ""
            if type == "idle_prompt" || message.localizedCaseInsensitiveContains("waiting for your input") {
                upsert(session, title: project, cwd: cwd) {
                    if $0.state != .review { $0.state = .yourTurn; $0.detail = "Waiting for you" }
                }
            }
        case "Stop":
            guard let index = activities.firstIndex(where: { $0.id == session }) else { return nil }
            if let request = activities[index].request { withdraw(request.id) }
            finish(index, summary: payload["last_assistant_message"] as? String)
        case "SessionEnd":
            if let activity = activities.first(where: { $0.id == session }), let request = activity.request {
                withdraw(request.id)
            }
            activities.removeAll { $0.id == session }
            hosts[session] = nil
        default:
            break
        }
        return nil
    }

    /// A session stopped: keep it as "ready for review" with what it changed.
    private func finish(_ index: Int, summary: String?) {
        let activity = activities[index]
        let minutes = Int(Date.now.timeIntervalSince(activity.started) / 60)
        let line = (summary ?? "").split(separator: "\n").first.map(String.init) ?? ""
        activities[index].state = .review
        activities[index].detail = "Ready for review"
        activities[index].review = Review(summary: line, minutes: minutes,
                                          added: activity.meter?.linesAdded ?? 0,
                                          removed: activity.meter?.linesRemoved ?? 0)
        let id = activity.id, cwd = activity.cwd
        Task {
            let changes = await inspectChanges(cwd)
            guard let i = activities.firstIndex(where: { $0.id == id }), activities[i].state == .review else { return }
            activities[i].review?.files = changes.files
            if activities[i].review?.added == 0 && activities[i].review?.removed == 0 {
                activities[i].review?.added = changes.files.reduce(0) { $0 + $1.added }
                activities[i].review?.removed = changes.files.reduce(0) { $0 + $1.removed }
            }
            activities[i].review?.pullRequest = changes.pullRequest
            activities[i].review?.loaded = true
        }
        // you watched it finish
        guard !isInFront(activity) else { return }
        var detail = minutes >= 1 ? "Claude worked for \(minutes) min" : "Claude finished"
        if let test = activity.lastTest { detail += test.passed ? " · tests passed" : " · tests failed" }
        onFinish(FinishedInfo(title: "\(activity.title) is ready", detail: detail, symbol: "checkmark",
                              succeeded: activity.lastTest?.passed ?? true))
    }

    // MARK: Status line (usage, context, cost)

    /// One status line update from a Claude Code session.
    func status(_ payload: [String: Any], now: Date = .now) {
        if let session = payload["session_id"] as? String,
           let index = activities.firstIndex(where: { $0.id == session }) {
            let context = payload["context_window"] as? [String: Any]
            let cost = payload["cost"] as? [String: Any]
            let model = payload["model"] as? [String: Any]
            activities[index].meter = Meter(
                contextPercent: Self.double(context?["used_percentage"]),
                costUSD: Self.double(cost?["total_cost_usd"]),
                linesAdded: Self.double(cost?["total_lines_added"]).map(Int.init),
                linesRemoved: Self.double(cost?["total_lines_removed"]).map(Int.init),
                model: model?["display_name"] as? String)
        }
        guard let limits = payload["rate_limits"] as? [String: Any] else { return }
        func window(_ key: String) -> Usage.Window? {
            guard let w = limits[key] as? [String: Any], let used = Self.double(w["used_percentage"]),
                  let resets = Self.double(w["resets_at"]) else { return nil }
            return Usage.Window(used: used, resetsAt: Date(timeIntervalSince1970: resets))
        }
        let fiveHour = window("five_hour"), weekly = window("seven_day")
        // a new window starts the forecast afresh
        if fiveHour?.resetsAt != usage?.fiveHour?.resetsAt { samples = [] }
        if let fiveHour { samples.append((now, fiveHour.used)) }
        samples.removeAll { now.timeIntervalSince($0.date) > 30 * 60 }
        usage = Usage(fiveHour: fiveHour, weekly: weekly, updated: now,
                      capForecast: fiveHour.flatMap { Self.forecast(samples, window: $0) })
        if let fiveHour { alertIfCrossed(fiveHour, name: "5-hour") }
        if let weekly { alertIfCrossed(weekly, name: "weekly") }
    }

    /// When usage reaches 100% at the recent pace, if that's before the reset.
    static func forecast(_ samples: [(date: Date, used: Double)], window: Usage.Window) -> Date? {
        guard let first = samples.first, let last = samples.last,
              last.date.timeIntervalSince(first.date) >= 120, last.used > first.used else { return nil }
        let rate = (last.used - first.used) / last.date.timeIntervalSince(first.date)
        let cap = last.date.addingTimeInterval((100 - last.used) / rate)
        return cap < window.resetsAt ? cap : nil
    }

    private func alertIfCrossed(_ window: Usage.Window, name: String) {
        for threshold in [80, 95] where window.used >= Double(threshold) {
            let key = "\(name)-\(threshold)-\(Int(window.resetsAt.timeIntervalSince1970))"
            guard !alerted.contains(key) else { continue }
            alerted.insert(key)
            // the higher threshold says it all
            if threshold == 80, window.used >= 95 { continue }
            onLimit(LimitInfo(percent: Int(window.used), window: name, resetsAt: window.resetsAt))
        }
    }

    // MARK: Tasks (`isle run`, `isle progress`)

    func task(id: String, title: String, detail: String?, progress: Double?) {
        upsert(id, title: title, kind: .task) {
            $0.title = title
            if let detail { $0.detail = detail }
            $0.progress = progress.map { min(max($0, 0), 1) }
            $0.state = .working
        }
    }

    func taskFinished(id: String, succeeded: Bool, detail: String?) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        let activity = activities.remove(at: index)
        let seconds = Int(Date.now.timeIntervalSince(activity.started))
        let took = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
        onFinish(FinishedInfo(title: activity.title,
                              detail: detail ?? (succeeded ? "Done in \(took)" : "Failed after \(took)"),
                              symbol: succeeded ? "checkmark" : "xmark", succeeded: succeeded))
    }

    // MARK: Helpers

    private func upsert(_ id: String, title: String, kind: Activity.Kind = .agent, cwd: String = "",
                        _ change: (inout Activity) -> Void) {
        if let index = activities.firstIndex(where: { $0.id == id }) {
            change(&activities[index])
            if activities[index].host == nil { activities[index].host = hosts[id] }
            if activities[index].cwd.isEmpty { activities[index].cwd = cwd }
        } else {
            var activity = Activity(id: id, kind: kind, title: title, detail: "", state: .working,
                                    progress: nil, started: .now, request: nil, host: hosts[id], cwd: cwd)
            change(&activity)
            activities.append(activity)
        }
    }

    /// Builds the request a PermissionRequest event raises: a question, a
    /// plan, or a plain permission.
    static func request(tool: String, input: [String: Any], suggestions: Any?) -> PermissionRequest {
        let inputJSON = try? JSONSerialization.data(withJSONObject: input)
        var request = PermissionRequest(id: UUID(), question: question(tool: tool),
                                        subject: subject(tool: tool, input: input), tool: tool, inputJSON: inputJSON)
        switch tool {
        case "AskUserQuestion":
            let questions = (input["questions"] as? [[String: Any]] ?? []).map { q in
                PermissionRequest.Question(
                    text: q["question"] as? String ?? "",
                    header: q["header"] as? String ?? "",
                    options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                    multiSelect: q["multiSelect"] as? Bool ?? false)
            }
            if !questions.isEmpty { request.kind = .question(questions) }
        case "ExitPlanMode":
            request.kind = .plan(input["plan"] as? String ?? "")
        default:
            if let list = suggestions as? [[String: Any]], !list.isEmpty,
               let title = alwaysTitle(list) {
                request.alwaysTitle = title
                request.suggestionsJSON = try? JSONSerialization.data(withJSONObject: list)
            }
        }
        return request
    }

    /// "Always allow swift test", from Claude's own suggested rule.
    static func alwaysTitle(_ suggestions: [[String: Any]]) -> String? {
        guard let first = suggestions.first else { return nil }
        if first["type"] as? String == "setMode" { return "Allow edits this session" }
        if let rule = (first["rules"] as? [[String: Any]])?.first {
            let content = (rule["ruleContent"] as? String)?
                .replacingOccurrences(of: ":*", with: "").replacingOccurrences(of: "*", with: "")
            if let content, !content.isEmpty { return "Always allow \(content)" }
            if let tool = rule["toolName"] as? String { return "Always allow \(tool)" }
        }
        return "Always allow"
    }

    static func question(tool: String) -> String {
        switch tool {
        case "Bash": "Run this command?"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "Edit this file?"
        case "WebFetch", "WebSearch": "Go online?"
        case "ExitPlanMode": "Ready to start?"
        default: "Use \(tool)?"
        }
    }

    static func subject(tool: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String { return path }
        if let url = input["url"] as? String { return url }
        if let query = input["query"] as? String ?? input["pattern"] as? String { return query }
        if let description = input["description"] as? String { return description }
        return tool
    }

    static func doing(tool: String, subject: String) -> String {
        let name = (subject as NSString).lastPathComponent
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing \(name)"
        case "Read": return "Reading \(name)"
        case "Bash": return "Running \(subject.split(separator: " ").prefix(2).joined(separator: " "))"
        case "Grep", "Glob": return "Searching"
        case "WebFetch", "WebSearch": return "Browsing"
        case "Task", "Agent": return "Delegating"
        case "TodoWrite": return "Planning"
        case "AskUserQuestion": return "Asking you"
        default: return tool.isEmpty ? "Working" : tool
        }
    }

    /// Test runners worth reporting on.
    static func isTest(_ command: String) -> Bool {
        let patterns = ["swift test", "xcodebuild test", "npm test", "npm run test", "pnpm test", "yarn test",
                        "bun test", "pytest", "go test", "cargo test", "jest", "vitest", "rspec", "mix test",
                        "gradle test", "./gradlew test", "mvn test", "dotnet test", "phpunit"]
        return patterns.contains { command.contains($0) }
    }

    /// A Bash result that reports failure (non-zero exit or an error flag).
    private static func failed(_ payload: [String: Any]) -> Bool {
        guard let response = payload["tool_response"] as? [String: Any] else { return false }
        if let code = response["exit_code"] as? Int ?? response["exitCode"] as? Int { return code != 0 }
        return response["is_error"] as? Bool ?? response["interrupted"] as? Bool ?? false
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    func preview(_ activities: [Activity], usage: Usage? = nil) {
        self.activities = activities
        self.usage = usage
    }
}

/// What a finished session changed: files from git, and its pull request.
struct ChangeSummary: Sendable {
    var files: [ActivityHub.Review.File] = []
    var pullRequest: URL?

    /// Uncommitted changes (`git diff --numstat HEAD`) and the branch's open
    /// PR (`gh pr view`), each with a short timeout.
    static func inspect(_ folder: String) async -> ChangeSummary {
        guard !folder.isEmpty else { return ChangeSummary() }
        async let numstat = run("/usr/bin/env", ["git", "-C", folder, "diff", "--numstat", "HEAD"], in: folder)
        async let pr = run("/usr/bin/env", ["gh", "pr", "view", "--json", "url", "-q", ".url"], in: folder)
        let files = (await numstat ?? "").split(separator: "\n").compactMap { line -> ActivityHub.Review.File? in
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            return ActivityHub.Review.File(path: String(parts[2]), added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0)
        }
        let url = (await pr).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return ChangeSummary(files: files, pullRequest: url?.scheme == "https" ? url : nil)
    }

    private static func run(_ tool: String, _ args: [String], in folder: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: folder)
            // gh and git from Homebrew, even though apps don't inherit the shell's PATH
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            process.environment = env
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
            do { try process.run() } catch { continuation.resume(returning: nil); return }
            // never hang a review on a slow network
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { if process.isRunning { process.terminate() } }
        }
    }
}
