import AppKit
import CoreAudio
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
            c.keepAwake.stop()
            c.calendar.preview(sampleEvents)
            c.audio.preview(outputs: sampleOutputs, current: 0, micMuted: false)
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
        Scene(name: "04-compact-agent-working") { c in
            c.hub.preview([agent(state: .working)])
            c.engine.activities = { [.agent] }
        },
        Scene(name: "05-compact-agent-request") { c in
            c.hub.preview([agent(state: .needsYou)])
            c.engine.activities = { [.agent, .nowPlaying] }
            playing(c)
        },
        Scene(name: "06-compact-task") { c in
            c.hub.preview([build])
            c.engine.activities = { [.task] }
        },
        Scene(name: "07-compact-meeting-join") { c in
            c.calendar.preview([standup(startingIn: 60)])
            c.engine.activities = { [.calendar] }
        },
        Scene(name: "08-compact-split-timer-music") { c in
            playing(c)
            c.timer.preview(remaining: 4 * 60 + 32, of: 600)
            c.engine.activities = { [.timer, .nowPlaying] }
        },
        Scene(name: "09-compact-privacy") { $0.engine.activities = { [.privacy] } },
        Scene(name: "10-hud-capslock") { $0.engine.present(.capsLock(isOn: true)) },
        Scene(name: "11-wide-charging") { $0.engine.present(.power(level: 82, isCharging: true)) },
        Scene(name: "12-banner-finished") {
            $0.engine.present(.finished(FinishedInfo(title: "isle is ready", detail: "Claude worked for 12 min",
                                                     symbol: "checkmark", succeeded: true)))
        },
        Scene(name: "13-banner-meeting") {
            $0.engine.present(.eventSoon(EventInfo(title: "Team stand-up", start: .now.addingTimeInterval(300),
                                                   color: IslandColor(red: 0.3, green: 0.75, blue: 0.55),
                                                   meeting: sampleMeeting)))
        },
        Scene(name: "14-banner-airpods") {
            $0.engine.present(.device(DeviceInfo(name: "AirPods Pro", symbol: "airpodspro", battery: 86, isConnected: true)))
        },
        Scene(name: "15-open-request") { c in
            playing(c)
            c.hub.preview([agent(state: .needsYou), build])
            c.engine.expand(tab: .home)
        },
        Scene(name: "16-open-music") { c in
            playing(c)
            c.audio.preview(outputs: [("soundcore Liberty 4 NC Wireless Earbuds", kAudioDeviceTransportTypeBluetooth)],
                            current: 0, micMuted: false)
            c.hub.preview([agent(state: .working)])
            c.engine.expand(tab: .home)
        },
        Scene(name: "17-open-call") { c in
            c.calendar.preview([standup(startingIn: 120)])
            playing(c)
            c.engine.expand(tab: .home)
        },
        Scene(name: "18-open-agent") { c in
            c.hub.preview([agent(state: .working), build])
            c.engine.expand(tab: .home)
        },
        Scene(name: "19-open-quiet") { $0.engine.expand(tab: .home) },
        Scene(name: "20-open-timer") { c in
            c.timer.preview(remaining: 272, of: 600)
            c.engine.expand(tab: .timer)
        },
        Scene(name: "21-open-shelf") { $0.engine.expand(tab: .shelf) },
        Scene(name: "24-open-question") { c in
            c.hub.preview([agent(state: .needsYou, request: ActivityHub.request(tool: "AskUserQuestion", input: [
                "questions": [["question": "Which payment provider should I use?", "header": "Payments", "multiSelect": false,
                               "options": [["label": "Stripe (already in the project)"], ["label": "Adyen"],
                                           ["label": "Apple Pay only"]]]]], suggestions: nil))])
            c.engine.expand(tab: .home)
        },
        Scene(name: "25-open-plan") { c in
            c.hub.preview([agent(state: .needsYou, request: ActivityHub.request(tool: "ExitPlanMode", input: [
                "plan": "# Apple Pay in checkout\n1. Add the PassKit entitlement\n2. Build the payment sheet\n3. Handle the webhook\n4. Tests for declined cards"],
                suggestions: nil))])
            c.engine.expand(tab: .home)
        },
        Scene(name: "26-open-always-allow") { c in
            c.hub.preview([agent(state: .needsYou, request: ActivityHub.request(
                tool: "Bash", input: ["command": "swift test --parallel"],
                suggestions: [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "swift test:*"]],
                               "behavior": "allow", "destination": "localSettings"]]))])
            c.engine.expand(tab: .home)
        },
        Scene(name: "27-open-review") { c in
            var done = agent(state: .review)
            done.lastTest = .init(command: "swift test", passed: true)
            done.review = .init(summary: "Added Apple Pay to checkout", minutes: 23,
                                files: [.init(path: "Sources/Checkout/ApplePay.swift", added: 148, removed: 0),
                                        .init(path: "Sources/Checkout/CheckoutView.swift", added: 41, removed: 22),
                                        .init(path: "Tests/CheckoutTests.swift", added: 25, removed: 15)],
                                added: 214, removed: 37, pullRequest: URL(string: "https://github.com/o/r/pull/482"),
                                loaded: true)
            done.host = 1
            c.hub.preview([done])
            c.engine.expand(tab: .home)
        },
        Scene(name: "27b-open-crowded") { c in
            var done = agent(state: .review)
            done.review = .init(summary: ActivityHub.plain("CI and pull requests work on your real GitHub account. The work is committed and pushed as **45da31f**."),
                                minutes: 0, loaded: true)
            done.host = 1
            c.hub.preview([done, agent(state: .working)], usage: sampleUsage(40))
            playing(c)
            c.github.preview(runs: [], pullRequests: (1...4).map { n in
                .init(id: "\(n)", title: "T13\(n)113: Added dropship for unavailable products with vendor", repo: "acme/shop",
                      number: 430 + n, url: URL(string: "https://github.com/acme/shop/pull/\(430 + n)")!,
                      kind: .reviewRequested, updated: .now)
            })
            c.engine.expand(tab: .home)
        },
        Scene(name: "31-open-deploy") { c in
            var run = GitHubModel.Run(repo: "acme/shop", branch: "feature/apple-pay", sha: "45da31f9", started: .now)
            run.state = .passed
            run.checks = [.init(name: "build", done: true, failed: false, url: nil)]
            run.deploys = [.init(environment: "Preview", isProduction: false, state: .ready,
                                 url: URL(string: "https://shop-git-apple-pay.vercel.app"), logs: nil),
                           .init(environment: "Production", isProduction: true, state: .building, url: nil, logs: nil)]
            c.github.preview(runs: [run], pullRequests: [])
            c.engine.expand(tab: .home)
        },
        Scene(name: "32-open-stuck") { c in
            var stuck = agent(state: .working)
            stuck.detail = "Running npm test"
            stuck.trouble = "“npm test” failed 3 times in a row"
            stuck.host = 1
            c.hub.preview([stuck])
            c.engine.expand(tab: .home)
        },
        Scene(name: "33-banner-two-agents") {
            $0.engine.present(.notice(NoticeInfo(title: "Two agents edited Checkout.swift",
                                                 detail: "api and web · expect a conflict when you merge",
                                                 symbol: "arrow.triangle.merge")))
        },
        Scene(name: "34-open-servers") { c in
            c.servers.preview([.init(port: 3000, pid: 501, program: "node", folder: "/Users/you/code/shop"),
                               .init(port: 5173, pid: 502, program: "node", folder: "/Users/you/code/admin"),
                               .init(port: 8069, pid: 503, program: "python", folder: "/Users/you/code/odoo")])
            c.engine.expand(tab: .home)
        },
        Scene(name: "40-compact-agent-reply") { c in
            c.hub.preview([agent(state: .yourTurn)]); c.engine.activities = { [.agent] }
        },
        Scene(name: "41-compact-agent-ready") { c in
            c.hub.preview([agent(state: .review)]); c.engine.activities = { [.agent] }
        },
        Scene(name: "42-compact-agent-long-name") { c in
            var a = agent(state: .working)
            a.title = "cust-odoo-acculon"
            c.hub.preview([a]); c.engine.activities = { [.agent] }
        },
        Scene(name: "43-compact-ci") { c in
            var run = GitHubModel.Run(repo: "o/r", branch: "main", sha: "a", started: .now)
            run.state = .passed
            c.github.preview(runs: [run], pullRequests: []); c.engine.activities = { [.ci] }
        },
        Scene(name: "44-compact-timer") { c in
            c.timer.preview(remaining: 272, of: 600); c.engine.activities = { [.timer] }
        },
        Scene(name: "28-open-usage") { c in
            var a = agent(state: .working)
            a.meter = .init(contextPercent: 64, costUSD: 4.2)
            var b = agent(state: .working)
            b = ActivityHub.Activity(id: "api", kind: .agent, title: "api", detail: "Running migrations", state: .working,
                                     progress: nil, started: .now, request: nil, meter: .init(contextPercent: 88, costUSD: 1.9))
            _ = (a, b)
            c.hub.preview([], usage: sampleUsage(84))
            c.engine.expand(tab: .home)
            c.engine.tab = .home
        },
        Scene(name: "29-compact-usage") { c in
            c.hub.preview([], usage: sampleUsage(84))
            c.engine.activities = { [.usage] }
        },
        Scene(name: "30-banner-limit") {
            $0.engine.present(.limit(LimitInfo(percent: 82, window: "5-hour", resetsAt: .now.addingTimeInterval(5400))))
        },
        Scene(name: "22-open-shelf-dropping") { $0.engine.fileDragEnteredDropZone() },
        Scene(name: "23-open-summary") { c in
            c.shelf.previewSummary(ShelfModel.Summary(file: "Q3 planning.pdf", text: """
                • Revenue grew 18% on the back of the new Mac app.
                • Hiring pauses until January; two roles stay open.
                • The 2.0 launch moves to the second week of November.
                """))
            c.engine.expand(tab: .shelf)
        },
    ]

    static func sampleUsage(_ used: Double) -> ActivityHub.Usage {
        ActivityHub.Usage(fiveHour: .init(used: used, resetsAt: .now.addingTimeInterval(5400)),
                          weekly: .init(used: 41, resetsAt: .now.addingTimeInterval(3 * 86_400)),
                          updated: .now, capForecast: .now.addingTimeInterval(1800))
    }

    static func agent(state: ActivityHub.Activity.State, request: ActivityHub.PermissionRequest) -> ActivityHub.Activity {
        var a = agent(state: state)
        a.request = request
        return a
    }

    static func agent(state: ActivityHub.Activity.State) -> ActivityHub.Activity {
        ActivityHub.Activity(
            id: "claude", kind: .agent, title: "isle",
            detail: state == .needsYou ? "Running swift test" : "Editing IslandView.swift",
            state: state, progress: nil, started: .now.addingTimeInterval(-252),
            request: state == .needsYou
                ? .init(id: UUID(), question: "Run this command?",
                        subject: "swift test --filter MeetingLinkTests", tool: "Bash")
                : nil)
    }

    static let build = ActivityHub.Activity(id: "build", kind: .task, title: "Archive Isle", detail: "Compiling 214 of 340",
                                            state: .working, progress: 0.64, started: .now.addingTimeInterval(-95),
                                            request: nil)

    private static func playing(_ c: IsleContainer) {
        c.nowPlaying.preview(title: "Midnight City — Extended Version", artist: "M83", playing: true,
                             artwork: artwork, accent: accent)
    }

    static let sampleOutputs: [(String, UInt32)] = [
        ("AirPods Pro", kAudioDeviceTransportTypeBluetooth),
        ("MacBook Pro Speakers", kAudioDeviceTransportTypeBuiltIn),
        ("Studio Display", kAudioDeviceTransportTypeDisplayPort),
    ]

    static let sampleMeeting = MeetingLink(url: URL(string: "https://zoom.us/j/1234567890")!, service: .zoom)

    static func standup(startingIn seconds: TimeInterval) -> CalendarModel.Event {
        CalendarModel.Event(id: "standup", title: "Team stand-up", start: Date.now.addingTimeInterval(seconds),
                            end: Date.now.addingTimeInterval(seconds + 900),
                            color: IslandColor(red: 0.3, green: 0.75, blue: 0.55), meeting: sampleMeeting)
    }

    static let accent = Color(red: 1.0, green: 0.45, blue: 0.62)

    private static let sampleEvents: [CalendarModel.Event] = [
        .init(id: "1", title: "Design review", start: .now.addingTimeInterval(3600 * 2),
              end: .now.addingTimeInterval(3600 * 3), color: IslandColor(red: 0.35, green: 0.5, blue: 1)),
        .init(id: "2", title: "Dinner with Sam", start: .now.addingTimeInterval(3600 * 5),
              end: .now.addingTimeInterval(3600 * 6), color: IslandColor(red: 1, green: 0.6, blue: 0.1)),
    ]

    /// Synthetic album art: a warm gradient with a sun.
    static let artwork: NSImage = {
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
        .frame(width: 900, height: 500)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        // the first pass measures the open island's content; the second draws it at that height
        _ = renderer.cgImage
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
