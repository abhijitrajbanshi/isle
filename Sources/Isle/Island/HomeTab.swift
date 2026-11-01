import IsleKit
import SwiftUI

/// The open island: the most urgent live thing at full size (the "hero"),
/// everything else that's running as a row beneath it. No tabs, no fixed
/// size: it's as tall as what's in it. Clicking a row brings it up.
struct StackView: View {
    enum Hero: Hashable {
        case request(String), review(String), ci(String), pullRequest(String), call(String), music, agent(String),
             timer, task(String), usage, summary, quiet
    }
    enum Panel { case output, awake }

    @Environment(IslandEngine.self) private var engine
    @Environment(ActivityHub.self) private var hub
    @Environment(NowPlayingModel.self) private var player
    @Environment(CalendarModel.self) private var calendar
    @Environment(TimerModel.self) private var timer
    @Environment(AudioModel.self) private var audio
    @Environment(ShelfModel.self) private var shelf
    @Environment(GitHubModel.self) private var github
    @State private var pinned: Hero?
    @State private var panel: Panel?

    /// Everything live, most urgent first.
    private var candidates: [Hero] {
        var list: [Hero] = []
        let agents = hub.live.filter { $0.kind == .agent }
        list += agents.filter { $0.request != nil }.map { .request($0.id) }
        list += agents.filter { $0.request == nil && $0.state == .review }.map { .review($0.id) }
        list += github.live.filter { $0.state == .failed }.map { .ci($0.id) }
        list += github.pullRequests.prefix(3).filter { $0.kind == .reviewRequested || $0.kind == .changesRequested }
            .map { .pullRequest($0.id) }
        if let meeting = calendar.nextMeeting() { list.append(.call(meeting.id)) }
        if player.track != nil { list.append(.music) }
        list += agents.filter { $0.request == nil && $0.state != .review }.map { .agent($0.id) }
        if timer.isActive { list.append(.timer) }
        list += hub.live.filter { $0.kind == .task }.map { .task($0.id) }
        list += github.live.filter { $0.state != .failed }.map { .ci($0.id) }
        list += github.pullRequests.prefix(3).filter { $0.kind == .approved }.map { .pullRequest($0.id) }
        if shelf.summary != nil { list.append(.summary) }
        if hub.usage != nil, hub.isEnabled() { list.append(.usage) }
        return list
    }

