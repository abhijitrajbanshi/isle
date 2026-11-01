import Darwin
import Foundation

/// The local endpoint the `isle` command talks to: a Unix socket in
/// Application Support, readable only by this user. One JSON line in, one
/// JSON line out per connection.
///
/// Each connection gets its own thread, which sleeps in `read` or on the
/// main actor's answer; the accept loop sleeps in `accept`. Nothing polls.
final class ActivityServer: Sendable {
    static var socketPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Isle/isle.sock").path
    }

    private let handler: @Sendable (Data) async -> Data

    /// - Parameter handler: turns a request line into a reply line (on any actor).
    init(handler: @escaping @Sendable (Data) async -> Data) {
        self.handler = handler
    }

    func start() {
        let path = Self.socketPath
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        chmod(path, 0o600)

        let handler = handler
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else {
                    if errno == EINTR { continue }
                    return
                }
                Thread.detachNewThread { Self.serve(client, handler: handler) }
            }
        }
    }

    private static func serve(_ client: Int32, handler: @escaping @Sendable (Data) async -> Data) {
        defer { close(client) }
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard let line = readLine(client) else { return }
        let semaphore = DispatchSemaphore(value: 0)
        let reply = Reply()
        Task {
            reply.data = await handler(line)
            semaphore.signal()
        }
        semaphore.wait()
        var out = reply.data ?? Data("{}".utf8)
        out.append(0x0A)
        out.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(client, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    /// Reads up to the first newline (or EOF); requests are small.
    private static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count < 4_000_000 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[0..<newline])
                return data
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data.isEmpty ? nil : data
    }

    private final class Reply: @unchecked Sendable {
        var data: Data?
    }
}

extension ActivityHub {
    /// How long the island waits for you before Claude shows its own prompt.
    static let decisionWindow: Duration = .seconds(45)

    /// One request from the `isle` command; returns the reply line.
    func handle(_ line: Data) async -> Data {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let kind = message["kind"] as? String else { return Self.reply(["ok": false]) }
        Self.capture(message, line: line)
        switch kind {
        case "claude":
            let event = message["event"] as? String ?? ""
            let payload = message["payload"] as? [String: Any] ?? [:]
            let ancestors = (message["ancestors"] as? [Int] ?? []).map { pid_t($0) }
            guard let request = claude(event: event, payload: payload, ancestors: ancestors) else {
                // nothing to decide, or the session's app is in front and will ask itself
                return Self.reply(event == "PermissionRequest" ? ["decision": NSNull()] : ["ok": true])
            }
            let decision = await withTaskGroup(of: Decision?.self) { group in
                group.addTask { await self.awaitDecision(request) }
                group.addTask {
                    try? await Task.sleep(for: Self.decisionWindow)
                    await self.withdraw(request.id)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            // no decision: Claude shows its normal prompt
            return Self.reply(Self.answer(decision, to: request))
        case "status":
            status(message["payload"] as? [String: Any] ?? [:])
            return Self.reply(["ok": true])
        case "task":
            let id = message["id"] as? String ?? UUID().uuidString
            let title = message["title"] as? String ?? "Task"
            switch message["op"] as? String {
            case "done":
                taskFinished(id: id, succeeded: message["ok"] as? Bool ?? true, detail: message["detail"] as? String)
            default:
                task(id: id, title: title, detail: message["detail"] as? String,
                     progress: message["progress"] as? Double)
            }
            return Self.reply(["ok": true])
        default:
            return Self.reply(["ok": false])
        }
    }

    /// Developer aid (`defaults write com.avhiejeet.Isle debugHooks -bool true`):
    /// keeps the last message of each kind in Application Support/Isle/hooks.
    private static func capture(_ message: [String: Any], line: Data) {
        guard UserDefaults.standard.bool(forKey: "debugHooks") else { return }
        let name = (message["event"] as? String) ?? (message["kind"] as? String) ?? "unknown"
        let tool = ((message["payload"] as? [String: Any])?["tool_name"] as? String).map { "-\($0)" } ?? ""
        let folder = (ActivityServer.socketPath as NSString).deletingLastPathComponent + "/hooks"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? line.write(to: URL(fileURLWithPath: "\(folder)/\(name)\(tool).json"))
    }

    /// The decision as the `isle` command passes it to Claude Code: a
    /// behaviour, plus updated input (answers) or permissions (always allow).
    static func answer(_ decision: Decision?, to request: PermissionRequest) -> [String: Any] {
        func json(_ data: Data?) -> Any? { data.flatMap { try? JSONSerialization.jsonObject(with: $0) } }
        switch decision {
        case nil:
            return ["decision": NSNull()]
        case .allow:
            return ["decision": "allow"]
        case .deny:
            return ["decision": "deny", "message": "Denied from the Isle notch."]
        case .keepPlanning:
            return ["decision": "deny", "message": "The user wants to keep planning before you start."]
        case .allowAlways:
            var reply: [String: Any] = ["decision": "allow"]
            if let rules = json(request.suggestionsJSON) { reply["updatedPermissions"] = rules }
            return reply
        case .answers(let answers):
            var input = json(request.inputJSON) as? [String: Any] ?? [:]
            input["answers"] = answers
            return ["decision": "allow", "updatedInput": input]
        }
    }

    private static func reply(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}
