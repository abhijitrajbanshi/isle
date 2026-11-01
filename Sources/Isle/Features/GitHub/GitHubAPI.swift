import Foundation

/// The few GitHub REST calls Isle makes, all conditional where GitHub allows
/// it (a 304 "unchanged" doesn't count against your rate limit).
enum GitHubAPI {
    struct CheckRuns: Sendable {
        let checks: [GitHubModel.Check]
        let etag: String?
    }

    struct Notifications: Sendable {
        /// nil when the feed hasn't changed since last time.
        let items: [GitHubModel.PullRequestItem]?
        /// Workflow runs you triggered that finished (pushes Isle didn't see).
        let ciRuns: [(title: String, repo: String, failed: Bool)]
        let lastModified: String?
        let pollInterval: Double
    }

    /// A commit's check runs; nil when it isn't on GitHub yet or nothing changed.
    static func checkRuns(repo: String, sha: String, token: String, etag: String?) async -> CheckRuns? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/commits/\(sha)/check-runs?per_page=100")!)
        authorize(&request, token: token)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let checks = (json["check_runs"] as? [[String: Any]] ?? []).map { run in
            let conclusion = run["conclusion"] as? String
            return GitHubModel.Check(
                name: run["name"] as? String ?? "Check",
                done: run["status"] as? String == "completed",
                failed: ["failure", "timed_out", "cancelled", "action_required", "startup_failure"].contains(conclusion ?? ""),
                url: (run["html_url"] as? String).flatMap(URL.init(string:)))
        }
        return CheckRuns(checks: checks, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    /// Notifications you're directly part of: review requests, your PRs, CI you triggered.
    static func notifications(token: String, since lastModified: String?) async -> Notifications? {
        var request = URLRequest(url: URL(string: "https://api.github.com/notifications?participating=true&per_page=50")!)
        authorize(&request, token: token)
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let interval = Double(http.value(forHTTPHeaderField: "X-Poll-Interval") ?? "") ?? 60
        let modified = http.value(forHTTPHeaderField: "Last-Modified")
        if http.statusCode == 304 {
            return Notifications(items: nil, ciRuns: [], lastModified: modified, pollInterval: interval)
        }
        guard http.statusCode == 200, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var items: [GitHubModel.PullRequestItem] = []
        var ciRuns: [(String, String, Bool)] = []
        let iso = ISO8601DateFormatter()
        for entry in list {
            guard let subject = entry["subject"] as? [String: Any],
                  let repo = (entry["repository"] as? [String: Any])?["full_name"] as? String else { continue }
            let title = subject["title"] as? String ?? ""
            let reason = entry["reason"] as? String ?? ""
            let unread = entry["unread"] as? Bool ?? false
            if subject["type"] as? String == "CheckSuite" || reason == "ci_activity" {
                if unread { ciRuns.append((title, repo, title.localizedCaseInsensitiveContains("fail"))) }
                continue
            }
            guard unread, subject["type"] as? String == "PullRequest",
                  let api = subject["url"] as? String, let number = Int((api as NSString).lastPathComponent),
                  let url = URL(string: "https://github.com/\(repo)/pull/\(number)") else { continue }
            let kind: GitHubModel.PullRequestItem.Kind = reason == "review_requested" ? .reviewRequested : .activity
            guard kind == .reviewRequested || reason == "author" else { continue }
            items.append(.init(id: entry["id"] as? String ?? api, title: title, repo: repo, number: number, url: url,
                               kind: kind, updated: iso.date(from: entry["updated_at"] as? String ?? "") ?? .now))
        }
        return Notifications(items: items, ciRuns: ciRuns, lastModified: modified, pollInterval: interval)
    }

    /// Whether the latest review on your PR approved it or asked for changes.
    static func latestReview(repo: String, number: Int, token: String) async -> GitHubModel.PullRequestItem.Kind? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/pulls/\(number)/reviews?per_page=100")!)
        authorize(&request, token: token)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let reviews = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        switch reviews.last(where: { ["APPROVED", "CHANGES_REQUESTED"].contains($0["state"] as? String ?? "") })?["state"] as? String {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        default: return nil
        }
    }

    private static func authorize(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 15
    }
}

/// The `gh` and `git` command lines: your login, and what a folder points at.
enum GitHubCLI {
    static func token() async -> String? {
        await run("gh", ["auth", "token"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static func login() async -> String? {
        await run("gh", ["api", "user", "-q", ".login"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The GitHub repository, branch and commit a folder is on.
    static func head(of folder: String) async -> (repo: String, branch: String, sha: String)? {
        async let remote = run("git", ["-C", folder, "remote", "get-url", "origin"])
        async let branch = run("git", ["-C", folder, "rev-parse", "--abbrev-ref", "HEAD"])
        async let sha = run("git", ["-C", folder, "rev-parse", "HEAD"])
        guard let url = await remote, let repo = repository(fromRemote: url),
              let branch = await branch, let sha = await sha else { return nil }
        return (repo, branch.trimmingCharacters(in: .whitespacesAndNewlines), sha.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "owner/name" from an https or ssh GitHub remote.
    static func repository(fromRemote remote: String) -> String? {
        var path = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.contains("github.com") else { return nil }
        if let range = path.range(of: "github.com/") ?? path.range(of: "github.com:") {
            path = String(path[range.upperBound...])
        }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        return parts.count == 2 ? "\(parts[0])/\(parts[1])" : nil
    }

    private static func run(_ tool: String, _ args: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [tool] + args
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
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}
