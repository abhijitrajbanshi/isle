import IsleKit
import SwiftUI

/// The island: one shape (black or glass) that morphs between presentations, content
/// cross-fading inside it, plus the detached bubble for a second activity.
///
/// At rest it draws nothing: the hardware notch *is* the idle island, so
/// there is never a second, slightly-off notch (e.g. during Space swipes).
struct IslandView: View {
    @Environment(IslandEngine.self) private var engine
    @Environment(ShelfModel.self) private var shelf
    @Environment(Preferences.self) private var preferences
    @Environment(PowerMonitor.self) private var power
    @Environment(NowPlayingModel.self) private var player
    @Environment(TimerModel.self) private var timer
    @Environment(CalendarModel.self) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var isResting = false

    var body: some View {
        let presentation = engine.presentation
        let shape = engine.shape
        let isHidden = presentation.isIdle && !engine.isHovering && (isResting || !engine.metrics.hasNotch)

        ZStack(alignment: .top) {
            body(for: presentation, shape: shape)
                .opacity(isHidden ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation(for: presentation), value: presentation)
        .animation(reduceMotion ? Motion.reduced : Motion.morph, value: engine.isHovering)
        .animation(Motion.morph, value: engine.metrics)
        .animation(reduceMotion ? Motion.reduced : Motion.morph, value: engine.expandedHeight)
        .task(id: presentation.isIdle) {
            // Once the shape has shrunk back into the notch, stop drawing it.
            isResting = false
            guard presentation.isIdle else { return }
            try? await Task.sleep(for: .milliseconds(450))
            isResting = !Task.isCancelled
        }
        .environment(\.colorScheme, .dark)
        .environment(\.ambience, ambience(for: presentation))
        .environment(\.prefersStillness, reduceMotion || power.isLowPowerMode)
    }

    private func body(for presentation: Presentation, shape: IslandShape) -> some View {
        let outline = NotchShape(shoulder: shape.shoulder, radius: shape.radius)
        // bare beside the notch, and while shrinking back into it (hovering
        // the empty notch still shows the glass)
        let bare = presentation.isCompact || (presentation.isIdle && !engine.isHovering)
        return IslandSurface(shape: outline, style: preferences.style, bare: bare)
            .frame(width: shape.outerWidth, height: shape.height)
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    content(for: presentation)
                        .id(presentation.contentKey)
                        .transition(.islandContent)
                }
                .frame(width: shape.width, height: shape.height, alignment: .top)
                // on see-through glass, a soft shadow keeps white content legible
                .shadow(color: .black.opacity(preferences.style == .glass ? 0.45 : 0), radius: 2.5, y: 0.5)
            }
            .clipShape(outline)
            .shadow(color: .black.opacity(shadowOpacity(for: presentation)), radius: 24, y: 14)
            .overlay(alignment: .topTrailing) { bubble(for: presentation) }
            .contentShape(outline)
            .onTapGesture { engine.activate() }
            .modifier(SystemInteractions(isEnabled: !isSnapshot, engine: engine, onDrop: acceptDrop))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Isle")
    }

    @ViewBuilder
    private func content(for presentation: Presentation) -> some View {
        switch presentation {
        case .idle: Color.clear
        case .compact(let primary, _): CompactContent(activity: primary)
        case .alert(let alert): AlertContent(alert: alert)
        case .expanded: ExpandedContent()
        }
    }

    @ViewBuilder
    private func bubble(for presentation: Presentation) -> some View {
        if case .compact(_, let secondary?) = presentation {
            let d = engine.layout.bubbleDiameter
            BubbleContent(activity: secondary, diameter: d)
                .frame(width: d, height: d)
                .background(IslandSurface(shape: Circle(), style: preferences.style, bare: true))
                .contentShape(Circle())
                .onTapGesture { engine.expand() }
                .offset(x: d + IslandLayout.bubbleGap)
                // splits off the island's trailing edge, like iOS
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.2, anchor: .leading).combined(with: .offset(x: -d)),
                    removal: .scale(scale: 0.2, anchor: .leading).combined(with: .offset(x: -d)).combined(with: .opacity)))
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { [shelf] url, _ in
                guard let url else { return }
                Task { @MainActor in shelf.add([url]) }
            }
        }
        engine.expand(tab: .shelf)
        engine.fileDragEnded()
        return true
    }

    private func animation(for presentation: Presentation) -> Animation {
        if reduceMotion { return Motion.reduced }
        switch presentation {
        case .expanded: return Motion.expand
        case .idle: return Motion.collapse
        default: return Motion.morph
        }
    }

    /// The content colour: the artwork's while music shows, a meeting's
    /// calendar, the timer's orange, amber while an agent waits on you.
    private func ambience(for presentation: Presentation) -> Ambience {
        let music = player.track != nil && player.artwork != nil ? Ambience(player.accent) : nil
        switch presentation {
        case .compact(let primary, _):
            switch primary {
            case .nowPlaying: return music ?? .signature
            case .timer: return Ambience(accent: Palette.orange)
            case .calendar: return calendar.current().map { Ambience($0.color) } ?? .signature
            case .agent, .usage: return Ambience(accent: Palette.amber)
            case .task, .privacy, .ci: return .signature
            }
        case .alert(.eventSoon(let event)):
            return Ambience(event.color)
        case .expanded:
            return music ?? .signature
        default:
            return .signature
        }
    }

    private func shadowOpacity(for presentation: Presentation) -> Double {
        switch presentation {
        case .expanded: 0.6
        case .alert(let alert) where alert.style == .banner: 0.45
        default: 0
        }
    }
}

private struct IslandContextMenu: View {
    @Environment(\.openIsleSettings) private var openSettings
    @Environment(TimerModel.self) private var timer
    @Environment(KeepAwakeModel.self) private var awake

    var body: some View {
        Menu("Timer") {
            ForEach(TimerModel.presets, id: \.self) { seconds in
                Button(seconds >= 3600 ? "1 hour" : "\(Int(seconds / 60)) minutes") { timer.start(seconds) }
            }
        }
        Menu("Keep Awake") {
            ForEach(KeepAwakeModel.Duration.allCases) { duration in
                Button(duration.title) { awake.start(duration) }
            }
            if awake.isOn {
                Divider()
                Button("Allow Sleep") { awake.stop() }
            }
        }
        Divider()
        Button("Settings…") { openSettings() }
        Divider()
        Button("Quit Isle") { NSApp.terminate(nil) }
    }
}

/// Context menu and drop target. AppKit-backed, so left out of offscreen
/// snapshots (ImageRenderer can't draw them).
private struct SystemInteractions: ViewModifier {
    let isEnabled: Bool
    let engine: IslandEngine
    let onDrop: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contextMenu { IslandContextMenu() }
                .onDrop(of: [.fileURL], isTargeted: Bindable(engine).isDropTargeted, perform: onDrop)
        } else {
            content
        }
    }
}

private extension Presentation {
    var isCompact: Bool {
        if case .compact = self { true } else { false }
    }
}

extension EnvironmentValues {
    @Entry var isSnapshot = false
}
