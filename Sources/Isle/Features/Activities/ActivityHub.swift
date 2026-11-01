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
            /// Blocked on a decision (a permission request).
            case needsYou
            /// Finished its turn and waiting for your next prompt.
            case yourTurn
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
    }

    struct PermissionRequest: Equatable, Identifiable {
        let id: UUID
        /// "Run a command?", "Edit a file?"
        let question: String
        /// The command, file path or URL in question.
        let subject: String
        let tool: String
    }

    enum Decision: String { case allow, deny }

    private(set) var activities: [Activity] = []
    /// Called when an agent or task finishes, to show the "done" banner.
    @ObservationIgnored var onFinish: (FinishedInfo) -> Void = { _ in }
    /// Called when an agent starts waiting on a decision.
    @ObservationIgnored var onRequest: () -> Void = {}
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    @ObservationIgnored private var hosts: [String: pid_t] = [:]
    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<Decision?, Never>] = [:]
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

    private func rank(_ a: Activity) -> Int {
        switch a.state {
        case .needsYou: 0
        case .working: 1
        case .yourTurn: 2
        }
    }

    // MARK: Decisions

    /// Resolves a pending permission request from the island.
    func decide(_ request: PermissionRequest, _ decision: Decision) {
        waiting.removeValue(forKey: request.id)?.resume(returning: decision)
        guard let index = activities.firstIndex(where: { $0.request?.id == request.id }) else { return }
        activities[index].request = nil
        activities[index].state = .working
        activities[index].detail = decision == .allow ? Self.doing(tool: request.tool, subject: request.subject)
                                                      : "Denied \(request.tool)"
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

    // MARK: Claude Code hook events

    /// Applies one Claude Code hook event. Returns the permission request it
    /// raised, if any, for the server to wait on.
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
            upsert(session, title: project) {
                $0.state = .working
                $0.detail = "Thinking"
                $0.started = .now
            }
        case "PreToolUse":
            upsert(session, title: project) {
                if $0.state != .needsYou { $0.state = .working }
                $0.detail = Self.doing(tool: tool, subject: Self.subject(tool: tool, input: input))
            }
        case "PermissionRequest":
            let request = PermissionRequest(id: UUID(), question: Self.question(tool: tool),
                                            subject: Self.subject(tool: tool, input: input), tool: tool)
            upsert(session, title: project) {
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
                upsert(session, title: project) { $0.state = .yourTurn; $0.detail = "Waiting for you" }
            }
        case "Stop":
            guard let index = activities.firstIndex(where: { $0.id == session }) else { return nil }
            let activity = activities[index]
            if let request = activity.request { withdraw(request.id) }
            activities.remove(at: index)
            hosts[session] = nil
            // you watched it finish
            if isInFront(activity) { return nil }
            let minutes = Int(Date.now.timeIntervalSince(activity.started) / 60)
            onFinish(FinishedInfo(title: "\(project) is ready",
                                  detail: minutes >= 1 ? "Claude worked for \(minutes) min" : "Claude finished",
                                  symbol: "checkmark", succeeded: true))
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

    private func upsert(_ id: String, title: String, kind: Activity.Kind = .agent, _ change: (inout Activity) -> Void) {
        if let index = activities.firstIndex(where: { $0.id == id }) {
            change(&activities[index])
            if activities[index].host == nil { activities[index].host = hosts[id] }
        } else {
            var activity = Activity(id: id, kind: kind, title: title, detail: "", state: .working,
                                    progress: nil, started: .now, request: nil, host: hosts[id])
            change(&activity)
            activities.append(activity)
        }
    }

    static func question(tool: String) -> String {
        switch tool {
        case "Bash": "Run this command?"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "Edit this file?"
        case "WebFetch", "WebSearch": "Go online?"
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
        default: return tool.isEmpty ? "Working" : tool
        }
    }

    func preview(_ activities: [Activity]) {
        self.activities = activities
    }
}
