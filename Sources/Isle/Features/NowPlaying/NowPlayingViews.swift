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

/// Artwork with its colour glowing beneath it; title, artist and position
/// beside it; transport controls below.
struct NowPlayingCard: View {
    @Environment(NowPlayingModel.self) private var player
    @Environment(\.ambience) private var ambience
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if let track = player.track {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    artwork(for: track)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .center, spacing: 8) {
                            MarqueeText(text: track.title.isEmpty ? "Not Playing" : track.title,
                                        font: .island(16, .semibold))
                            Waveform(color: ambience.accent, isPlaying: player.isPlaying, bars: 4, height: 13,
                                     barWidth: 2.4)
                        }
                        Text(track.artist.isEmpty ? track.album : track.artist)
                            .font(.island(13, .medium))
                            .foregroundStyle(ambience.tint.opacity(0.72))
                            .lineLimit(1)
                            .padding(.top, 1)
                        Spacer(minLength: 0)
                        if track.duration > 0 {
                            Scrubber(duration: track.duration)
                        }
                    }
                    .frame(height: 68)
                }
                Spacer(minLength: 6)
                HStack(spacing: 34) {
                    IslandButton(symbol: "backward.fill", label: "Previous", size: 17, tint: ambience.tint,
                                 diameter: 38) { player.previous() }
                    PlayButton()
                    IslandButton(symbol: "forward.fill", label: "Next", size: 17, tint: ambience.tint,
                                 diameter: 38) { player.next() }
                }
            }
        } else {
            NothingPlaying()
        }
    }

    private func artwork(for track: NowPlayingModel.Track) -> some View {
        Button { player.openPlayer() } label: {
            ArtworkView(image: player.artwork, size: 68, cornerRadius: 15)
                .overlay(alignment: .bottomTrailing) {
                    if !isSnapshot, let icon = NSWorkspace.shared.appIcon(bundleID: track.bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                            .offset(x: 5, y: 5)
                    }
                }
                .scaleEffect(player.isPlaying ? 1 : 0.92)
                .animation(Motion.morph, value: player.isPlaying)
        }
        .buttonStyle(PressableStyle())
        .help("Open \(track.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.deletingPathExtension().lastPathComponent } ?? "player")")
    }
}

/// The focal control: a pale disc in the scene's tint, glyph in its deep colour.
private struct PlayButton: View {
    @Environment(NowPlayingModel.self) private var player
    @Environment(\.ambience) private var ambience
    @State private var isHovering = false

    var body: some View {
        Button { player.togglePlayPause() } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.black)
                .contentTransition(.symbolEffect(.replace.offUp))
                .offset(x: player.isPlaying ? 0 : 1.5)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.white).brightness(isHovering ? -0.06 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }
}

private struct NothingPlaying: View {
    @Environment(\.ambience) private var ambience

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Palette.secondaryFill)
                Image(systemName: "music.note").font(.system(size: 24, weight: .medium))
                    .foregroundStyle(ambience.tint.opacity(0.5))
            }
            .frame(width: 68, height: 68)
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing playing").font(.island(16, .semibold))
                Text("Music, podcasts and videos show up here.")
                    .font(.island(12.5)).foregroundStyle(ambience.tint.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// Elapsed / progress / remaining, draggable to seek.
private struct Scrubber: View {
    @Environment(NowPlayingModel.self) private var player
    @Environment(\.ambience) private var ambience
    let duration: Double
    @State private var scrubbing: Double?
    @State private var isHovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = scrubbing ?? player.elapsed(at: context.date)
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ambience.tint.opacity(0.16))
                        Capsule().fill(ambience.tint.opacity(scrubbing == nil ? 0.9 : 1))
                            .frame(width: geo.size.width * CGFloat(min(elapsed / duration, 1)))
                    }
                    .frame(height: isHovering || scrubbing != nil ? 6 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { scrubbing = max(0, min(1, $0.location.x / geo.size.width)) * duration }
                        .onEnded { _ in
                            if let scrubbing { player.seek(to: scrubbing) }
                            scrubbing = nil
                        })
                }
                .frame(height: 10)
                HStack {
                    Text(Clock.string(elapsed))
                    Spacer()
                    Text("-" + Clock.string(max(0, duration - elapsed)))
                }
                .font(.islandNumber(10, .medium))
                .foregroundStyle(ambience.tint.opacity(0.5))
            }
        }
        .onHover { isHovering = $0 }
        .animation(Motion.snappy, value: isHovering)
        .animation(Motion.snappy, value: scrubbing == nil)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Clock.string(player.elapsed()))
    }
}
