import AppKit
import IsleKit
import Observation

/// GitHub, through the `gh` login you already have: CI on what you push, and
/// pull requests waiting on you. Only things you caused or are blocked on.
///
/// Checks run only while one of your commits is in CI. Pull requests come
/// from the notifications feed at the interval GitHub asks for, with
/// conditional requests (an unchanged feed doesn't count against your rate
/// limit), and pause while the screen sleeps.
@MainActor
@Observable
final class GitHubModel {
    struct Check: Equatable {
        let name: String
        let done: Bool
        let failed: Bool
        let url: URL?
    }

    /// One pushed commit's CI.
    struct Run: Identifiable, Equatable {
        enum State: Equatable { case waiting, running, passed, failed }
        var id: String { "\(repo)@\(sha)" }
        let repo: String
        let branch: String
        let sha: String
        var state: State = .waiting
        var checks: [Check] = []
        let started: Date
        /// The app the push came from (a terminal, Claude), to step aside while it's in front.
        var host: pid_t?

        var failing: Check? { checks.first(where: \.failed) }
        var progress: Double? { checks.isEmpty ? nil : Double(checks.filter(\.done).count) / Double(checks.count) }
    }

    /// A pull request waiting on you, or news on yours.
    struct PullRequestItem: Identifiable, Equatable {
        enum Kind: Equatable { case reviewRequested, approved, changesRequested, activity }
        let id: String
        let title: String
        let repo: String
        let number: Int
        let url: URL
        var kind: Kind
        let updated: Date
    }

    private(set) var runs: [Run] = []
    private(set) var pullRequests: [PullRequestItem] = []
    private(set) var signedIn: String?

    @ObservationIgnored var onFinish: (FinishedInfo) -> Void = { _ in }
    @ObservationIgnored var onPullRequest: (PullRequestItem) -> Void = { _ in }
    @ObservationIgnored var ciEnabled: () -> Bool = { true }
    @ObservationIgnored var reviewsEnabled: () -> Bool = { true }
    /// Same rule as agents: nothing for a push whose app is in front.
    @ObservationIgnored var isInFront: (pid_t?) -> Bool = { _ in false }
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var watchers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var inboxTask: Task<Void, Never>?
    @ObservationIgnored private var lastModified: String?
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var screenAsleep = false

    var live: [Run] { ciEnabled() ? runs.filter { !isInFront($0.host) } : [] }

    func start() {
        Task {
            token = await GitHubCLI.token()
            signedIn = token == nil ? nil : await GitHubCLI.login()
            startInbox()
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenAsleep = true
                self?.inboxTask?.cancel()
            }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenAsleep = false
                self?.startInbox()
            }
        }
    }

    // MARK: CI

    /// A push from `folder` (the shell or an agent): watch its commit's checks.
    func pushed(from folder: String, host: pid_t? = nil) {
        guard ciEnabled(), token != nil else { return }
        Task {
            guard let target = await GitHubCLI.head(of: folder) else { return }
            let run = Run(repo: target.repo, branch: target.branch, sha: target.sha, started: .now, host: host)
            guard !runs.contains(where: { $0.id == run.id }) else { return }
            runs.removeAll { $0.repo == run.repo && $0.branch == run.branch && $0.state != .running }
            runs.append(run)
            watch(run.id)
        }
    }

    /// Checks every 15 s until every check is done: as soon as the push
    /// lands, and never after. Gives up if no CI shows up within 3 minutes.
    private func watch(_ id: String) {
        watchers[id]?.cancel()
        watchers[id] = Task { [weak self] in
            var etag: String?
            let deadline = Date.now.addingTimeInterval(45 * 60)
            while !Task.isCancelled, Date.now < deadline {
                try? await Task.sleep(for: .seconds(15), tolerance: .seconds(3))
                guard let self, let index = self.runs.firstIndex(where: { $0.id == id }), let token = self.token else { return }
                let run = self.runs[index]
                let response = await GitHubAPI.checkRuns(repo: run.repo, sha: run.sha, token: token, etag: etag)
                guard let response else { continue }       // not pushed yet, or unchanged
                etag = response.etag
                if response.checks.isEmpty {
                    if Date.now.timeIntervalSince(run.started) > 180 { self.runs.remove(at: index); return }
                    continue
                }
                self.runs[index].checks = response.checks
                let done = response.checks.allSatisfy(\.done)
                self.runs[index].state = done ? (response.checks.contains(where: \.failed) ? .failed : .passed) : .running
                if done {
                    self.finished(self.runs[index])
                    return
                }
            }
        }
    }

    private func finished(_ run: Run) {
        watchers[run.id] = nil
        if run.state == .passed {
            // a pass needs no follow-up: it leaves after a moment
            Task {
                try? await Task.sleep(for: .seconds(60))
                runs.removeAll { $0.id == run.id && $0.state == .passed }
            }
        }
        guard !isInFront(run.host) else { return }
        onFinish(FinishedInfo(
            title: run.state == .passed ? "CI passed · \(run.branch)" : "CI failed · \(run.branch)",
            detail: run.failing.map { "\($0.name) failed" } ?? "\(run.checks.count) checks",
            symbol: run.state == .passed ? "checkmark" : "xmark", succeeded: run.state == .passed))
    }

    func dismiss(_ run: Run) {
        watchers.removeValue(forKey: run.id)?.cancel()
        runs.removeAll { $0.id == run.id }
    }

    // MARK: Pull requests

    private func startInbox() {
        guard reviewsEnabled(), token != nil, !screenAsleep else { return }
        inboxTask?.cancel()
        inboxTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self, let token = self.token else { return }
                let interval = await self.refreshInbox(token: token, announce: !first)
                first = false
                try? await Task.sleep(for: .seconds(max(interval, 120)), tolerance: .seconds(20))
            }
        }
    }

    /// One pass over the notifications feed; returns the interval GitHub asks for.
    private func refreshInbox(token: String, announce: Bool) async -> Double {
        guard let response = await GitHubAPI.notifications(token: token, since: lastModified) else { return 120 }
        if let modified = response.lastModified { lastModified = modified }
        guard let items = response.items else { return response.pollInterval }   // unchanged
        var fresh: [PullRequestItem] = []
        for var item in items {
            if item.kind == .activity, let state = await GitHubAPI.latestReview(repo: item.repo, number: item.number, token: token) {
                item.kind = state
            }
            // only what you need to act on or would want to know
            guard item.kind != .activity else { continue }
            fresh.append(item)
        }
        let announced = fresh.filter { !seen.contains("\($0.id)-\($0.kind)") }
        announced.forEach { seen.insert("\($0.id)-\($0.kind)") }
        pullRequests = fresh.sorted { $0.updated > $1.updated }
        if announce { announced.forEach(onPullRequest) }
        // CI on pushes Isle didn't watch itself (an IDE, GitHub Desktop)
        if announce, ciEnabled() {
            for run in response.ciRuns where !runs.contains(where: { $0.repo == run.repo }) {
                let key = "ci-\(run.repo)-\(run.title)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                onFinish(FinishedInfo(title: run.title, detail: run.repo, symbol: run.failed ? "xmark" : "checkmark",
                                      succeeded: !run.failed))
            }
        }
        return response.pollInterval
    }

    func open(_ item: PullRequestItem) {
        NSWorkspace.shared.open(item.url)
        pullRequests.removeAll { $0.id == item.id }
    }

    func preview(runs: [Run], pullRequests: [PullRequestItem]) {
        self.runs = runs
        self.pullRequests = pullRequests
    }
}
