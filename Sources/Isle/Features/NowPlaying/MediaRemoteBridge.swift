import Foundation

private let log = Diagnostics(category: "NowPlaying")

/// Runs the MediaRemote bridge (Helpers/MediaRemoteBridge.m) inside the
/// Apple-signed /usr/bin/perl and exchanges JSON lines with it.
@MainActor
final class MediaRemoteBridge {
    struct Message: Decodable, Sendable {
        var type: String
        var empty: Bool?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var rate: Double?
        var playing: Bool?
        var timestamp: Double?
        var bundleID: String?
        var artwork: String?
        var artworkKey: String?

        private enum Key: String, CodingKey {
            case type, empty, title, artist, album, duration, elapsed, rate, playing, timestamp, bundleID, artwork, artworkKey
        }

        /// Field-by-field and type-tolerant: a single odd value (e.g. a flag
        /// sent as 1 instead of true) must never drop a whole update.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            type = try c.decode(String.self, forKey: .type)
            func flag(_ key: Key) -> Bool? {
                (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? (try? c.decodeIfPresent(Double.self, forKey: key)).map { $0 != 0 }
            }
            func text(_ key: Key) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
            func number(_ key: Key) -> Double? { try? c.decodeIfPresent(Double.self, forKey: key) }
            empty = flag(.empty)
            playing = flag(.playing)
            title = text(.title)
            artist = text(.artist)
            album = text(.album)
            bundleID = text(.bundleID)
            artwork = text(.artwork)
            artworkKey = text(.artworkKey)
            duration = number(.duration)
            elapsed = number(.elapsed)
            rate = number(.rate)
            timestamp = number(.timestamp)
        }
    }

    var onMessage: (Message) -> Void = { _ in }
    /// Called with how long the bridge ran, so callers can tell a crash loop
    /// from an occasional exit.
    var onExit: (_ uptime: TimeInterval) -> Void = { _ in }
    private(set) var isRunning = false
    private var launchedAt = Date.distantPast

    private var process: Process?
    private var input: FileHandle?
    private var readTask: Task<Void, Never>?

    func start() {
        guard !isRunning,
              let script = Bundle.main.url(forResource: "mediaremote", withExtension: "pl"),
              let library = Bundle.main.url(forResource: "libIsleMediaRemote", withExtension: "dylib")
        else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path]
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        let stderr = Pipe()
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // EOF: release the handler, or it is called again immediately, forever
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            log.error("bridge stderr: \(String(decoding: data.prefix(500), as: UTF8.self))")
        }
        process.terminationHandler = { [weak self] p in
            log.error("bridge exited, status \(p.terminationStatus)")
            Task { @MainActor in self?.exited() }
        }

        do { try process.run() } catch {
            log.error("bridge failed to launch: \(error.localizedDescription)")
            return
        }
        log.notice("bridge launched, pid \(process.processIdentifier)")
        self.process = process
        input = stdin.fileHandleForWriting
        isRunning = true
        launchedAt = .now

        // decode off the main actor; artwork lines are large
        let output = stdout.fileHandleForReading
        readTask = Task.detached { [weak self] in
            let decoder = JSONDecoder()
            do {
                for try await line in output.bytes.lines {
                    guard let message = try? decoder.decode(Message.self, from: Data(line.utf8)) else {
                        log.error("bridge sent undecodable line: \(line.prefix(200))")
                        continue
                    }
                    await self?.deliver(message)
                }
            } catch {}
        }
    }

    func stop() {
        readTask?.cancel()
        try? input?.close()
        process?.terminate()
        process = nil
        isRunning = false
    }

    func send(_ command: MediaCommand) {
        let line = switch command {
        case .togglePlayPause: "toggle"
        case .next: "next"
        case .previous: "prev"
        case .seek(let seconds): String(format: "seek %.2f", seconds)
        }
        // SIGPIPE is ignored app-wide, so a dead bridge surfaces as a thrown EPIPE here
        try? input?.write(contentsOf: Data((line + "\n").utf8))
    }

    private func deliver(_ message: Message) { onMessage(message) }

    private func exited() {
        guard isRunning else { return }
        isRunning = false
        process = nil
        input = nil
        onExit(Date.now.timeIntervalSince(launchedAt))
    }
}

/// Music and Spotify over AppleScript. An actor, so slow Apple Events never
/// touch the main thread.
actor AppleScriptPlayers {
    enum Player: String, CaseIterable, Sendable {
        case spotify = "com.spotify.client"
        case music = "com.apple.Music"

        var name: String { self == .music ? "Music" : "Spotify" }
    }

    struct Snapshot: Sendable {
        var player: Player
        var isPlaying: Bool
        var title, artist, album: String
        var duration, position: Double
        var trackID: String
    }

    /// The playing player, or the first one with a paused track.
    func snapshot(of candidates: [Player]) -> Snapshot? {
        var paused: Snapshot?
        for player in candidates {
            guard let s = query(player) else { continue }
            if s.isPlaying { return s }
            paused = paused ?? s
        }
        return paused
    }

    func artwork(of player: Player) async -> Data? {
        if player == .music {
            return run(on: player, "return raw data of artwork 1 of current track")?.data
        }
        guard let string = run(on: player, "return artwork url of current track")?.stringValue,
              let url = URL(string: string), url.scheme == "https" else { return nil }
        // async: a slow CDN must not block the actor (and every other query)
        return try? await URLSession.shared.data(from: url).0
    }

    func perform(_ command: MediaCommand, on player: Player) {
        let verb = switch command {
        case .togglePlayPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        case .seek(let s): String(format: "set player position to %.2f", s)
        }
        _ = run(on: player, verb)
    }

    private func query(_ player: Player) -> Snapshot? {
        let id = player == .music ? "persistent ID" : "id"
        let body = """
            if player state is stopped then return {"stopped"}
            set t to current track
            return {player state as string, name of t, artist of t, album of t, (duration of t) as string, (player position) as string, (\(id) of t) as string}
        """
        guard let list = run(on: player, body), list.numberOfItems >= 7 else { return nil }
        let f = (1...list.numberOfItems).map { list.atIndex($0)?.stringValue ?? "" }
        let number: (String) -> Double = { Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return Snapshot(player: player, isPlaying: f[0] == "playing", title: f[1], artist: f[2], album: f[3],
                        duration: number(f[4]) / (player == .spotify ? 1000 : 1),
                        position: number(f[5]), trackID: f[6])
    }

    /// Runs `body` inside `tell application …`, but only if the player is
    /// running *at that moment*: a bare `tell` would relaunch a player the
    /// user just quit. Short timeout so a hung player can't stall the actor.
    private func run(on player: Player, _ body: String) -> NSAppleEventDescriptor? {
        run("""
        if application "\(player.name)" is running then
            with timeout of 3 seconds
                tell application "\(player.name)"
                    \(body)
                end tell
            end timeout
        end if
        """)
    }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
