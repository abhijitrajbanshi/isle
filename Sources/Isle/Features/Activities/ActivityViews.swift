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

    private var needsYouLabel: String {
        switch activity.request?.kind {
        case .question: "Question"
        case .plan: "Plan ready"
        default: "Allow?"
        }
    }

    var body: some View {
        switch activity.state {
        case .needsYou:
            HStack(spacing: 5) {
                PulsingDot(color: Palette.amber)
                Text(needsYouLabel).font(.island(size, .semibold)).foregroundStyle(Palette.amber)
            }
        case .review:
            Text("Ready").font(.island(size, .semibold)).foregroundStyle(Palette.green)
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
        switch request.kind {
        case .question(let questions): QuestionCard(request: request, questions: questions)
        case .plan(let plan): PlanCard(request: request, plan: plan)
        case .permission: permission
        }
    }

    private var permission: some View {
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
                if let always = request.alwaysTitle {
                    CapsuleButton(title: always) { hub.decide(request, .allowAlways) }
                        .lineLimit(1)
                }
                CapsuleButton(title: "Deny") { hub.decide(request, .deny) }
                Spacer(minLength: 0)
                CapsuleButton(title: "Answer in Claude", isQuiet: true) { hub.withdraw(request.id) }
            }
            .padding(.top, 14)
        }
    }
}

/// Claude asks you to choose: the options as buttons. Several questions
/// are answered one after another; multiple choice collects, then Continue.
struct QuestionCard: View {
    let request: ActivityHub.PermissionRequest
    let questions: [ActivityHub.PermissionRequest.Question]
    @Environment(ActivityHub.self) private var hub
    @State private var step = 0
    @State private var answers: [String: String] = [:]
    @State private var picked: Set<String> = []

    var body: some View {
        let question = questions[min(step, questions.count - 1)]
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(question.text).font(.island(17, .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if questions.count > 1 {
                    Text("\(step + 1) of \(questions.count)").font(.islandNumber(12, .medium))
                        .foregroundStyle(Palette.tertiaryLabel)
                }
            }
            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    OptionButton(number: index + 1, title: option, isOn: picked.contains(option),
                                 showsCheck: question.multiSelect) {
                        choose(option, in: question)
                    }
                }
            }
            .padding(.top, 12)
            HStack(spacing: 8) {
                if question.multiSelect {
                    CapsuleButton(title: "Continue", isPrimary: true) { commit(question) }
                        .disabled(picked.isEmpty)
                }
                Spacer(minLength: 0)
                CapsuleButton(title: "Answer in Claude", isQuiet: true) { hub.withdraw(request.id) }
            }
            .padding(.top, 10)
        }
        .id(step)
        .transition(.islandContent)
        .animation(Motion.morph, value: step)
    }

    private func choose(_ option: String, in question: ActivityHub.PermissionRequest.Question) {
        guard question.multiSelect else {
            picked = [option]
            commit(question)
            return
        }
        if picked.contains(option) { picked.remove(option) } else { picked.insert(option) }
    }

    private func commit(_ question: ActivityHub.PermissionRequest.Question) {
        // keep the options' order for multiple choice
        answers[question.text] = question.options.filter(picked.contains).joined(separator: ", ")
        picked = []
        if step + 1 < questions.count {
            step += 1
        } else {
            hub.decide(request, .answers(answers))
        }
    }
}

private struct OptionButton: View {
    let number: Int
    let title: String
    let isOn: Bool
    let showsCheck: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.tertiaryLabel)
                    .frame(width: 18, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.fill, lineWidth: 1))
                Text(title).font(.island(13, .medium)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                if showsCheck {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isOn ? Color.white : Palette.tertiaryLabel)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovering || isOn ? Palette.fill : Palette.secondaryFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
    }
}

/// Claude has a plan and wants to start: its outline, then go or keep planning.
struct PlanCard: View {
    let request: ActivityHub.PermissionRequest
    let plan: String
    @Environment(ActivityHub.self) private var hub

    /// The plan's headings and first-level steps, without markdown syntax.
    private var outline: [String] {
        plan.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("#") || $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.first?.isNumber == true }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-* ")) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ready to start?").font(.island(17, .semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(outline.prefix(5).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.island(13)).foregroundStyle(Palette.secondaryLabel).lineLimit(1)
                }
                if outline.count > 5 {
                    Text("and \(outline.count - 5) more").font(.island(12)).foregroundStyle(Palette.tertiaryLabel)
                }
            }
            .padding(.top, 8)
            HStack(spacing: 8) {
                CapsuleButton(title: "Start", isPrimary: true) { hub.decide(request, .allow) }
                CapsuleButton(title: "Keep planning") { hub.decide(request, .keepPlanning) }
                Spacer(minLength: 0)
                CapsuleButton(title: "Read in Claude", isQuiet: true) { hub.withdraw(request.id) }
            }
            .padding(.top, 14)
        }
    }
}

