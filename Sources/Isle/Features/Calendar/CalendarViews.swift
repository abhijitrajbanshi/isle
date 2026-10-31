import SwiftUI

struct CalendarCompactLeading: View {
    @Environment(CalendarModel.self) private var calendar

    var body: some View {
        if let event = calendar.current() {
            Image(systemName: "calendar")
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
                Text(Self.relative(event.start, now: context.date))
                    .font(.islandNumber(13))
                    .foregroundStyle(event.color.color)
            }
        }
    }

    static func relative(_ start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 0 ? "Now" : "in \(minutes)m"
    }
}

/// Today card on the Home tab, after the iOS Calendar widget.
struct CalendarWidget: View {
    @Environment(CalendarModel.self) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Date.now.formatted(.dateTime.weekday(.wide)).uppercased())
                .font(.island(10.5, .semibold))
                .foregroundStyle(Palette.red)
                .kerning(0.3)
            Text(Date.now.formatted(.dateTime.day()))
                .font(.system(size: 28, weight: .regular))
                .padding(.bottom, 2)
            Spacer(minLength: 2)
            content
        }
        .contentShape(Rectangle())
        .onTapGesture { calendar.openCalendar() }
    }

    @ViewBuilder private var content: some View {
        if !calendar.hasAccess {
            Button { calendar.requestAccess() } label: {
                Text("Show events").font(.island(11.5, .semibold)).foregroundStyle(Palette.blue)
            }
            .buttonStyle(PressableStyle())
        } else if calendar.upcoming.isEmpty {
            Text("No more events today").font(.island(11.5)).foregroundStyle(Palette.tertiaryLabel)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(calendar.upcoming.prefix(2)) { event in
                    HStack(spacing: 7) {
                        Capsule().fill(event.color.color).frame(width: 3)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(event.title).font(.island(11.5, .semibold)).lineLimit(1)
                            Text(event.start.formatted(date: .omitted, time: .shortened))
                                .font(.island(10.5)).foregroundStyle(Palette.secondaryLabel)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
