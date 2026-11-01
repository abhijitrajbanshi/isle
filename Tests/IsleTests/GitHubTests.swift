import Foundation
import Testing
@testable import Isle

@MainActor
struct GitHubTests {
    @Test(arguments: ["git push", "git push -u origin feature/x", "git -C ~/code/shop push", "npm test && git push",
                      "GIT_SSH_COMMAND=ssh git push --force-with-lease", "git -c core.sshCommand=ssh push"])
    func recognisesPushes(_ command: String) {
        #expect(ActivityHub.isPush(command))
    }

    @Test(arguments: ["git pull", "git status", "echo git push", "git log --grep push", "gitpush"])
    func ignoresEverythingElse(_ command: String) {
        #expect(!ActivityHub.isPush(command))
    }

    @Test func findsTheFolderAPushRanIn() {
        #expect(ActivityHub.pushFolder("cd /code/isle && git push", cwd: "/code/odoo") == "/code/isle")
        #expect(ActivityHub.pushFolder("git -C ~/code/shop push", cwd: "/x") == NSString("~/code/shop").expandingTildeInPath)
        #expect(ActivityHub.pushFolder("git push", cwd: "/code/api") == "/code/api")
        #expect(ActivityHub.pushFolder("cd sub && git push", cwd: "/code") == "/code/sub")
    }

    @Test func readsGitHubRemotes() {
        #expect(GitHubCLI.repository(fromRemote: "https://github.com/abhijitrajbanshi/isle.git\n") == "abhijitrajbanshi/isle")
        #expect(GitHubCLI.repository(fromRemote: "git@github.com:acme/shop.git") == "acme/shop")
        #expect(GitHubCLI.repository(fromRemote: "https://gitlab.com/acme/shop.git") == nil)
    }

    @Test func pushesFromTheShellAndAgentsStartCI() {
        let hub = ActivityHub()
        var pushes: [String] = []
        hub.onPush = { folder, _ in pushes.append(folder) }
        // a quick push still counts
        hub.shellStarted(id: "1", command: "git push", cwd: "/code/shop")
        hub.shellEnded(id: "1", status: 0)
        // a failed push doesn't
        hub.shellStarted(id: "2", command: "git push", cwd: "/code/shop")
        hub.shellEnded(id: "2", status: 1)
        // an agent's push
        hub.claude(event: "PostToolUse", payload: ["session_id": "s", "cwd": "/code/api", "tool_name": "Bash",
                                                   "tool_input": ["command": "git push origin main"]])
        #expect(pushes == ["/code/shop", "/code/api"])
    }

    @Test func runProgressAndFailure() {
        var run = GitHubModel.Run(repo: "o/r", branch: "main", sha: "abc", started: .now)
        run.checks = [.init(name: "build", done: true, failed: false, url: nil),
                      .init(name: "lint", done: true, failed: true, url: URL(string: "https://github.com/o/r/runs/1")),
                      .init(name: "test", done: false, failed: false, url: nil)]
        #expect(run.progress == 2.0 / 3.0)
        #expect(run.failing?.name == "lint")
    }
}
