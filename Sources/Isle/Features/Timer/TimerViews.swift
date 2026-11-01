import SwiftUI

/// Countdown text that ticks with a numeric content transition.
struct TimerCountdown: View {
    @Environment(TimerModel.self) private var timer
    var size: CGFloat
    var weight: Font.Weight = .semibold

    var body: some View {
        TimelineView(CountdownSchedule(end: timer.end)) { context in
            Text(Clock.string(TimerModel.displayed(timer.remaining(at: context.date))))
                .font(.islandNumber(size, weight))
                .foregroundStyle(Palette.orange)
                .contentTransition(.numericText(countsDown: true))
                .animation(Motion.snappy, value: context.date)
        }
        .opacity(timer.isRunning ? 1 : 0.55)
        .accessibilityLabel("Timer")
    }
}

struct TimerCompactLeading: View {
    @Environment(TimerModel.self) private var timer

    var body: some View {
        Image(systemName: timer.isRunning ? "timer" : "pause.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Palette.orange)
            .contentTransition(.symbolEffect(.replace))
    }
}

struct TimerBubble: View {
    @Environment(TimerModel.self) private var timer

    var body: some View {
        TimelineView(CountdownSchedule(end: timer.end)) { context in
            RingView(progress: timer.fraction(at: context.date), color: Palette.orange, lineWidth: 2.4) {
                Image(systemName: timer.isRunning ? "timer" : "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.orange)
            }
        }
        .padding(6)
    }
}

struct TimerTab: View {
    @Environment(TimerModel.self) private var timer

    var body: some View {
        if timer.isActive {
            HStack(spacing: 20) {
                TimelineView(CountdownSchedule(end: timer.end)) { context in
                    RingView(progress: timer.fraction(at: context.date), color: Palette.orange, lineWidth: 6) {
                        Image(systemName: timer.isRunning ? "timer" : "pause.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Palette.orange)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .animation(.linear(duration: 1), value: context.date)
                }
                .frame(width: 82, height: 82)

                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Clock.string(timer.total)) timer")
                        .font(.island(12, .medium)).foregroundStyle(Palette.secondaryLabel)
                    TimerCountdown(size: 46, weight: .light)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    IslandButton(symbol: "plus", label: "Add a minute", size: 15, fill: Palette.fill, diameter: 46) {
                        timer.addMinute()
                    }
                    IslandButton(symbol: "xmark", label: "Cancel", size: 15, fill: Palette.fill, diameter: 46) {
                        timer.cancel()
                    }
                    IslandButton(symbol: timer.isRunning ? "pause.fill" : "play.fill",
                                 label: timer.isRunning ? "Pause" : "Resume", size: 17, tint: Palette.orange,
                                 fill: Palette.orange.opacity(0.22), diameter: 46) { timer.toggle() }
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Timer").font(.island(13, .semibold)).foregroundStyle(Palette.secondaryLabel)
                HStack(spacing: 0) {
                    ForEach(TimerModel.presets, id: \.self) { seconds in
                        PresetButton(seconds: seconds) { timer.start(seconds) }
                        if seconds != TimerModel.presets.last { Spacer(minLength: 6) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct PresetButton: View {
    let seconds: TimeInterval
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let isHour = seconds >= 3600
        Button(action: action) {
            VStack(spacing: -1) {
                Text(isHour ? "1" : "\(Int(seconds / 60))").font(.islandNumber(18, .semibold))
                Text(isHour ? "hr" : "min").font(.island(9.5, .medium)).opacity(0.7)
            }
            .foregroundStyle(Palette.orange)
            .frame(width: 54, height: 54)
            .background(Circle().fill(Palette.orange.opacity(isHovering ? 0.28 : 0.17)))
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
        .animation(Motion.snappy, value: isHovering)
        .accessibilityLabel(isHour ? "1 hour" : "\(Int(seconds / 60)) minutes")
    }
}

/// Ticks on the countdown's own whole seconds, so the display changes the
/// moment the remaining time does and reads 0:00 when the timer fires.
/// A paused (or idle) timer doesn't tick at all.
struct CountdownSchedule: TimelineSchedule {
    let end: Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        guard let end, end > startDate else { return AnyIterator([startDate].makeIterator()) }
        // the latest whole-second boundary at or before startDate
        var next = end.addingTimeInterval(-end.timeIntervalSince(startDate).rounded(.up))
        return AnyIterator {
            guard next <= end else { return nil }
            defer { next = next.addingTimeInterval(1) }
            return next
        }
    }
}
