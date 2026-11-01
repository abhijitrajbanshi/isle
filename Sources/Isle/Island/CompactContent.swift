import IsleKit
import SwiftUI

/// Leading and trailing content either side of the notch.
struct CompactContent: View {
    @Environment(IslandEngine.self) private var engine
    let activity: LiveActivity

    /// Inset from the body edge, matched to the corner radius so content
    /// sits optically centred in each lobe.
    private let inset: CGFloat = 11

    var body: some View {
        let side = engine.layout.sideWidth(for: activity)
        let height = engine.metrics.size.height
        HStack(spacing: 0) {
            leading(height: height).frame(width: side - inset, alignment: .leading)
            Spacer(minLength: 0)
            trailing.frame(width: side - inset, alignment: .trailing)
        }
        .padding(.horizontal, inset)
        .frame(height: height)
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
