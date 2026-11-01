import AppKit
import IsleKit
import SwiftUI

/// A scripted tour of the island with sample data, live in a window
/// (`Isle --demo [glass|black]`), for recording the showcase video. Prints
/// the window's screen rect (top-left origin, points) for `screencapture -R`,
/// waits a moment, plays the script once and quits.
@MainActor
enum DemoReel {
    static func run(style: IslandStyle) {
        let defaults = UserDefaults(suiteName: "isle.demo")!
        defaults.removePersistentDomain(forName: "isle.demo")
        let preferences = Preferences(defaults: defaults)
        preferences.expandOnHover = false
        preferences.haptics = false
        preferences.style = style
        let c = IsleContainer(preferences: preferences, metrics: .preview, defaults: defaults)
        c.power.preview(level: 82, charging: false)
        let event = CalendarModel.Event(id: "1", title: "Design review", start: Date.now.addingTimeInterval(7200),
                                        end: Date.now.addingTimeInterval(10_800),
                                        color: IslandColor(red: 0.35, green: 0.5, blue: 1))
        c.calendar.preview([event])

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let size = CGSize(width: 820, height: 230)
        guard let screen = NSScreen.main else { exit(1) }
        // somewhere the pointer isn't, since the recording includes it
        let visible = screen.visibleFrame
        let candidates = [visible.midY, visible.maxY - size.height - 40, visible.minY + 40].map {
            CGRect(x: visible.midX - size.width / 2, y: $0 - ($0 == visible.midY ? size.height / 2 : 0),
                   width: size.width, height: size.height).integral
        }
        let mouse = NSEvent.mouseLocation
        let frame = candidates.first { !$0.insetBy(dx: -30, dy: -30).contains(mouse) } ?? candidates[0]
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: Stage(container: c))
        window.orderFrontRegardless()

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        print("RECT \(Int(frame.minX)),\(Int(primaryHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))")
        fflush(stdout)

        Task {
            try? await Task.sleep(for: .seconds(2))
            await play(c)
            print("DONE")
            fflush(stdout)
            exit(0)
        }
        app.run()
    }

    private static func play(_ c: IsleContainer) async {
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        let engine = c.engine

        await wait(1.2)
        engine.pointerMoved(inside: true); await wait(1.1)
        engine.pointerMoved(inside: false); await wait(0.9)

        c.nowPlaying.preview(title: "Midnight City", artist: "M83", playing: true,
                             artwork: SnapshotRenderer.artwork, accent: SnapshotRenderer.accent)
        await wait(3)
        engine.expand(tab: .home); await wait(3.4)
        engine.collapse(); await wait(1.4)

        c.timer.start(5 * 60); await wait(2.6)
        engine.present(.device(DeviceInfo(name: "AirPods Pro", symbol: "airpodspro", battery: 86, isConnected: true)))
        await wait(4.6)
        engine.present(.power(level: 82, isCharging: true)); await wait(3)
        engine.present(.capsLock(isOn: true)); await wait(2)

        engine.expand(tab: .timer); await wait(2.8)
        engine.collapse(); await wait(1.2)
        c.timer.cancel(); await wait(1.2)
        c.nowPlaying.clear(); await wait(1.6)
    }

    /// A wallpaper and menu bar under the island, with the hardware notch on top.
    private struct Stage: View {
        let container: IsleContainer

        var body: some View {
            let notch = container.engine.metrics.size
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.08, green: 0.2, blue: 0.55), Color(red: 0.55, green: 0.2, blue: 0.6),
                                        Color(red: 0.95, green: 0.45, blue: 0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(.white.opacity(0.14)).frame(height: notch.height)
                    .frame(maxHeight: .infinity, alignment: .top)
                IslandView().isleEnvironment(container)
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                    .fill(.black)
                    .frame(width: notch.width, height: notch.height)
            }
        }
    }
}
