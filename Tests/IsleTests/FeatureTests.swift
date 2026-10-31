import AppKit
import IsleKit
import Testing
@testable import Isle

// MARK: - Now Playing bridge protocol

struct BridgeMessageTests {
    private func decode(_ json: String) throws -> MediaRemoteBridge.Message {
        try JSONDecoder().decode(MediaRemoteBridge.Message.self, from: Data(json.utf8))
    }

    /// Regression: MediaRemote's `Boolean` reached JSON as 1, and strict Bool
    /// decoding silently dropped every track update.
    @Test func acceptsNumericFlags() throws {
        let message = try decode(#"{"type":"info","title":"Song","playing":1,"rate":1}"#)
        #expect(message.playing == true)
        #expect(try decode(#"{"type":"info","playing":0}"#).playing == false)
        #expect(try decode(#"{"type":"info","playing":true}"#).playing == true)
    }

    @Test func oneBadFieldDoesNotDropTheMessage() throws {
        let message = try decode(#"{"type":"info","title":42,"artist":"Artist","duration":"long"}"#)
        #expect(message.title == nil)
        #expect(message.artist == "Artist")
        #expect(message.duration == nil)
    }

    @Test func emptyMessage() throws {
        let message = try decode(#"{"type":"info","empty":true}"#)
        #expect(message.empty == true)
        #expect(message.title == nil)
    }

    @Test func missingTypeIsRejected() {
        #expect(throws: (any Error).self) { try decode(#"{"title":"x"}"#) }
    }
}

struct BundleMappingTests {
    @Test(arguments: [
        ("com.apple.WebKit.GPU", "com.apple.Safari"),
        ("com.google.Chrome.helper.renderer", "com.google.Chrome"),
        ("com.brave.Browser.helper", "com.brave.Browser"),
        ("com.brave.Browser", "com.brave.Browser"),
        ("com.spotify.client", "com.spotify.client"),
    ])
    func mapsHelpersToApps(id: String, expected: String) {
        #expect(NowPlayingService.appBundleID(for: id) == expected)
    }
}

// MARK: - Now Playing model

@MainActor
struct NowPlayingModelTests {
    private let track = NowPlayingModel.Track(title: "Song", artist: "Artist", album: "", duration: 200, bundleID: nil)

    /// Regression: a track already paused when Isle launched never left the notch.
    @Test func pausedAtLaunchStillLeavesTheNotch() async throws {
        let model = NowPlayingModel()
        model.lingerDuration = .milliseconds(20)
        model.update(track: track, isPlaying: false, elapsed: 10, timestamp: .now)
        #expect(model.isActive)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!model.isActive)
    }

    @Test func playingStaysActive() async throws {
        let model = NowPlayingModel()
        model.lingerDuration = .milliseconds(20)
        model.update(track: track, isPlaying: true, elapsed: 10, timestamp: .now)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.isActive)
    }

    @Test func resumingCancelsTheLinger() async throws {
        let model = NowPlayingModel()
        model.lingerDuration = .milliseconds(60)
        model.update(track: track, isPlaying: false, elapsed: 10, timestamp: .now)
        model.update(track: track, isPlaying: true, elapsed: 10, timestamp: .now)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.isActive)
    }

    @Test func elapsedHonoursPlaybackRate() {
        let model = NowPlayingModel()
        let start = Date.now
        model.update(track: track, isPlaying: true, elapsed: 10, timestamp: start, rate: 2)
        let later = model.elapsed(at: Date.now.addingTimeInterval(5))
        #expect(abs(later - 20) < 0.5)
    }

    @Test func elapsedIsClampedToDuration() {
        let model = NowPlayingModel()
        model.update(track: track, isPlaying: true, elapsed: 190, timestamp: .now)
        #expect(model.elapsed(at: Date.now.addingTimeInterval(60)) == 200)
    }

    @Test func disabledHidesActivity() {
        let model = NowPlayingModel()
        model.isEnabled = { false }
        model.update(track: track, isPlaying: true, elapsed: 0, timestamp: .now)
        #expect(!model.isActive)
    }

    /// Regression: the player's stale "still playing" report right after a
    /// click flipped the button back, so it flickered pause → play → pause.
    @Test func staleReportAfterToggleIsIgnored() {
        let model = NowPlayingModel()
        model.update(track: track, isPlaying: true, elapsed: 10, timestamp: .now)
        model.togglePlayPause()
        #expect(!model.isPlaying)
        model.update(track: track, isPlaying: true, elapsed: 10, timestamp: .now)
        #expect(!model.isPlaying)
        model.update(track: track, isPlaying: false, elapsed: 10, timestamp: .now)
        // confirmed: later reports are trusted again
        model.update(track: track, isPlaying: true, elapsed: 10, timestamp: .now)
        #expect(model.isPlaying)
    }

    @Test func toggleThatNeverLandsGivesWay() {
        let model = NowPlayingModel()
        model.toggleSettleTime = 0
        model.update(track: track, isPlaying: true, elapsed: 10, timestamp: .now)
        model.togglePlayPause()
        model.update(track: track, isPlaying: true, elapsed: 10, timestamp: .now)
        #expect(model.isPlaying)
    }

    /// Regression: the old position, reported just after a seek, snapped
    /// the scrubber back before it jumped forward again.
    @Test func stalePositionAfterSeekIsIgnored() {
        let model = NowPlayingModel()
        model.update(track: track, isPlaying: false, elapsed: 10, timestamp: .now)
        model.seek(to: 120)
        model.update(track: track, isPlaying: false, elapsed: 10, timestamp: .now)
        #expect(abs(model.elapsed() - 120) < 0.5)
        model.update(track: track, isPlaying: false, elapsed: 120.3, timestamp: .now)
        // confirmed: later reports are trusted again
        model.update(track: track, isPlaying: false, elapsed: 30, timestamp: .now)
        #expect(abs(model.elapsed() - 30) < 0.5)
    }

    /// Regression: every skip flashed the placeholder before the new artwork.
    @Test func artworkSurvivesUntilTheNextArrives() async throws {
        let model = NowPlayingModel()
        model.artworkGrace = .milliseconds(40)
        let png = try #require(NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }.tiffRepresentation)
        model.setArtwork(png, key: "a")
        model.artworkUnavailable()
        #expect(model.artwork != nil)
        model.setArtwork(png, key: "b")
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.artwork != nil)
        model.artworkUnavailable()
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.artwork == nil)
    }

    @Test func clearRemovesTrack() {
        let model = NowPlayingModel()
        model.update(track: track, isPlaying: true, elapsed: 0, timestamp: .now)
        model.clear()
        #expect(model.track == nil && !model.isActive)
    }
}

