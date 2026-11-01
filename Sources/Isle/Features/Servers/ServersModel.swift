import AppKit
import Observation

/// Your dev servers on localhost: what's listening, from which project.
/// Read when you open the island, never on a timer.
@MainActor
@Observable
final class ServersModel {
    struct Server: Identifiable, Equatable {
        var id: Int { port }
        let port: Int
        let pid: pid_t
        let program: String
        /// The project folder it runs from, if it's in your home folder.
        let folder: String?

        var project: String? { folder.map { ($0 as NSString).lastPathComponent } }
        var url: URL { URL(string: "http://localhost:\(port)")! }
    }

    private(set) var servers: [Server] = []
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    @ObservationIgnored private var refreshing = false

    func refresh() async {
        guard isEnabled(), !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let found = await Self.scan()
        if found != servers { servers = found }
    }

    func open(_ server: Server) {
        NSWorkspace.shared.open(server.url)
    }

    /// Asks the server to quit (SIGTERM), then reads the ports again.
    func stop(_ server: Server) {
        kill(server.pid, SIGTERM)
        servers.removeAll { $0.pid == server.pid }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            await refresh()
        }
    }

    func preview(_ servers: [Server]) { self.servers = servers }

    // MARK: Scan

    /// Programs that are dev servers wherever they run.
    static let runtimes: Set<String> = [
        "node", "bun", "deno", "python", "python3", "Python", "ruby", "php", "java", "go", "dotnet", "beam.smp",
        "com.docke", "com.docker", "docker", "OrbStack", "postgres", "redis-ser", "redis-server", "mysqld", "mongod",
        "nginx", "caddy", "hugo", "uvicorn", "gunicorn", "puma", "rails", "next-serv", "vite", "esbuild", "air",
        "cargo", "flask", "jekyll", "ngrok", "odoo-bin",
    ]

    /// Listening TCP ports of your own processes, as `lsof` reports them.
    static func scan() async -> [Server] {
        guard let listing = await run(["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-u", "\(getuid())", "-Fpcn"]) else { return [] }
        let listeners = parse(listing)
        guard !listeners.isEmpty else { return [] }
        let pids = Set(listeners.map(\.pid)).map(String.init).joined(separator: ",")
        let folders = await run(["-a", "-p", pids, "-d", "cwd", "-Fpn"]).map(parseFolders) ?? [:]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var seen = Set<Int>()
        return listeners.compactMap { listener -> Server? in
            guard listener.port < 49152, seen.insert(listener.port).inserted else { return nil }
            let folder = folders[listener.pid]
            let inProject = folder.map { $0.hasPrefix(home + "/") && !$0.hasPrefix(home + "/Library") } ?? false
            // apps listen too (AirPlay, music, editors' helpers); keep dev runtimes and project processes
            guard runtimes.contains(listener.program) || (inProject && !listener.program.contains("Helper")) else {
                return nil
            }
            return Server(port: listener.port, pid: listener.pid, program: friendly(listener.program),
                          folder: inProject ? folder : nil)
        }
        .sorted { $0.port < $1.port }
    }

    /// `lsof -F pcn`: p<pid>, c<command>, n<address:port> lines.
    static func parse(_ listing: String) -> [(pid: pid_t, program: String, port: Int)] {
        var result: [(pid_t, String, Int)] = []
        var pid: pid_t = 0
        var program = ""
        for line in listing.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = pid_t(value) ?? 0
            case "c": program = value
            case "n":
                if let port = value.split(separator: ":").last.flatMap({ Int($0) }) { result.append((pid, program, port)) }
            default: break
            }
        }
        return result
    }

    static func parseFolders(_ listing: String) -> [pid_t: String] {
        var folders: [pid_t: String] = [:]
        var pid: pid_t = 0
        for line in listing.split(separator: "\n") {
            if line.hasPrefix("p") { pid = pid_t(line.dropFirst()) ?? 0 }
            if line.hasPrefix("n") { folders[pid] = String(line.dropFirst()) }
        }
        return folders
    }

    private static func friendly(_ program: String) -> String {
        switch program {
        case "com.docke", "com.docker": "Docker"
        case "Python": "python"
        case "redis-ser": "redis"
        case "next-serv": "next"
        default: program
        }
    }

    private static func run(_ args: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = args
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                // lsof exits 1 when one of several filters matches nothing; the output still counts
                continuation.resume(returning: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}