/// A finished session: what it changed, whether tests passed, and where to look.
struct ReviewCard: View {
    let activity: ActivityHub.Activity
    let review: ActivityHub.Review
    @Environment(ActivityHub.self) private var hub
    @State private var showsFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(review.summary.isEmpty ? "Ready for review" : review.summary)
                .font(.island(17, .semibold)).lineLimit(2)
            HStack(spacing: 12) {
                Text(review.minutes >= 1 ? "Worked \(review.minutes) min" : "Finished")
                if let test = activity.lastTest {
                    Label(test.passed ? "Tests passed" : "Tests failed",
                          systemImage: test.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(test.passed ? Palette.green : Palette.red)
                }
                if !review.files.isEmpty { Text("\(review.files.count) files") }
                if review.added + review.removed > 0 {
                    HStack(spacing: 6) {
                        Text("+\(review.added)").foregroundStyle(Palette.green)
                        Text("−\(review.removed)").foregroundStyle(Palette.red)
                    }
                    .font(.islandNumber(13, .medium))
                }
            }
            .font(.island(13))
            .foregroundStyle(Palette.secondaryLabel)
            .padding(.top, 3)

            if showsFiles {
                VStack(spacing: 0) {
                    ForEach(review.files.prefix(8)) { file in
                        FileRow(file: file, folder: activity.cwd)
                    }
                    if review.files.count > 8 {
                        Text("and \(review.files.count - 8) more").font(.island(12))
                            .foregroundStyle(Palette.tertiaryLabel).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
                .padding(.top, 10)
            }

            HStack(spacing: 8) {
                if !review.files.isEmpty {
                    CapsuleButton(title: showsFiles ? "Hide changes" : "Review changes", isPrimary: !showsFiles) {
                        showsFiles.toggle()
                    }
                }
                if let pr = review.pullRequest {
                    CapsuleButton(title: "Open PR") { NSWorkspace.shared.open(pr) }
                }
                if activity.host != nil {
                    CapsuleButton(title: "Go to session") { hub.focus(activity) }
                }
                Spacer(minLength: 0)
                CapsuleButton(title: "Done", isQuiet: true) { hub.dismissReview(activity.id) }
            }
            .padding(.top, 14)
        }
        .animation(Motion.morph, value: showsFiles)
    }
}

private struct FileRow: View {
    let file: ActivityHub.Review.File
    let folder: String
    @State private var isHovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: folder).appendingPathComponent(file.path))
        } label: {
            HStack(spacing: 8) {
                Text((file.path as NSString).lastPathComponent).font(.island(12.5, .medium)).lineLimit(1)
                Text((file.path as NSString).deletingLastPathComponent)
                    .font(.island(11.5)).foregroundStyle(Palette.tertiaryLabel).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 6)
                Text("+\(file.added)").foregroundStyle(Palette.green)
                Text("−\(file.removed)").foregroundStyle(Palette.red)
            }
            .font(.islandNumber(12, .medium))
            .frame(height: 26)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovering ? Palette.secondaryFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, -8)
    }
}

// MARK: Usage

/// Your Claude limits: two meters, the reset times, and a forecast.
struct UsageCard: View {
    let usage: ActivityHub.Usage
    @Environment(ActivityHub.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let window = usage.fiveHour {
                UsageMeter(title: "5-hour window", window: window, forecast: usage.capForecast)
            }
            if let window = usage.weekly {
                UsageMeter(title: "This week", window: window, forecast: nil, resetFormat: .weekday)
            }
            let sessions = hub.live.filter { $0.meter?.costUSD != nil }
            if !sessions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        HStack {
                            Text(session.title).font(.island(13, .medium))
                            if let context = session.meter?.contextPercent {
                                Text("context \(Int(context))%").font(.island(12))
                                    .foregroundStyle(context >= 80 ? Palette.amber : Palette.tertiaryLabel)
                            }
                            Spacer()
                            if let cost = session.meter?.costUSD {
                                Text(cost, format: .currency(code: "USD")).font(.islandNumber(12, .medium))
                                    .foregroundStyle(Palette.secondaryLabel)
                            }
                        }
                        .frame(height: 30)
                        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
                    }
                }
            }
        }
    }
}

private struct UsageMeter: View {
    enum ResetFormat { case time, weekday }
    let title: String
    let window: ActivityHub.Usage.Window
    let forecast: Date?
    var resetFormat: ResetFormat = .time

    var body: some View {
        let warn = window.used >= 80
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.island(13, .semibold))
                Spacer()
                Text("\(Int(window.used))% · resets \(resets)")
                    .font(.islandNumber(12, .medium))
                    .foregroundStyle(warn ? Palette.amber : Palette.secondaryLabel)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.fill)
                    Capsule().fill(warn ? Palette.amber : Color.white)
                        .frame(width: geo.size.width * min(window.used / 100, 1))
                }
            }
            .frame(height: 6)
            if let forecast {
                Text("At this pace you'll reach the limit around \(forecast.formatted(date: .omitted, time: .shortened))")
                    .font(.island(12)).foregroundStyle(Palette.amber)
            }
        }
    }

    private var resets: String {
        switch resetFormat {
        case .time: window.resetsAt.formatted(date: .omitted, time: .shortened)
        case .weekday: window.resetsAt.formatted(.dateTime.weekday(.abbreviated))
        }
    }
}

/// Beside the notch when a window is nearly used up.
struct UsageCompactLeading: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 12, weight: .semibold))
            Text("Claude").font(.island(13, .semibold))
        }
        .foregroundStyle(Palette.secondaryLabel)
    }
}

struct UsageCompactTrailing: View {
    @Environment(ActivityHub.self) private var hub

    var body: some View {
        if let usage = hub.usage {
            let window = (usage.fiveHour?.used ?? 0) >= 80 ? usage.fiveHour : usage.weekly
            if let window {
                // one fact a side: how full; when it resets is in the open island
                Text("\(Int(window.used))%")
                    .font(.islandNumber(13, .semibold)).foregroundStyle(Palette.amber)
            }
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