    var body: some View {
        let all = candidates
        // a waiting request always wins; otherwise what you clicked, else the most urgent
        let hero = all.first.flatMap { if case .request = $0 { $0 } else { nil } }
            ?? pinned.flatMap { all.contains($0) ? $0 : nil } ?? all.first ?? .quiet
        let rows = all.filter { $0 != hero }

        VStack(alignment: .leading, spacing: 0) {
            header(for: hero)
                .frame(height: engine.metrics.size.height)
            Group {
                switch panel {
                case .output: OutputPicker { panel = nil }
                case .awake: AwakePicker { panel = nil }
                case nil: heroView(hero)
                }
            }
            .id(panel.map { "\($0)" } ?? "\(hero)")
            .transition(.islandContent)
            .padding(.top, 8)
            if panel == nil, !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.self) { row in
                        StackRow(hero: row) { pinned = row }
                    }
                }
                .padding(.top, 14)
            }
        }
        .animation(Motion.morph, value: hero)
        .animation(Motion.morph, value: rows)
        .animation(Motion.morph, value: panel)
    }

    // MARK: Header

    /// Left of the notch: what this is. Right: its state or one control.
    @ViewBuilder
    private func header(for hero: Hero) -> some View {
        // each side gets only the room beside the notch, so nothing slides under it
        let side = (engine.layout.expandedWidth - 44 - engine.metrics.size.width) / 2 - 12
        HStack(spacing: 0) {
            Group {
                if let panel {
                    Text(panel == .output ? "Sound output" : "Keep awake")
                } else {
                    Text(title(for: hero))
                }
            }
            .font(.island(12, .semibold))
            .foregroundStyle(Palette.secondaryLabel)
            .lineLimit(1)
            .frame(maxWidth: side, alignment: .leading)
            Spacer(minLength: 0)
            Group {
                if panel != nil {
                    CapsuleButton(title: "Done", isQuiet: true) { panel = nil }
                } else {
                    status(for: hero)
                }
            }
            .font(.island(12, .semibold))
            .frame(maxWidth: side, alignment: .trailing)
        }
        .padding(.top, 2)
    }

    private func requestStatus(_ id: String) -> String {
        switch hub.live.first(where: { $0.id == id })?.request?.kind {
        case .question: "Question"
        case .plan: "Plan ready"
        default: "Needs permission"
        }
    }

    private func title(for hero: Hero) -> String {
        switch hero {
        case .request(let id), .agent(let id), .review(let id):
            "Claude Code · \(hub.live.first { $0.id == id }?.title ?? "")"
        case .usage: "Claude usage"
        case .ci: "GitHub Actions"
        case .pullRequest: "Pull request"
        case .call: "Up next"
        case .music: "Now playing"
        case .timer: "Timer"
        case .task: "Task"
        case .summary: "Summary"
        case .quiet: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
    }

    @ViewBuilder
    private func status(for hero: Hero) -> some View {
        switch hero {
        case .request(let id):
            Text(requestStatus(id)).foregroundStyle(Palette.amber)
        case .review:
            Text("Ready for review").foregroundStyle(Palette.green)
        case .ci(let id):
            if let run = github.live.first(where: { $0.id == id }) {
                Text(run.state == .failed ? "Failed" : run.state == .passed ? "Passed" : "Running")
                    .foregroundStyle(run.state == .failed ? Palette.red : run.state == .passed ? Palette.green : Palette.secondaryLabel)
            }
        case .usage:
            if let model = hub.live.compactMap(\.meter?.model).first { Text(model).foregroundStyle(Palette.secondaryLabel) }
        case .call(let id):
            if let event = calendar.upcoming.first(where: { $0.id == id }) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(MeetingCopy.when(event, now: context.date)).foregroundStyle(Palette.green)
                }
            }
        case .music:
            if let output = audio.current {
                Chip(symbol: output.symbol, title: output.name, disclosure: true,
                     label: "Sound output: \(output.name)") { panel = .output }
            }
        default:
            EmptyView()
        }
    }

    // MARK: Hero

    @ViewBuilder
    private func heroView(_ hero: Hero) -> some View {
        switch hero {
        case .request(let id):
            if let activity = hub.live.first(where: { $0.id == id }), let request = activity.request {
                PermissionCard(activity: activity, request: request)
            }
        case .call(let id):
            if let event = calendar.upcoming.first(where: { $0.id == id }) {
                CallCard(event: event) { panel = .output }
            }
        case .music:
            NowPlayingCard()
        case .agent(let id):
            if let activity = hub.live.first(where: { $0.id == id }) { AgentCard(activity: activity) }
        case .review(let id):
            if let activity = hub.live.first(where: { $0.id == id }), let review = activity.review {
                ReviewCard(activity: activity, review: review)
            }
        case .usage:
            if let usage = hub.usage { UsageCard(usage: usage) }
        case .ci(let id):
            if let run = github.live.first(where: { $0.id == id }) { CICard(run: run) }
        case .pullRequest(let id):
            if let item = github.pullRequests.first(where: { $0.id == id }) { PullRequestCard(item: item) }
        case .timer:
            TimerTab()
        case .task(let id):
            if let activity = hub.live.first(where: { $0.id == id }) { TaskCard(activity: activity) }
        case .summary:
            if let summary = shelf.summary { SummaryCard(summary: summary) }
        case .quiet:
            QuietCard { panel = .awake }
        }
    }
}

// MARK: Rows

