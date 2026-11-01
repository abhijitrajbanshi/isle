import IsleKit
import SwiftUI

// MARK: Compact

struct CICompactLeading: View {
    @Environment(GitHubModel.self) private var github

    var body: some View {
        if let run = github.live.first {
            switch run.state {
            case .passed:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Palette.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Palette.red)
            case .waiting, .running:
                ProgressGlyph(progress: run.progress ?? 0.02, size: 15)
            }
        }
    }
}

struct CICompactTrailing: View {
    @Environment(GitHubModel.self) private var github

    var body: some View {
        if let run = github.live.first {
            Group {
                switch run.state {
                case .waiting: Text("CI").foregroundStyle(Palette.secondaryLabel)
                case .running:
                    Text("\(run.checks.filter(\.done).count)/\(run.checks.count)").foregroundStyle(Palette.secondaryLabel)
                case .passed: Text("Passed").foregroundStyle(Palette.green)
                case .failed: Text("Failed").foregroundStyle(Palette.red)
                }
            }
            .font(.islandNumber(13, .semibold))
        }
    }
}

// MARK: Open

/// A pushed commit's checks: progress, then the result and the way to the failure.
struct CICard: View {
    let run: GitHubModel.Run
    @Environment(GitHubModel.self) private var github

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headline).font(.island(17, .semibold))
            Text("\(run.repo) · \(String(run.sha.prefix(7)))")
                .font(.island(13)).foregroundStyle(Palette.secondaryLabel).padding(.top, 2)
            if run.state == .running, let progress = run.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.fill)
                        Capsule().fill(Color.white).frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 4)
                .padding(.top, 12)
                .animation(Motion.morph, value: progress)
            }
            let failed = run.checks.filter(\.failed)
            if !failed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(failed.prefix(3).enumerated()), id: \.offset) { _, check in
                        Label(check.name, systemImage: "xmark.circle.fill")
                            .font(.island(13)).foregroundStyle(Palette.red).lineLimit(1)
                    }
                }
                .padding(.top, 10)
            }
            if !run.deploys.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(run.deploys.enumerated()), id: \.offset) { _, deploy in
                        DeployRow(deploy: deploy)
                    }
                }
                .padding(.top, 10)
            }
            HStack(spacing: 8) {
                if let failing = run.failing, let url = failing.url {
                    CapsuleButton(title: "Open failing job", isPrimary: true) { NSWorkspace.shared.open(url) }
                } else if let url = run.checks.first?.url {
                    CapsuleButton(title: "Open checks") { NSWorkspace.shared.open(url) }
                }
                Spacer(minLength: 0)
                if run.state == .failed || run.state == .passed {
                    CapsuleButton(title: "Done", isQuiet: true) { github.dismiss(run) }
                }
            }
            .padding(.top, 14)
        }
    }

    private var headline: String {
        switch run.state {
        case .waiting: "Waiting for CI · \(run.branch)"
        case .running: "CI running · \(run.branch)"
        case .passed: run.deploys.contains { $0.state == .ready && !$0.isProduction } ? "Preview ready · \(run.branch)"
                                                                                      : "CI passed · \(run.branch)"
        case .failed: "CI failed · \(run.branch)"
        }
    }
}

private struct DeployRow: View {
    let deploy: GitHubModel.Deploy
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch deploy.state {
                case .building: Image(systemName: "clock").foregroundStyle(Palette.secondaryLabel)
                case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.red)
                }
            }
            .font(.system(size: 13))
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(deploy.title).font(.island(13, .semibold))
                if let host = deploy.url?.host {
                    Text(host).font(.island(11.5)).foregroundStyle(Palette.tertiaryLabel).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            switch deploy.state {
            case .ready:
                if let url = deploy.url {
                    CapsuleButton(title: copied ? "Copied" : "Copy URL", isQuiet: true) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        copied = true
                    }
                    CapsuleButton(title: "Open") { NSWorkspace.shared.open(url) }
                }
            case .failed:
                if let logs = deploy.logs { CapsuleButton(title: "Open logs") { NSWorkspace.shared.open(logs) } }
            case .building:
                Text("Deploying").font(.island(12, .semibold)).foregroundStyle(Palette.secondaryLabel)
            }
        }
        .frame(minHeight: 40)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
    }
}

/// A pull request waiting on you, or a review on yours.
struct PullRequestCard: View {
    let item: GitHubModel.PullRequestItem
    @Environment(GitHubModel.self) private var github

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.title).font(.island(17, .semibold)).lineLimit(2)
            Text("\(item.repo) #\(item.number) · \(PullRequestCopy.state(item.kind))")
                .font(.island(13)).foregroundStyle(PullRequestCopy.tint(item.kind)).padding(.top, 2)
            HStack {
                CapsuleButton(title: item.kind == .reviewRequested ? "Review" : "Open", isPrimary: true) { github.open(item) }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
        }
    }
}

enum PullRequestCopy {
    static func state(_ kind: GitHubModel.PullRequestItem.Kind) -> String {
        switch kind {
        case .reviewRequested: "Review requested"
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .activity: "Updated"
        }
    }

    static func tint(_ kind: GitHubModel.PullRequestItem.Kind) -> Color {
        switch kind {
        case .reviewRequested: Palette.amber
        case .approved: Palette.green
        case .changesRequested: Palette.red
        case .activity: Palette.secondaryLabel
        }
    }

    static func symbol(_ event: PullRequestInfo.Event) -> String {
        switch event {
        case .reviewRequested: "eye"
        case .approved: "checkmark.seal.fill"
        case .changesRequested: "exclamationmark.bubble.fill"
        }
    }
}
