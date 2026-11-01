import Darwin
import Foundation

// `isle`: reports to the Isle island over its local socket.
//
//   isle hook claude                      Claude Code hook (reads the event on stdin)
//   isle statusline                       Claude Code status line (usage, context, cost)
//   isle run [--title T] -- command…      run a command as a live activity
//   isle progress ID FRACTION [--title T] [--detail D]
//   isle done ID [--failed] [--detail D]
//
// When Isle isn't running every command is a silent no-op (and `run` still
// runs the command), so scripts and hooks never break because of it.

let socketPath: String = {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("Isle/isle.sock").path
}()

/// Sends one JSON line and returns the reply, or nil when Isle isn't listening.
func send(_ message: [String: Any]) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: socketPath.utf8)
        buffer[socketPath.utf8.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0, var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
    data.append(0x0A)
    let sent = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard sent == data.count else { return nil }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        reply.append(contentsOf: buffer[0..<count])
        if buffer[0..<count].contains(0x0A) { break }
    }
    return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
}

/// This process's ancestors, nearest first: the app hosting the Claude
/// session (Claude, a terminal, an editor) is among them.
func ancestors() -> [Int32] {
    var chain: [Int32] = []
    var pid = getppid()
    while pid > 1, chain.count < 24 {
        chain.append(pid)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        pid = info.kp_eproc.e_ppid
    }
    return chain
}

func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: isle run [--title T] -- command [args…]
           isle progress ID FRACTION [--title T] [--detail D]
           isle done ID [--failed] [--detail D]
           isle hook claude

    """.utf8))
    exit(64)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch command {
case "hook":
    // Claude Code passes the event as JSON on stdin.
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
          let event = payload["hook_event_name"] as? String else { exit(0) }
    let reply = send(["kind": "claude", "event": event, "payload": payload, "ancestors": ancestors()])
    // Only a permission request gets a decision; anything else (or no
    // answer) prints nothing, so Claude carries on as normal.
    if event == "PermissionRequest", let behavior = reply?["decision"] as? String,
       behavior == "allow" || behavior == "deny" {
        var decision: [String: Any] = ["behavior": behavior]
        if behavior == "deny" { decision["message"] = reply?["message"] as? String ?? "Denied from the Isle notch." }
        if let input = reply?["updatedInput"] { decision["updatedInput"] = input }
        if let rules = reply?["updatedPermissions"] { decision["updatedPermissions"] = rules }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        if let data = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(data)
        }
    }
    exit(0)

case "shell-init":
    // Printed into zsh by `source <(isle shell-init zsh)`: reports each
    // command's start and end in the background (`&!`: no job messages, and
    // still a child of the shell, so Isle can tell which terminal it's in).
    let me = CommandLine.arguments[0]
    print(#"""
    zmodload zsh/datetime 2>/dev/null
    typeset -g __isle_cmd="" __isle_id=""
    __isle_preexec() {
      __isle_cmd="$1"; __isle_id="$$-$EPOCHREALTIME"
      "\#(me)" shell start "$__isle_id" "$PWD" "$1" >/dev/null 2>&1 &!
    }
    __isle_precmd() {
      local isle_status=$?
      [[ -z $__isle_id ]] && return
      "\#(me)" shell end "$__isle_id" "$isle_status" >/dev/null 2>&1 &!
      __isle_id=""
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook preexec __isle_preexec
    add-zsh-hook precmd __isle_precmd
    """#)
    exit(0)

case "shell":
    // isle shell start ID FOLDER COMMAND… | isle shell end ID STATUS
    guard args.count >= 3 else { usage() }
    if args[1] == "start", args.count >= 4 {
        _ = send(["kind": "shell", "op": "start", "id": args[2], "cwd": args[3],
                  "command": args[4...].joined(separator: " "), "ancestors": ancestors()])
    } else if args[1] == "end" {
        _ = send(["kind": "shell", "op": "end", "id": args[2], "status": Int(args.count > 3 ? args[3] : "0") ?? 0])
    }
    exit(0)

case "xcode":
    // Xcode Behaviors: `isle xcode started|succeeded|failed`
    guard args.count >= 2, ["started", "succeeded", "failed"].contains(args[1]) else { usage() }
    _ = send(["kind": "xcode", "op": args[1], "ancestors": ancestors()])
    exit(0)

case "statusline":
    // Claude Code's status line: forward the session's numbers to Isle, and
    // print a short line for Claude Code to show.
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
    _ = send(["kind": "status", "payload": payload])
    var parts: [String] = []
    if let model = (payload["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
    if let context = (payload["context_window"] as? [String: Any])?["used_percentage"] as? Double {
        parts.append("context \(Int(context))%")
    }
    if let five = ((payload["rate_limits"] as? [String: Any])?["five_hour"] as? [String: Any])?["used_percentage"]
        as? Double {
        parts.append("5h \(Int(five))%")
    }
    print(parts.joined(separator: " · "))
    exit(0)

case "run":
    guard let dash = args.firstIndex(of: "--"), dash + 1 < args.count else { usage() }
    let argv = Array(args[(dash + 1)...])
    let title = option("--title", in: Array(args[..<dash])) ?? argv.joined(separator: " ")
    let id = UUID().uuidString
    _ = send(["kind": "task", "op": "start", "id": id, "title": title, "detail": "Running"])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = argv
    // let Ctrl-C reach the child, then report it as failed
    signal(SIGINT, SIG_IGN)
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        _ = send(["kind": "task", "op": "done", "id": id, "ok": false, "detail": "Couldn't start \(argv[0])"])
        FileHandle.standardError.write(Data("isle: \(error.localizedDescription)\n".utf8))
        exit(127)
    }
    let status = process.terminationStatus
    _ = send(["kind": "task", "op": "done", "id": id, "ok": status == 0])
    exit(status)

case "progress":
    guard args.count >= 3, let fraction = Double(args[2]) else { usage() }
    var message: [String: Any] = ["kind": "task", "op": "progress", "id": args[1],
                                  "progress": fraction > 1 ? fraction / 100 : fraction,
                                  "title": option("--title", in: args) ?? args[1]]
    if let detail = option("--detail", in: args) { message["detail"] = detail }
    _ = send(message)

case "done":
    guard args.count >= 2 else { usage() }
    var message: [String: Any] = ["kind": "task", "op": "done", "id": args[1], "ok": !args.contains("--failed")]
    if let detail = option("--detail", in: args) { message["detail"] = detail }
    _ = send(message)

default:
    usage()
}
