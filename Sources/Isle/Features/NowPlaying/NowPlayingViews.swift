import SwiftUI

// MARK: Compact

struct NowPlayingCompactLeading: View {
    @Environment(NowPlayingModel.self) private var player
    let size: CGFloat

    var body: some View {
        ArtworkView(image: player.artwork, size: size, cornerRadius: size * 0.26)
            .scaleEffect(player.isPlaying ? 1 : 0.86)
            .saturation(player.isPlaying ? 1 : 0.4)
            .opacity(player.isPlaying ? 1 : 0.72)
            .animation(Motion.morph, value: player.isPlaying)
    }
}

struct NowPlayingCompactTrailing: View {
    @Environment(NowPlayingModel.self) private var player

    var body: some View {
        Waveform(color: player.accent, isPlaying: player.isPlaying, bars: 4, height: 12, barWidth: 2.4)
    }
}

struct NowPlayingBubble: View {
    @Environment(NowPlayingModel.self) private var player
    let diameter: CGFloat

    var body: some View {
        if player.artwork != nil {
            ArtworkView(image: player.artwork, size: diameter - 8, cornerRadius: (diameter - 8) / 2)
                .opacity(player.isPlaying ? 1 : 0.7)
        } else {
            Waveform(color: player.accent, isPlaying: player.isPlaying, bars: 3, height: 10, barWidth: 2.2)
        }
    }
}

// MARK: Expanded

struct NowPlayingCard: View {
    @Environment(NowPlayingModel.self) private var player
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if let track = player.track {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    artwork(for: track)
                    VStack(alignment: .leading, spacing: 1) {
                        MarqueeText(text: track.title.isEmpty ? "Not Playing" : track.title,
                                    font: .island(14.5, .semibold))
                        Text(track.artist.isEmpty ? track.album : track.artist)
                            .font(.island(13))
                            .foregroundStyle(Palette.secondaryLabel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Waveform(color: player.accent, isPlaying: player.isPlaying, bars: 5, height: 18, barWidth: 2.8)
                        .padding(.trailing, 2)
                }
                Spacer(minLength: 8)
                if track.duration > 0 {
                    Scrubber(duration: track.duration)
                }
                Spacer(minLength: 4)
                HStack(spacing: 30) {
                    IslandButton(symbol: "backward.fill", label: "Previous", size: 17, diameter: 36) { player.previous() }
                    IslandButton(symbol: player.isPlaying ? "pause.fill" : "play.fill",
                                 label: player.isPlaying ? "Pause" : "Play", size: 24, diameter: 42) {
                        player.togglePlayPause()
                    }
                    IslandButton(symbol: "forward.fill", label: "Next", size: 17, diameter: 36) { player.next() }
                }
            }
        } else {
            NothingPlaying()
        }
    }

    private func artwork(for track: NowPlayingModel.Track) -> some View {
        Button { player.openPlayer() } label: {
            ArtworkView(image: player.artwork, size: 52, cornerRadius: 12)
                .shadow(color: player.accent.opacity(player.artwork == nil ? 0 : 0.3), radius: 10, y: 2)
                .overlay(alignment: .bottomTrailing) {
                    if !isSnapshot, let icon = NSWorkspace.shared.appIcon(bundleID: track.bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 19, height: 19)
                            .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                            .offset(x: 5, y: 5)
                    }
                }
                .scaleEffect(player.isPlaying ? 1 : 0.93)
                .animation(Motion.morph, value: player.isPlaying)
        }
        .buttonStyle(PressableStyle())
        .help("Open \(track.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.deletingPathExtension().lastPathComponent } ?? "player")")
    }
}

private struct NothingPlaying: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.secondaryFill)
                Image(systemName: "music.note").font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.tertiaryLabel)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not Playing").font(.island(14.5, .semibold)).foregroundStyle(Palette.secondaryLabel)
                Text("Music, podcasts and videos appear here.")
                    .font(.island(12)).foregroundStyle(Palette.tertiaryLabel)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// Elapsed / progress / remaining, draggable to seek.
private struct Scrubber: View {
    @Environment(NowPlayingModel.self) private var player
    let duration: Double
    @State private var scrubbing: Double?
    @State private var isHovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = scrubbing ?? player.elapsed(at: context.date)
            HStack(spacing: 10) {
                Text(Clock.string(elapsed)).frame(width: 38, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.fill)
                        Capsule().fill(Color.white.opacity(scrubbing == nil ? 0.88 : 1))
                            .frame(width: geo.size.width * CGFloat(min(elapsed / duration, 1)))
                    }
                    .frame(height: isHovering || scrubbing != nil ? 7 : 4.5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { scrubbing = max(0, min(1, $0.location.x / geo.size.width)) * duration }
                        .onEnded { _ in
                            if let scrubbing { player.seek(to: scrubbing) }
                            scrubbing = nil
                        })
                }
                .frame(height: 14)
                Text("-" + Clock.string(max(0, duration - elapsed))).frame(width: 42, alignment: .trailing)
            }
            .font(.islandNumber(10.5, .medium))
            .foregroundStyle(Palette.secondaryLabel)
        }
        .onHover { isHovering = $0 }
        .animation(Motion.snappy, value: isHovering)
        .animation(Motion.snappy, value: scrubbing == nil)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Clock.string(player.elapsed()))
    }
}