/// One line per other live thing: glyph, what it is, its state.
private struct StackRow: View {
    let hero: StackView.Hero
    let select: () -> Void
    @Environment(ActivityHub.self) private var hub
    @Environment(NowPlayingModel.self) private var player
    @Environment(CalendarModel.self) private var calendar
    @Environment(ShelfModel.self) private var shelf
    @Environment(GitHubModel.self) private var github
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                glyph
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.secondaryFill))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                label
                    .font(.island(13, .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .frame(height: 38)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
            .opacity(isHovering ? 0.8 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder private var glyph: some View {
        switch hero {
        case .music:
            ArtworkView(image: player.artwork, size: 24, cornerRadius: 7)
        case .request, .agent, .review:
            Image(systemName: "terminal.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondaryLabel)
        case .usage:
            Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hub.isNearLimit ? Palette.amber : Palette.secondaryLabel)
        case .ci(let id):
            let run = github.live.first { $0.id == id }
            if run?.state == .failed {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.red)
            } else if run?.state == .passed {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.green)
            } else {
                ProgressGlyph(progress: run?.progress ?? 0.02, size: 13)
            }
        case .pullRequest:
            Image(systemName: "arrow.triangle.pull").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondaryLabel)
        case .call:
            Image(systemName: "video.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.green)
        case .timer:
            Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.orange)
        case .summary:
            Image(systemName: "text.alignleft").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondaryLabel)
        case .task(let id):
            ProgressGlyph(progress: hub.live.first { $0.id == id }?.progress, size: 13)
        case .quiet:
            EmptyView()
        }
    }

    @ViewBuilder private var label: some View {
        switch hero {
        case .music:
            if let track = player.track {
                Text(track.title) + Text(track.artist.isEmpty ? "" : "  \(track.artist)").foregroundStyle(Palette.tertiaryLabel)
            }
        case .request(let id), .agent(let id), .task(let id), .review(let id):
            if let activity = hub.live.first(where: { $0.id == id }) {
                Text(activity.title) + Text("  \(activity.detail)").foregroundStyle(Palette.tertiaryLabel)
            }
        case .usage:
            Text("Claude usage") + Text("  5-hour window").foregroundStyle(Palette.tertiaryLabel)
        case .ci(let id):
            if let run = github.live.first(where: { $0.id == id }) {
                Text("CI · \(run.branch)") + Text("  \(run.repo)").foregroundStyle(Palette.tertiaryLabel)
            }
        case .pullRequest(let id):
            if let item = github.pullRequests.first(where: { $0.id == id }) {
                Text(item.title) + Text("  #\(item.number)").foregroundStyle(Palette.tertiaryLabel)
            }
        case .call(let id):
            Text(calendar.upcoming.first { $0.id == id }?.title ?? "Meeting")
        case .timer:
            Text("Timer")
        case .summary:
            Text("Summary") + Text("  \(shelf.summary?.file ?? "")").foregroundStyle(Palette.tertiaryLabel)
        case .quiet:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch hero {
        case .music:
            IslandButton(symbol: player.isPlaying ? "pause.fill" : "play.fill",
                         label: player.isPlaying ? "Pause" : "Play", size: 12, diameter: 26) { player.togglePlayPause() }
        case .request(let id), .agent(let id), .task(let id), .review(let id):
            if let activity = hub.live.first(where: { $0.id == id }) { ActivityStatus(activity: activity, size: 12) }
        case .ci(let id):
            if let run = github.live.first(where: { $0.id == id }) {
                switch run.state {
                case .running: Text("\(run.checks.filter(\.done).count)/\(run.checks.count)").font(.islandNumber(12, .medium))
                    .foregroundStyle(Palette.secondaryLabel)
                case .waiting: Text("Waiting").font(.island(12, .semibold)).foregroundStyle(Palette.secondaryLabel)
                case .passed: Text("Passed").font(.island(12, .semibold)).foregroundStyle(Palette.green)
                case .failed: Text("Failed").font(.island(12, .semibold)).foregroundStyle(Palette.red)
                }
            }
        case .pullRequest(let id):
            if let item = github.pullRequests.first(where: { $0.id == id }) {
                Text(PullRequestCopy.state(item.kind)).font(.island(12, .semibold)).foregroundStyle(PullRequestCopy.tint(item.kind))
            }
        case .usage:
            if let window = hub.usage?.fiveHour ?? hub.usage?.weekly {
                Text("\(Int(window.used))% · resets \(window.resetsAt.formatted(date: .omitted, time: .shortened))")
                    .font(.islandNumber(12, .medium))
                    .foregroundStyle(window.used >= 80 ? Palette.amber : Palette.secondaryLabel)
            }
        case .call(let id):
            if let event = calendar.upcoming.first(where: { $0.id == id }), let meeting = event.meeting {
                ActionPill(symbol: "video.fill", title: "Join", color: .white, height: 24) { calendar.join(meeting) }
            }
        case .timer:
            TimerCountdown(size: 12)
        case .summary:
            Text(shelf.summary?.isWorking == true ? "Reading" : "Ready")
                .font(.island(12, .semibold)).foregroundStyle(Palette.secondaryLabel)
        case .quiet:
            EmptyView()
        }
    }
}

