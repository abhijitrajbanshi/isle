import AppKit
import CoreImage
import IsleKit
import Observation
import SwiftUI

enum MediaCommand: Sendable, Equatable {
    case togglePlayPause, next, previous
    case seek(Double)
}

/// What is playing, anywhere on the Mac. Sources write to it; views read it.
@MainActor
@Observable
final class NowPlayingModel {
    struct Track: Equatable, Sendable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var bundleID: String?
    }

    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    /// Vivid tint derived from the artwork, used by the waveform.
    private(set) var accent: Color = .white
    private(set) var lastPlayed: Date = .distantPast
    /// Set shortly after playback pauses; ends the live activity.
    private(set) var pauseExpired = false
    /// Playback position anchor; `elapsed(at:)` extrapolates from here at `rate`.
    private(set) var anchor: (elapsed: Double, date: Date, rate: Double) = (0, .distantPast, 1)

    @ObservationIgnored var perform: (MediaCommand) -> Void = { _ in }
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    /// After a click, players report their old state for a moment; until
    /// they confirm the change (or this deadline passes) those reports are
    /// stale and would flip the button back and forth.
    @ObservationIgnored private var expectedPlaying: (value: Bool, until: Date)?
    /// Same for a seek: players keep reporting the old position for a moment.
    @ObservationIgnored private var expectedPosition: (value: Double, until: Date)?
    @ObservationIgnored var toggleSettleTime: TimeInterval = 1.5
    @ObservationIgnored private var artworkClearTask: Task<Void, Never>?
    /// How long the previous track's artwork stays while the next one's loads.
    @ObservationIgnored var artworkGrace: Duration = .seconds(1)
    /// How long a paused track stays in the notch: long enough to ride out
    /// the brief pauses between tracks and videos without flickering.
    @ObservationIgnored var lingerDuration: Duration = .seconds(2)

    /// Stays in the notch while playing; leaves shortly after pausing. The
    /// paused track is still in the expanded island, to resume it.
    var isActive: Bool {
        isEnabled() && track != nil && (isPlaying || !pauseExpired)
    }

    private func playbackChanged() {
        lingerTask?.cancel()
        if isPlaying {
            lastPlayed = .now
            if pauseExpired { pauseExpired = false }
            return
        }
        lingerTask = Task { [weak self, lingerDuration] in
            try? await Task.sleep(for: lingerDuration)
            guard !Task.isCancelled else { return }
            self?.pauseExpired = true
        }
    }

    func elapsed(at date: Date = .now) -> Double {
        var value = anchor.elapsed
        if isPlaying { value += date.timeIntervalSince(anchor.date) * anchor.rate }
        let duration = track?.duration ?? 0
        return duration > 0 ? min(max(value, 0), duration) : max(value, 0)
    }

    // MARK: Intents

    func togglePlayPause() {
        // optimistic; the source confirms within a few hundred ms
        anchor = (elapsed(), .now, anchor.rate)
        isPlaying.toggle()
        expectedPlaying = (isPlaying, .now + toggleSettleTime)
        playbackChanged()
        perform(.togglePlayPause)
    }

    func next() { perform(.next) }
    func previous() { perform(.previous) }

    func seek(to seconds: Double) {
        anchor = (seconds, .now, anchor.rate)
        expectedPosition = (seconds, .now + toggleSettleTime)
        perform(.seek(seconds))
    }

    func openPlayer() {
        guard let id = track?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: Source updates

    /// - Parameter rate: playback speed (1 = normal); players report 0 while paused.
    func update(track next: Track, isPlaying reported: Bool, elapsed: Double, timestamp: Date, rate: Double = 1) {
        let isNewTrack = track != next
        var playing = reported
        if let expected = expectedPlaying {
            if reported == expected.value || isNewTrack || Date.now > expected.until {
                expectedPlaying = nil
            } else {
                playing = expected.value // stale report from before the click
            }
        }
        if isNewTrack { track = next; pauseExpired = false }
        let playingChanged = isPlaying != playing
        if playingChanged { isPlaying = playing }
        // a new track (including the first one seen, possibly already paused)
        // must start or stop the linger timer just like a play/pause change
        if playingChanged || isNewTrack { playbackChanged() }

        let speed = rate > 0 ? rate : 1
        let position = elapsed + (playing ? Date.now.timeIntervalSince(timestamp) * speed : 0)
        if let expected = expectedPosition {
            if abs(position - self.elapsed()) < 2 || isNewTrack || Date.now > expected.until {
                expectedPosition = nil
            } else {
                return // stale position from before the seek
            }
        }
        // ignore sub-second drift so views don't redraw for nothing
        if isNewTrack || abs(position - self.elapsed()) > 0.75 || anchor.rate != speed || anchor.date == .distantPast {
            anchor = (position, .now, speed)
        }
    }

    func setArtwork(_ data: Data?, key: String?) {
        guard key != artworkKey || key == nil else { return }
        artworkKey = key
        artworkClearTask?.cancel()
        artworkClearTask = nil
        guard let data, let image = NSImage(data: data) else {
            artwork = nil
            accent = .white
            return
        }
        artwork = image
        Task {
            let tint = await Task.detached(priority: .utility) { ArtworkPalette.accent(of: data) }.value
            guard self.artworkKey == key else { return }
            withAnimation(Motion.snappy) { self.accent = tint?.color ?? .white }
        }
    }

    /// The new track has no artwork (yet). Keeps the previous artwork
    /// briefly, since it usually arrives a moment after the title, instead
    /// of flashing the placeholder on every skip.
    func artworkUnavailable() {
        artworkKey = nil
        guard artwork != nil, artworkClearTask == nil else { return }
        artworkClearTask = Task { [weak self, artworkGrace] in
            try? await Task.sleep(for: artworkGrace)
            guard !Task.isCancelled, let self else { return }
            self.artworkClearTask = nil
            self.artwork = nil
            self.accent = .white
        }
    }

    var hasArtworkKey: Bool { artworkKey != nil }

    func clear() {
        lingerTask?.cancel()
        pauseExpired = false
        expectedPlaying = nil
        expectedPosition = nil
        artworkClearTask?.cancel()
        artworkClearTask = nil
        guard track != nil else { return }
        track = nil
        isPlaying = false
        artworkKey = nil
        artwork = nil
        accent = .white
    }

    /// Fixture for previews and snapshots.
    func preview(title: String, artist: String, playing: Bool, artwork: NSImage?, accent: Color) {
        track = Track(title: title, artist: artist, album: "", duration: 214, bundleID: "com.apple.Music")
        isPlaying = playing
        lastPlayed = .now
        anchor = (78, .now, 1)
        self.artwork = artwork
        self.accent = accent
    }
}

/// Accent extraction: average colour of the artwork, lifted so it stays
/// vivid against black (the way the iOS waveform is tinted).
enum ArtworkPalette {
    static func accent(of data: Data) -> IslandColor? {
        guard let input = CIImage(data: data),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let average = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                              blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        average.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.14 { return IslandColor(red: 0.92, green: 0.92, blue: 0.94) }
        let lifted = NSColor(hue: h, saturation: min(max(s * 1.2, 0.45), 0.8), brightness: max(b, 0.9), alpha: 1)
        return IslandColor(lifted)
    }
}