// MARK: - Timer

@MainActor
struct TimerModelTests {
    @Test func lifecycle() {
        let timer = TimerModel()
        #expect(!timer.isActive)
        timer.start(300)
        #expect(timer.isRunning)
        #expect(abs(timer.remaining() - 300) < 1)
        timer.toggle()
        #expect(!timer.isRunning && timer.isActive)
        let paused = timer.remaining()
        timer.addMinute()
        #expect(abs(timer.remaining() - (paused + 60)) < 0.01)
        timer.cancel()
        #expect(!timer.isActive && timer.remaining() == 0)
    }

    @Test func finishes() async throws {
        let timer = TimerModel()
        var finished = false
        timer.onFinish = { finished = true }
        timer.start(0.05)
        try await Task.sleep(for: .milliseconds(300))
        #expect(finished && !timer.isActive)
    }

    @Test func countdownTicksOnWholeSeconds() {
        let now = Date.now
        let end = now.addingTimeInterval(3.4)
        let ticks = Array(CountdownSchedule(end: end).entries(from: now, mode: .normal))
        #expect(ticks.count == 5) // through 0:00, when it fires
        #expect(ticks.first! <= now)
        #expect(ticks.map { TimerModel.displayed(end.timeIntervalSince($0)) } == [4, 3, 2, 1, 0].map(Double.init))
        #expect(Array(CountdownSchedule(end: nil).entries(from: now, mode: .normal)) == [now])
    }

    @Test func fractionCountsDown() {
        let timer = TimerModel()
        timer.start(100)
        #expect(timer.fraction() > 0.99)
        #expect(abs(timer.fraction(at: Date.now.addingTimeInterval(50)) - 0.5) < 0.02)
    }
}

// MARK: - Shelf

@MainActor
struct ShelfModelTests {
    private func scratch() throws -> (UserDefaults, URL) {
        let suite = "isle.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (defaults, directory)
    }

    private func file(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test func addsWithoutDuplicatesAndPersists() throws {
        let (defaults, directory) = try scratch()
        let a = try file("a.txt", in: directory), b = try file("b.txt", in: directory)
        let shelf = ShelfModel(defaults: defaults)
        shelf.add([a, b, a])
        shelf.add([b])
        #expect(shelf.items.map(\.url) == [a, b])
        #expect(ShelfModel(defaults: defaults).items.map(\.url) == [a, b])
    }

    @Test func prunesDeletedFiles() throws {
        let (defaults, directory) = try scratch()
        let a = try file("a.txt", in: directory), b = try file("b.txt", in: directory)
        let shelf = ShelfModel(defaults: defaults)
        shelf.add([a, b])
        try FileManager.default.removeItem(at: a)
        shelf.pruneMissing()
        #expect(shelf.items.map(\.url) == [b])
        #expect(ShelfModel(defaults: defaults).items.map(\.url) == [b])
    }

    @Test func ignoresNonFileURLs() throws {
        let (defaults, _) = try scratch()
        let shelf = ShelfModel(defaults: defaults)
        shelf.add([URL(string: "https://apple.com")!])
        #expect(shelf.items.isEmpty)
    }
}

// MARK: - Preferences

@MainActor
struct PreferencesTests {
    @Test func defaultsAndPersistence() throws {
        let defaults = try #require(UserDefaults(suiteName: "isle.tests.\(UUID().uuidString)"))
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.style == .glass)
        #expect(preferences.expandOnHover)
        preferences.style = .black
        preferences.hoverDelay = 0.3
        preferences.capsLockAlerts = false
        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.style == .black)
        #expect(reloaded.hoverDelay == 0.3)
        #expect(!reloaded.capsLockAlerts)
    }
}

// MARK: - Alert copy

struct AlertCopyTests {
    @Test(arguments: [(300.0, "In 5 minutes"), (60.0, "In 1 minute"), (20.0, "Starting now"), (-30.0, "Starting now")])
    func eventLeadTime(seconds: Double, expected: String) {
        let now = Date.now
        #expect(AlertCopy.startsIn(now.addingTimeInterval(seconds), now: now) == expected)
    }
}
