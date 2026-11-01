import IsleKit
import SwiftUI

/// System alerts. HUD and wide alerts live in the notch row; banners drop
/// below it with a title, subtitle and accessory.
struct AlertContent: View {
    @Environment(IslandEngine.self) private var engine
    let alert: IslandAlert

    var body: some View {
        let height = engine.metrics.size.height
        switch alert.style {
        case .hud, .wide:
            HStack(spacing: 0) {
                AlertLeading(alert: alert)
                Spacer(minLength: engine.metrics.size.width + 12)
                AlertTrailing(alert: alert)
            }
            .padding(.horizontal, 14)
            .frame(height: height)
        case .banner:
            VStack(spacing: 0) {
                Color.clear.frame(height: height)
                AlertBanner(alert: alert)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 4)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

private struct AlertLeading: View {
    let alert: IslandAlert

    var body: some View {
        switch alert {
        case .capsLock(let on):
            Image(systemName: on ? "capslock.fill" : "capslock")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Palette.green : Palette.secondaryLabel)
                .contentTransition(.symbolEffect(.replace))
        case .power(_, let charging):
            Label {
                Text(charging ? "Charging" : "On Battery").font(.island(13, .semibold))
            } icon: {
                Image(systemName: charging ? "bolt.fill" : "powerplug.portrait.fill")
                    .font(.system(size: 12, weight: .bold))
                    .symbolEffect(.bounce, value: charging)
            }
            .labelStyle(TightLabel())
            .foregroundStyle(charging ? Palette.green : Palette.secondaryLabel)
        case .lowPowerMode(let on, _):
            Label {
                Text(on ? "Low Power" : "Low Power Off").font(.island(13, .semibold))
            } icon: {
                Image(systemName: "leaf.fill").font(.system(size: 11, weight: .bold))
            }
            .labelStyle(TightLabel())
            .foregroundStyle(on ? Palette.yellow : Palette.secondaryLabel)
        default:
            EmptyView()
        }
    }
}

private struct AlertTrailing: View {
    let alert: IslandAlert

    var body: some View {
        switch alert {
        case .capsLock(let on):
            Text(on ? "On" : "Off")
                .font(.island(13, .semibold))
                .foregroundStyle(on ? Palette.green : Palette.secondaryLabel)
        case .power(let level, let charging):
            HStack(spacing: 6) {
                Text("\(level)%").font(.islandNumber(13))
                    .foregroundStyle(charging ? Palette.green : .white)
                BatteryGlyph(level: level, color: charging ? Palette.green : Palette.battery(level),
                             isCharging: charging)
            }
        case .lowPowerMode(let on, let level):
            HStack(spacing: 6) {
                Text("\(level)%").font(.islandNumber(13))
                BatteryGlyph(level: level, color: on ? Palette.yellow : Palette.battery(level))
            }
        default:
            EmptyView()
        }
    }
}

private struct AlertBanner: View {
    @Environment(IslandEngine.self) private var engine
    @Environment(TimerModel.self) private var timer
    @Environment(CalendarModel.self) private var calendar
    let alert: IslandAlert

    var body: some View {
        switch alert {
        case .device(let device):
            HStack(spacing: 14) {
                Image(systemName: device.symbol)
                    .font(.system(size: 30, weight: .regular))
                    .symbolEffect(.bounce, value: device.isConnected)
                    .frame(width: 42)
                Titles(title: device.name, subtitle: device.isConnected ? "Connected" : "Disconnected")
                Spacer(minLength: 8)
                if let battery = device.battery {
                    RingView(progress: Double(battery) / 100, color: Palette.battery(battery), lineWidth: 3.5) {
                        Text("\(battery)").font(.islandNumber(11))
                    }
                    .frame(width: 36, height: 36)
                }
            }
        case .lowBattery(let level):
            HStack(spacing: 14) {
                BatteryGlyph(level: level, color: Palette.red, width: 36)
                    .frame(width: 42)
                Titles(title: "Low Battery", subtitle: "Connect to power soon")
                Spacer(minLength: 8)
                Text("\(level)%").font(.islandNumber(22, .semibold)).foregroundStyle(Palette.red)
            }
        case .timerDone:
            HStack(spacing: 12) {
                TimerDoneGlyph()
                Titles(title: "Timer", subtitle: "Done", tint: Palette.orange)
                Spacer(minLength: 8)
                IslandButton(symbol: "arrow.counterclockwise", label: "Repeat", size: 15, tint: Palette.orange,
                             fill: Palette.orange.opacity(0.22), diameter: 40) {
                    timer.start(timer.lastDuration)
                    engine.dismissAlert()
                }
                IslandButton(symbol: "xmark", label: "Stop", size: 15, weight: .bold, tint: .black,
                             fill: Palette.orange, diameter: 40) {
                    engine.dismissAlert()
                }
            }
        case .eventSoon(let event):
            HStack(spacing: 13) {
                Capsule().fill(event.color.color).frame(width: 4, height: 36)
                Titles(title: event.title,
                       subtitle: "\(AlertCopy.startsIn(event.start)) · \(event.start.formatted(date: .omitted, time: .shortened))")
                Spacer(minLength: 8)
                if let meeting = event.meeting {
                    ActionPill(symbol: "video.fill", title: "Join", color: event.color.color, height: 32) {
                        calendar.join(meeting)
                        engine.dismissAlert()
                    }
                } else {
                    Image(systemName: "calendar").font(.system(size: 22, weight: .medium))
                        .foregroundStyle(event.color.color)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { calendar.openCalendar() }
        case .notice(let info):
            HStack(spacing: 13) {
                Image(systemName: info.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.amber)
                    .frame(width: 32)
                Titles(title: info.title, subtitle: info.detail)
                Spacer(minLength: 8)
            }
        case .pullRequest(let info):
            HStack(spacing: 13) {
                Image(systemName: PullRequestCopy.symbol(info.event))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(info.event == .approved ? Palette.green
                                     : info.event == .changesRequested ? Palette.red : Palette.amber)
                    .frame(width: 32)
                Titles(title: info.title,
                       subtitle: "\(info.repo) #\(info.number) · " + (info.event == .reviewRequested ? "Review requested"
                           : info.event == .approved ? "Approved" : "Changes requested"))
                Spacer(minLength: 8)
            }
        case .limit(let info):
            HStack(spacing: 13) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Palette.amber)
                    .frame(width: 32)
                Titles(title: "Claude usage at \(info.percent)%",
                       subtitle: "\(info.window.prefix(1).uppercased() + info.window.dropFirst()) limit · resets " + (info.window == "weekly"
                           ? info.resetsAt.formatted(.dateTime.weekday(.wide).hour().minute())
                           : info.resetsAt.formatted(date: .omitted, time: .shortened)))
                Spacer(minLength: 8)
            }
        case .finished(let info):
            HStack(spacing: 13) {
                Image(systemName: info.succeeded ? "checkmark" : "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(info.succeeded ? Palette.green : Palette.red))
                    .symbolEffect(.bounce, value: info)
                Titles(title: info.title, subtitle: info.detail)
                Spacer(minLength: 8)
            }
        default:
            EmptyView()
        }
    }
}

enum AlertCopy {
    /// "In 5 minutes", "In 1 minute", "Starting now": events can be created
    /// closer to their start than the usual five-minute heads-up.
    static func startsIn(_ start: Date, now: Date = .now) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded())
        switch minutes {
        case ..<1: return "Starting now"
        case 1: return "In 1 minute"
        default: return "In \(minutes) minutes"
        }
    }
}

/// Bounces a few times when it appears, like the iOS timer alert.
private struct TimerDoneGlyph: View {
    @State private var appeared = false

    var body: some View {
        Image(systemName: "timer")
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(Palette.orange)
            .symbolEffect(.bounce, options: .repeat(4), value: appeared)
            .onAppear { appeared = true }
    }
}

private struct Titles: View {
    let title: String
    let subtitle: String
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.island(15, .semibold)).foregroundStyle(tint).lineLimit(1)
            Text(subtitle).font(.island(12.5)).foregroundStyle(Palette.secondaryLabel).lineLimit(1)
        }
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon; configuration.title }
    }
}