// MARK: Call

/// A call about to start: Join (the one primary action), your mic, and
/// where you'll hear it.
private struct CallCard: View {
    let event: CalendarModel.Event
    let chooseOutput: () -> Void
    @Environment(CalendarModel.self) private var calendar
    @Environment(AudioModel.self) private var audio

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            CameraCheck()
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(event.title).font(.island(17, .semibold)).lineLimit(2)
            Text([event.meeting?.service.rawValue, event.start.formatted(date: .omitted, time: .shortened)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.island(13)).foregroundStyle(Palette.secondaryLabel)
                .padding(.top, 2)
            HStack(spacing: 8) {
                if let meeting = event.meeting {
                    CapsuleButton(title: "Join", isPrimary: true) { calendar.join(meeting) }
                }
                if audio.canMuteMic {
                    Chip(symbol: audio.isMicMuted ? "mic.slash.fill" : "mic.fill",
                         title: audio.isMicMuted ? "Muted" : "Mic on", isActive: audio.isMicMuted,
                         activeColor: Palette.red,
                         label: audio.isMicMuted ? "Unmute microphone" : "Mute microphone") { audio.toggleMicMute() }
                }
                if let output = audio.current {
                    Chip(symbol: output.symbol, title: output.name, disclosure: true,
                         label: "Sound output: \(output.name)", action: chooseOutput)
                }
            }
            .padding(.top, 14)
        }
    }
}

enum MeetingCopy {
    static func when(_ event: CalendarModel.Event, now: Date = .now) -> String {
        if event.start <= now { return "Now" }
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 1 ? "In 1 min" : "In \(minutes) min"
    }
}

// MARK: Quiet

/// Nothing running: the rest of today, and a few things to start.
private struct QuietCard: View {
    let keepAwake: () -> Void
    @Environment(IslandEngine.self) private var engine
    @Environment(CalendarModel.self) private var calendar
    @Environment(KeepAwakeModel.self) private var awake

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nothing running").font(.island(17, .semibold))
            Group {
                if let next = calendar.upcoming.first {
                    Text("Next: \(next.title) at \(next.start.formatted(date: .omitted, time: .shortened))")
                } else if calendar.hasAccess {
                    Text("Nothing else on your calendar today")
                } else {
                    Text("Agents, calls, music and tasks show up here")
                }
            }
            .font(.island(13)).foregroundStyle(Palette.secondaryLabel).lineLimit(1)
            .padding(.top, 2)
            HStack(spacing: 8) {
                Chip(symbol: "timer", title: "Timer") { engine.tab = .timer }
                Chip(symbol: "tray.full", title: "Shelf") { engine.tab = .shelf }
                Chip(symbol: awake.isOn ? "cup.and.heat.waves.fill" : "cup.and.saucer",
                     title: awake.isOn ? "Awake" : "Keep awake", isActive: awake.isOn, activeColor: Palette.orange,
                     disclosure: true, action: keepAwake)
            }
            .padding(.top, 14)
        }
    }
}

// MARK: Pickers

struct OutputPicker: View {
    @Environment(AudioModel.self) private var audio
    let done: () -> Void

    var body: some View {
        PickerList {
            ForEach(audio.outputs) { device in
                ListRow(symbol: device.symbol, title: device.name, isSelected: device.id == audio.currentOutput) {
                    audio.select(device)
                    done()
                }
            }
        }
    }
}

struct AwakePicker: View {
    @Environment(KeepAwakeModel.self) private var awake
    let done: () -> Void

    var body: some View {
        PickerList {
            ForEach(KeepAwakeModel.Duration.allCases) { duration in
                ListRow(symbol: duration == .indefinitely ? "infinity" : "clock", title: duration.title) {
                    awake.start(duration)
                    done()
                }
            }
            if awake.isOn {
                ListRow(symbol: "moon.zzz", title: "Allow sleep") {
                    awake.stop()
                    done()
                }
            }
        }
    }
}

private struct PickerList<Rows: View>: View {
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(spacing: 0) { rows }
            .padding(.horizontal, -10)
    }
}
