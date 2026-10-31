import AppKit
import Observation

/// Feeds `NowPlayingModel` from the best available source and routes the
/// model's commands back to it.
///
/// 1. MediaRemote bridge — every player, browsers included (see Helpers/).
/// 2. AppleScript — Music and Spotify, used whenever the bridge has nothing.
@MainActor
final class NowPlayingService {
    private enum Source: Equatable { case none, bridge, script(AppleScriptPlayers.Player) }

    private let model: NowPlayingModel
    private let preferences: Preferences
    private let bridge = MediaRemoteBridge()
    private let scripts = AppleScriptPlayers()
    private var source: Source = .none
    private var bridgeHasTrack = false
    private var bridgeRestarts = 0
    private var observers: [NSObjectProtocol] = []
    private var emptyTask: Task<Void, Never>?
    /// Players report "nothing playing" for a moment between tracks;
    /// only a longer silence ends the activity.
    private let emptyGrace: Duration = .milliseconds(1500)

    init(model: NowPlayingModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
    }

    func start() {
        model.perform = { [weak self] in self?.perform($0) }
        model.isEnabled = { [preferences] in preferences.nowPlaying }
        bridge.onMessage = { [weak self] in self?.receive($0) }
        bridge.onExit = { [weak self] in self?.bridgeExited(after: $0) }
        syncBridgeWithPreferences()

        observePlayers()
        refreshScripts()
    }

    /// Runs the bridge only while Now Playing and "all apps" are both on;
    /// re-arms on every change so Settings apply without a relaunch.
    private func syncBridgeWithPreferences() {
        let wanted = withObservationTracking {
            preferences.nowPlaying && preferences.allPlayers
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncBridgeWithPreferences() }
        }
        if wanted, !bridge.isRunning {
            bridgeRestarts = 0
            bridge.start()
        } else if !wanted, bridge.isRunning {
            bridge.stop()
            emptyTask?.cancel()
            emptyTask = nil
            bridgeHasTrack = false
            if source == .bridge { model.clear(); source = .none }
            refreshScripts()
        }
    }

    func stop() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        bridge.stop()
    }

    /// Music and Spotify announce every change; querying them only then means
    /// the fallback costs nothing while idle.
    private func observePlayers() {
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshScripts() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard let id, AppleScriptPlayers.Player(rawValue: id) != nil else { return }
                MainActor.assumeIsolated { self?.refreshScripts() }
            }
        }
    }

    private func refreshScripts() {
        Task { await pollScripts() }
    }

    // MARK: Commands

    private func perform(_ command: MediaCommand) {
        switch source {
        case .bridge:
            bridge.send(command)
        case .script(let player):
            Task { await scripts.perform(command, on: player) }
        case .none:
            return
        }
        // confirm quickly instead of waiting for the next poll
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            await self?.pollScripts()
        }
    }

    // MARK: Bridge

    private func receive(_ message: MediaRemoteBridge.Message) {
        switch message.type {
        case "ready":
            break
        case "info" where message.empty == true:
            guard bridgeHasTrack else { refreshScripts(); return }
            guard emptyTask == nil else { return }
            emptyTask = Task { [weak self, emptyGrace] in
                try? await Task.sleep(for: emptyGrace)
                guard !Task.isCancelled, let self else { return }
                self.emptyTask = nil
                self.bridgeHasTrack = false
                if self.source == .bridge { self.model.clear(); self.source = .none }
                self.refreshScripts()
            }
        case "info":
            emptyTask?.cancel()
            emptyTask = nil
            bridgeHasTrack = true
            source = .bridge
            let previous = model.track
            let track = NowPlayingModel.Track(
                title: message.title ?? "", artist: message.artist ?? "", album: message.album ?? "",
                duration: message.duration ?? 0, bundleID: Self.appBundleID(for: message.bundleID))
            model.update(track: track, isPlaying: message.playing ?? ((message.rate ?? 0) > 0),
                         elapsed: message.elapsed ?? 0,
                         timestamp: message.timestamp.map(Date.init(timeIntervalSince1970:)) ?? .now,
                         rate: message.rate ?? 1)
            if let base64 = message.artwork {
                model.setArtwork(Data(base64Encoded: base64), key: message.artworkKey)
            } else if message.artworkKey == nil, model.track != previous {
                // players drop artwork for a moment around play/pause;
                // only a new track without artwork clears it
                model.artworkUnavailable()
            }
        default:
            break
        }
    }

    private func bridgeExited(after uptime: TimeInterval) {
        emptyTask?.cancel()
        emptyTask = nil
        bridgeHasTrack = false
        if source == .bridge { model.clear(); source = .none }
        refreshScripts()
        // a bridge that ran for a while earns a fresh budget; a crash loop doesn't
        bridgeRestarts = uptime > 60 ? 1 : bridgeRestarts + 1
        guard bridgeRestarts < 4, preferences.allPlayers else { return }
        Task { [weak self, restarts = bridgeRestarts] in
            try? await Task.sleep(for: .seconds(restarts * 2))
            self?.bridge.start()
        }
    }

    /// Media often plays in a helper process; map it to the app the user knows.
    nonisolated static func appBundleID(for id: String?) -> String? {
        guard let id else { return nil }
        if id.hasPrefix("com.apple.WebKit") || id.hasPrefix("com.apple.Safari") { return "com.apple.Safari" }
        // Chromium helpers: com.google.Chrome.helper, com.brave.Browser.helper.renderer, …
        if let range = id.range(of: ".helper") { return String(id[..<range.lowerBound]) }
        return id
    }

    // MARK: AppleScript fallback

    private func pollScripts() async {
        guard preferences.nowPlaying, !(bridge.isRunning && bridgeHasTrack) else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = AppleScriptPlayers.Player.allCases.filter { running.contains($0.rawValue) }
        guard !candidates.isEmpty else {
            if case .script = source { model.clear(); source = .none }
            return
        }
        let snapshot = await scripts.snapshot(of: candidates)
        guard !(bridge.isRunning && bridgeHasTrack) else { return }
        guard let snapshot else {
            if case .script = source { model.clear(); source = .none }
            return
        }
        source = .script(snapshot.player)
        model.update(track: .init(title: snapshot.title, artist: snapshot.artist, album: snapshot.album,
                                  duration: snapshot.duration, bundleID: snapshot.player.rawValue),
                     isPlaying: snapshot.isPlaying, elapsed: snapshot.position, timestamp: .now)
        let key = "\(snapshot.player.rawValue)|\(snapshot.trackID)"
        if model.track?.title == snapshot.title, !model.hasArtworkKey || key != lastScriptArtworkKey {
            lastScriptArtworkKey = key
            let data = await scripts.artwork(of: snapshot.player)
            model.setArtwork(data, key: key)
        }
    }

    private var lastScriptArtworkKey: String?
}
