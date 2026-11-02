import IsleKit
import SwiftUI

/// Leading and trailing content either side of the notch.
struct CompactContent: View {
    @Environment(IslandEngine.self) private var engine
    let activity: LiveActivity

    /// Whether this activity's sides follow its content (everything but the
    /// balanced music and privacy glances).
    private var hugsNotch: Bool { activity != .nowPlaying && activity != .privacy }

    var body: some View {
        let sides = engine.layout.sides(for: activity)
        let height = engine.metrics.size.height
        let outer = IslandLayout.outerInset
        if hugsNotch {
            // both sides hug the notch: the icon ends just before it, the word starts just after
            let gap = IslandLayout.notchGap
            HStack(spacing: 0) {
                measured(leading(height: height)) { width in record(leading: width) }
                    .frame(width: max(sides.leading - outer - gap, 0), alignment: .trailing)
                Spacer(minLength: 0)
                measured(trailing) { width in record(trailing: width) }
                    .frame(width: max(sides.trailing - outer - gap, 0), alignment: .leading)
            }
            .padding(.horizontal, outer)
            .frame(height: height)
        } else {
            HStack(spacing: 0) {
                leading(height: height).frame(width: sides.leading - outer, alignment: .leading)
                Spacer(minLength: 0)
                trailing.frame(width: sides.trailing - outer, alignment: .trailing)
            }
            .padding(.horizontal, outer)
            .frame(height: height)
        }
    }

    /// The content at its natural width, reported so the island can fit it.
    private func measured(_ content: some View, report: @escaping (CGFloat) -> Void) -> some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report($0) }
    }

    private func record(leading: CGFloat? = nil, trailing: CGFloat? = nil) {
        var widths = engine.compactContent[activity] ?? CompactContentWidth(leading: 0, trailing: 0)
        if let leading { widths.leading = leading }
        if let trailing { widths.trailing = trailing }
        // ignore sub-point jitter so text updates don't nudge the island
        guard let old = engine.compactContent[activity],
              abs(old.leading - widths.leading) < 0.5, abs(old.trailing - widths.trailing) < 0.5 else {
            engine.compactContent[activity] = widths
            return
        }
    }

    @ViewBuilder
    private func leading(height: CGFloat) -> some View {
        switch activity {
        case .nowPlaying: NowPlayingCompactLeading(size: height - 12)
        case .timer: TimerCompactLeading()
        case .calendar: CalendarCompactLeading()
        case .privacy: PrivacyCompactLeading()
        case .agent: ActivityCompactLeading(kind: .agent)
        case .task: ActivityCompactLeading(kind: .task)
        case .usage: UsageCompactLeading()
        case .ci: CICompactLeading()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity {
        case .nowPlaying: NowPlayingCompactTrailing()
        case .timer: TimerCountdown(size: 14)
        case .calendar: CalendarCompactTrailing()
        case .privacy: PrivacyDot()
        case .agent: ActivityCompactTrailing(kind: .agent)
        case .task: ActivityCompactTrailing(kind: .task)
        case .usage: UsageCompactTrailing()
        case .ci: CICompactTrailing()
        }
    }
}

/// The detached circle for the second live activity.
struct BubbleContent: View {
    let activity: LiveActivity
    let diameter: CGFloat

    var body: some View {
        switch activity {
        case .nowPlaying: NowPlayingBubble(diameter: diameter)
        case .timer: TimerBubble()
        case .calendar: CalendarCompactLeading()
        case .privacy: PrivacyDot()
        case .agent: ActivityBubble(kind: .agent)
        case .task: ActivityBubble(kind: .task)
        case .usage:
            Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.amber)
        case .ci: CICompactLeading()
        }
    }
}
