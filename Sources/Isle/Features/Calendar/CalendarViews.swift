import SwiftUI

struct CalendarCompactLeading: View {
    @Environment(CalendarModel.self) private var calendar

    var body: some View {
        if let event = calendar.current() {
            Image(systemName: event.meeting == nil ? "calendar" : "video.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(event.color.color)
        }
    }
}

struct CalendarCompactTrailing: View {
    @Environment(CalendarModel.self) private var calendar

    var body: some View {
        if let event = calendar.current() {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                // a call about to start: join straight from the notch
                if let meeting = event.meeting, event.start.timeIntervalSince(context.date) < 2 * 60 {
                    ActionPill(symbol: "video.fill", title: "Join", color: event.color.color, height: 22, showsSymbol: false) {
                        calendar.join(meeting)
                    }
                } else {
                    Text(Self.relative(event.start, now: context.date))
                        .font(.islandNumber(13))
                        .foregroundStyle(event.color.color)
                }
            }
        }
    }

    static func relative(_ start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 0 ? "Now" : "in \(minutes)m"
    }
}
