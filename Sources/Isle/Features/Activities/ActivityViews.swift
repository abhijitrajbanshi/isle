import IsleKit
import SwiftUI

// MARK: Compact

/// What it is: the agent glyph and project, or the task's progress.
struct ActivityCompactLeading: View {
    @Environment(ActivityHub.self) private var hub
    let kind: ActivityHub.Activity.Kind

    var body: some View {
        if let activity = hub.live.first(where: { $0.kind == kind }) {
            HStack(spacing: 5) {
                if kind == .agent {
                    Image(systemName: "terminal.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.secondaryLabel)
                    Text(activity.title).font(.island(13, .semibold)).lineLimit(1)
                } else {
                    ProgressGlyph(progress: activity.progress, size: 15)
                }
            }
        }
    }
}

/// Its state: "Allow?" when it needs you, else elapsed time or progress.
struct ActivityCompactTrailing: View {
    @Environment(ActivityHub.self) private var hub
    let kind: ActivityHub.Activity.Kind

    var body: some View {
        if let activity = hub.live.first(where: { $0.kind == kind }) {
            ActivityStatus(activity: activity, size: 13)
        }
    }
}

struct ActivityBubble: View {
    @Environment(ActivityHub.self) private var hub
    let kind: ActivityHub.Activity.Kind

    var body: some View {
        if let activity = hub.live.first(where: { $0.kind == kind }) {
            ZStack(alignment: .topTrailing) {
                if kind == .agent {
                    Image(systemName: "terminal.fill").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.secondaryLabel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressGlyph(progress: activity.progress, size: 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if activity.state == .needsYou {
                    Circle().fill(Palette.amber).frame(width: 7, height: 7).offset(x: -5, y: 5)
                }
            }
        }
    }
}

/// The trailing fact: amber "Allow?", "Your turn", a percentage or how long.
struct ActivityStatus: View {
    let activity: ActivityHub.Activity
    var size: CGFloat = 13

    var body: some View {
        switch activity.state {
        case .needsYou:
            HStack(spacing: 5) {
                PulsingDot(color: Palette.amber)
                Text("Allow?").font(.island(size, .semibold)).foregroundStyle(Palette.amber)
            }
        case .yourTurn:
            Text("Your turn").font(.island(size, .semibold)).foregroundStyle(Palette.green)
        case .working:
            if let progress = activity.progress {
                Text("\(Int((progress * 100).rounded()))%").font(.islandNumber(size, .semibold))
            } else {
                // minutes, not seconds: calm, and nothing ticks every second
                TimelineView(.periodic(from: activity.started, by: 30)) { context in
                    Text(Elapsed.short(since: activity.started, now: context.date))
                        .font(.islandNumber(size, .semibold))
                        .foregroundStyle(Palette.secondaryLabel)
                        .contentTransition(.numericText())
                }
            }
        }
    }
}

enum Elapsed {
    static func short(since start: Date, now: Date = .now) -> String {
        let minutes = Int(now.timeIntervalSince(start) / 60)
        switch minutes {
        case ..<1: return "Working"
        case ..<60: return "\(minutes)m"
        default: return "\(minutes / 60)h \(minutes % 60)m"
        }
    }
}

struct PulsingDot: View {
    let color: Color
    @State private var dim = false
    @Environment(\.prefersStillness) private var prefersStillness

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(dim ? 0.35 : 1)
            .animation(prefersStillness ? nil : .easeInOut(duration: 0.8).repeatForever(), value: dim)
            .onAppear { if !prefersStillness { dim = true } }
    }
}

/// A thin progress ring, or a terminal glyph when the task can't say how far along it is.
struct ProgressGlyph: View {
    let progress: Double?
    var size: CGFloat = 16

    var body: some View {
        if let progress {
            ZStack {
                Circle().stroke(Palette.fill, lineWidth: 2.2)
                Circle().trim(from: 0, to: max(0.02, progress))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.morph, value: progress)
            }
            .frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape.2.fill").font(.system(size: size * 0.8, weight: .semibold))
                .foregroundStyle(Palette.secondaryLabel)
        }
    }
}

// MARK: Open: heroes

/// An agent asking for permission: the question, exactly what it wants to
/// do, and Allow as the one primary action.
struct PermissionCard: View {
    let activity: ActivityHub.Activity
    let request: ActivityHub.PermissionRequest
    @Environment(ActivityHub.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(request.question).font(.island(17, .semibold))
            Text(request.subject)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Palette.label)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.secondaryFill))
                .padding(.top, 10)
            HStack(spacing: 8) {
                CapsuleButton(title: "Allow", isPrimary: true) { hub.decide(request, .allow) }
                CapsuleButton(title: "Deny") { hub.decide(request, .deny) }
                Spacer(minLength: 0)
                CapsuleButton(title: "Answer in Claude", isQuiet: true) { hub.withdraw(request.id) }
            }
            .padding(.top, 14)
        }
    }
}

/// An agent at work: what it's doing and for how long.
struct AgentCard: View {
    let activity: ActivityHub.Activity

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "terminal.fill").font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.secondaryLabel)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.secondaryFill))
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.detail.isEmpty ? "Working" : activity.detail)
                    .font(.island(17, .semibold)).lineLimit(1)
                Text(activity.state == .yourTurn ? "Waiting for your next message" : "Claude Code")
                    .font(.island(13)).foregroundStyle(Palette.secondaryLabel)
            }
            Spacer(minLength: 8)
            ActivityStatus(activity: activity, size: 13)
        }
    }
}

/// A task posted through `isle`: progress bar when it reports one.
struct TaskCard: View {
    let activity: ActivityHub.Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(activity.title).font(.island(17, .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                ActivityStatus(activity: activity)
            }
            if !activity.detail.isEmpty {
                Text(activity.detail).font(.island(13)).foregroundStyle(Palette.secondaryLabel).lineLimit(1)
            }
            if let progress = activity.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.fill)
                        Capsule().fill(Color.white).frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 4)
                .animation(Motion.morph, value: progress)
            }
        }
    }
}

/// Text capsule: the primary action is white with black text; the rest are quiet fills.
struct CapsuleButton: View {
    let title: String
    var isPrimary = false
    var isQuiet = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.island(13, .semibold))
                .foregroundStyle(isPrimary ? Color.black : (isQuiet ? Palette.secondaryLabel : Palette.label))
                .padding(.horizontal, isQuiet ? 6 : 16)
                .frame(height: 32)
                .background {
                    if !isQuiet {
                        Capsule().fill(isPrimary ? Color.white : Palette.secondaryFill)
                            .brightness(isHovering ? (isPrimary ? -0.06 : 0.05) : 0)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
    }
}
