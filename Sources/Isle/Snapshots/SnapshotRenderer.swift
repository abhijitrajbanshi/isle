import AppKit
import IsleKit
import SwiftUI

/// Renders every island state offscreen to PNG (`Isle --snapshots <dir>`),
/// composited under a hardware-notch mask over a wallpaper and menu bar —
/// i.e. what the user actually sees. Used for design review without a
/// screen-recording permission.
@MainActor
enum SnapshotRenderer {
    private struct Scene {
        let name: String
        let setup: (IsleContainer) -> Void
    }

    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "isle.snapshots")!
        defaults.removePersistentDomain(forName: "isle.snapshots")

        var sheet: [(String, CGImage)] = []
        for scene in scenes {
            let preferences = Preferences(defaults: defaults)
            preferences.expandOnHover = false
            // ImageRenderer can't sample the desktop, so glass would render empty
            preferences.style = .black
            let c = IsleContainer(preferences: preferences, metrics: .preview, defaults: defaults)
            c.power.preview(level: 82, charging: false)
            c.calendar.preview(sampleEvents)
            scene.setup(c)
            if let image = render(c) {
                write(image, to: directory.appendingPathComponent("\(scene.name).png"))
                sheet.append((scene.name, image))
            }
        }
        writeContactSheet(sheet, to: directory.appendingPathComponent("00-contact-sheet.png"))
    }

    private static let scenes: [Scene] = [
        Scene(name: "01-idle") { _ in },
        Scene(name: "02-idle-hover") { $0.engine.pointerMoved(inside: true) },
        Scene(name: "03-compact-music") { c in
            playing(c)
            c.engine.activities = { [.nowPlaying] }
        },
        Scene(name: "04-compact-music-paused") { c in
            c.nowPlaying.preview(title: "Midnight City", artist: "M83", playing: false, artwork: artwork, accent: accent)
            c.engine.activities = { [.nowPlaying] }
        },
        Scene(name: "05-split-timer-music") { c in
            playing(c)
            c.timer.preview(remaining: 4 * 60 + 32, of: 600)
            c.engine.activities = { [.timer, .nowPlaying] }
        },
        Scene(name: "06-compact-calendar") { c in
            c.calendar.preview([.init(id: "a", title: "Design review", start: .now.addingTimeInterval(240),
                                      end: .now.addingTimeInterval(3600), color: IslandColor(red: 0.35, green: 0.5, blue: 1))])
            c.engine.activities = { [.calendar] }
        },
        Scene(name: "07-compact-privacy") { $0.engine.activities = { [.privacy] } },
        Scene(name: "08-hud-capslock") { $0.engine.present(.capsLock(isOn: true)) },
        Scene(name: "09-wide-charging") { $0.engine.present(.power(level: 82, isCharging: true)) },
        Scene(name: "10-wide-lowpower") { $0.engine.present(.lowPowerMode(isOn: true, level: 34)) },
        Scene(name: "11-banner-airpods") {
            $0.engine.present(.device(DeviceInfo(name: "AirPods Pro", symbol: "airpodspro", battery: 86, isConnected: true)))
        },
        Scene(name: "12-banner-lowbattery") { $0.engine.present(.lowBattery(level: 10)) },
        Scene(name: "13-banner-timer") { $0.engine.present(.timerDone) },
        Scene(name: "14-banner-event") {
            $0.engine.present(.eventSoon(EventInfo(title: "Design review", start: .now.addingTimeInterval(300),
                                                   color: IslandColor(red: 0.35, green: 0.5, blue: 1))))
        },
        Scene(name: "15-expanded-home") { c in
            playing(c)
            c.engine.expand(tab: .home)
        },
        Scene(name: "16-expanded-home-empty") { $0.engine.expand(tab: .home) },
        Scene(name: "17-expanded-home-timer") { c in
            playing(c)
            c.timer.preview(remaining: 272, of: 600)
            c.engine.expand(tab: .home)
        },
        Scene(name: "18-expanded-timer") { $0.engine.expand(tab: .timer) },
        Scene(name: "19-expanded-timer-running") { c in
            c.timer.preview(remaining: 272, of: 600)
            c.engine.expand(tab: .timer)
        },
        Scene(name: "20-expanded-shelf") { $0.engine.expand(tab: .shelf) },
    ]

    private static func playing(_ c: IsleContainer) {
        c.nowPlaying.preview(title: "Midnight City — Extended Version", artist: "M83", playing: true,
                             artwork: artwork, accent: accent)
    }

    private static let accent = Color(red: 1.0, green: 0.45, blue: 0.62)

    private static let sampleEvents: [CalendarModel.Event] = [
        .init(id: "1", title: "Design review", start: .now.addingTimeInterval(3600 * 2),
              end: .now.addingTimeInterval(3600 * 3), color: IslandColor(red: 0.35, green: 0.5, blue: 1)),
        .init(id: "2", title: "Dinner with Sam", start: .now.addingTimeInterval(3600 * 5),
              end: .now.addingTimeInterval(3600 * 6), color: IslandColor(red: 1, green: 0.6, blue: 0.1)),
    ]

    /// Synthetic album art: a warm gradient with a sun.
    private static let artwork: NSImage = {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [NSColor(calibratedRed: 0.98, green: 0.36, blue: 0.55, alpha: 1),
                                NSColor(calibratedRed: 0.36, green: 0.16, blue: 0.62, alpha: 1)])!
                .draw(in: rect, angle: -70)
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.5, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: 95, y: 110, width: 110, height: 110)).fill()
            return true
        }
    }()

    private static func render(_ c: IsleContainer) -> CGImage? {
        let notch = c.engine.metrics.size
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.1, green: 0.32, blue: 0.75), Color(red: 0.85, green: 0.25, blue: 0.3),
                                    Color(red: 0.95, green: 0.75, blue: 0.2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.white.opacity(0.18)).frame(height: notch.height)
                .frame(maxHeight: .infinity, alignment: .top)
            IslandView().isleEnvironment(c).environment(\.isSnapshot, true)
            // the hardware notch, which always sits on top of the screen
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                .fill(.black)
                .frame(width: notch.width, height: notch.height)
        }
        .frame(width: 900, height: 240)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage
    }

    private static func write(_ image: CGImage, to url: URL) {
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// All scenes on one labelled sheet, two columns, cropped to the island.
    private static func writeContactSheet(_ images: [(String, CGImage)], to url: URL) {
        let cell = CGSize(width: 900, height: 220), columns = 2
        let rows = (images.count + columns - 1) / columns
        let sheet = NSImage(size: CGSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows)),
                            flipped: true) { _ in
            for (i, (name, image)) in images.enumerated() {
                let origin = CGPoint(x: CGFloat(i % columns) * cell.width, y: CGFloat(i / columns) * cell.height)
                let crop = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Int(cell.height * 2)))!
                NSImage(cgImage: crop, size: cell).draw(in: CGRect(origin: origin, size: cell))
                NSColor.black.withAlphaComponent(0.55).setFill()
                CGRect(x: origin.x, y: origin.y + cell.height - 22, width: cell.width, height: 22).fill()
                (name as NSString).draw(at: CGPoint(x: origin.x + 8, y: origin.y + cell.height - 19),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                         .foregroundColor: NSColor.white])
            }
            return true
        }
        guard let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
