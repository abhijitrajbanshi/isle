import IsleKit
import ServiceManagement
import SwiftUI

/// Settings in the System Settings style: a sidebar of panes, one per part
/// of Isle, agents first.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case agents, calls, music, island, alerts, general

        var id: Self { self }

        var title: String {
            switch self {
            case .agents: "Agents"
            case .calls: "Calls & Calendar"
            case .music: "Music"
            case .island: "Island"
            case .alerts: "Alerts"
            case .general: "General"
            }
        }

        var symbol: String {
            switch self {
            case .agents: "terminal.fill"
            case .calls: "video.fill"
            case .music: "music.note"
            case .island: "capsule.fill"
            case .alerts: "bell.badge.fill"
            case .general: "gearshape.fill"
            }
        }

        var tint: Color {
            switch self {
            case .agents: Color(red: 0.96, green: 0.6, blue: 0.14)
            case .calls: Color(red: 0.2, green: 0.72, blue: 0.42)
            case .music: Color(red: 0.98, green: 0.3, blue: 0.4)
            case .island: Color(white: 0.18)
            case .alerts: Color(red: 0.95, green: 0.3, blue: 0.25)
            case .general: Color(white: 0.55)
            }
        }
    }

    @State private var pane: Pane = .agents

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(pane.tint.gradient))
                }
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(196)
            .safeAreaInset(edge: .top) { SidebarHeader().padding(.horizontal, 14).padding(.bottom, 6) }
        } detail: {
            Group {
                switch pane {
                case .agents: AgentsPane()
                case .calls: CallsPane()
                case .music: MusicPane()
                case .island: IslandPane()
                case .alerts: AlertsPane()
                case .general: GeneralPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(width: 720, height: 540)
    }
}

private struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("Isle").font(.headline)
                Text(Updater.currentVersion).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: Agents

private struct AgentsPane: View {
    @Environment(Preferences.self) private var preferences
    @Environment(GitHubModel.self) private var github
    @State private var connected = ClaudeConnector.isConnected
    @State private var shellConnected = ShellConnector.isConnected
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        @Bindable var p = preferences
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.black))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Code").font(.headline)
                        Text(connected ? "Sessions report to the notch, in the app and the terminal."
                                       : "See what Claude is doing and answer its requests from the notch.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if connected {
                        Menu {
                            Button("Disconnect") { change(ClaudeConnector.disconnect) }
                        } label: {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .foregroundStyle(.green)
                    } else {
                        Button("Connect") { change(ClaudeConnector.connect) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            } footer: {
                Note("Connecting adds Isle's hooks to ~/.claude/settings.json and keeps a backup next to it. If you don't answer a request within 45 seconds, or Claude's own window is in front, Claude asks you as usual.")
            }

            Section {
                Toggle("Show agents in the notch", isOn: $p.agents)
                Toggle("Open the island when an agent needs permission", isOn: $p.openForRequests)
                    .disabled(!p.agents)
            }

            Section {
                LabeledContent("Account") {
                    if let login = github.signedIn {
                        Label(login, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("Run gh auth login in Terminal").foregroundStyle(.secondary)
                    }
                }
                Toggle("CI on what you push", isOn: $p.githubCI)
                Toggle("Pull requests waiting on you", isOn: $p.githubReviews)
            } header: {
                Text("GitHub")
            } footer: {
                Note("Uses your gh login; nothing new to sign into. After a push from a connected terminal or an agent, the notch follows its checks and tells you when they pass or fail. Review requests and reviews on your pull requests are checked every two minutes while the screen is on.")
            }

            Section {
                LabeledContent("Long commands") {
                    if shellConnected {
                        Menu {
                            Button("Disconnect") { changeShell(ShellConnector.disconnect) }
                        } label: {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .foregroundStyle(.green)
                    } else {
                        Button("Connect") { changeShell(ShellConnector.connect) }
                    }
                }
            } header: {
                Text("Terminal")
            } footer: {
                Note("Any command that runs longer than 30 seconds shows in the notch, and you get ✓ or ✗ when it ends, unless its terminal is in front. Connecting adds three lines to ~/.zshrc and keeps a backup; new terminal windows pick it up.")
            }

            Section {
                LabeledContent("Command") {
                    HStack(spacing: 8) {
                        Text("isle").font(.system(.body, design: .monospaced))
                        Button(copied ? "Copied" : "Copy Path") {
                            let path = ClaudeConnector.helperPath ?? "/Applications/Isle.app/Contents/Helpers/isle"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                            copied = true
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Example(command: "isle run -- make release", note: "live while it runs, ✓ or ✗ when it ends")
                    Example(command: "isle progress upload 0.4 --title Upload", note: "a progress ring in the notch")
                    Example(command: "isle done upload", note: "finish it")
                }
                .padding(.vertical, 2)
            } header: {
                Text("Scripts and builds")
            } footer: {
                Note("Anything you run can report to the notch. When Isle isn't running, these do nothing.")
            }
        }
    }

    private func change(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        connected = ClaudeConnector.isConnected
    }

    private func changeShell(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        shellConnected = ShellConnector.isConnected
    }
}

private struct Example: View {
    let command: String
    let note: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Calls & Calendar

private struct CallsPane: View {
    @Environment(Preferences.self) private var preferences
    @Environment(CalendarModel.self) private var calendar

    var body: some View {
        @Bindable var p = preferences
        Form {
            Section {
                Toggle("Upcoming events", isOn: $p.calendar)
                    .onChange(of: p.calendar) { _, on in if on, !calendar.hasAccess { calendar.requestAccess() } }
                if p.calendar, !calendar.hasAccess {
                    LabeledContent("Calendar access") {
                        Button("Allow Access") { calendar.requestAccess() }
                    }
                }
            } footer: {
                Note("Events show beside the notch 15 minutes before they start, with a reminder at 5. Calls on Zoom, Google Meet, Teams, Webex, FaceTime, Slack and Whereby get a Join button.")
            }
            Section {
                Toggle("Camera and microphone in use", isOn: $p.privacyIndicators)
            } footer: {
                Note("A dot beside the notch while any app uses them; a red mic when an app is listening and you're muted. Mute and Check camera are in the call card.")
            }
        }
    }
}

// MARK: Music

private struct MusicPane: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var p = preferences
        Form {
            Section {
                Toggle("Now Playing", isOn: $p.nowPlaying)
                Toggle("Include browsers and all other apps", isOn: $p.allPlayers)
                    .disabled(!p.nowPlaying)
            } footer: {
                Note("Without “all other apps”, Isle follows Music and Spotify only. Music leaves the notch two seconds after you pause; open the island to resume.")
            }
        }
    }
}

// MARK: Island

private struct IslandPane: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var p = preferences
        Form {
            Section {
                Picker("Material", selection: $p.style) {
                    ForEach(IslandStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Note("Black is continuous with the notch. Liquid Glass shows the desktop through the open island.")
            }
            Section {
                Toggle("Open on hover", isOn: $p.expandOnHover)
                if p.expandOnHover {
                    LabeledContent("Hover delay") {
                        HStack(spacing: 10) {
                            Slider(value: $p.hoverDelay, in: 0.05...0.6).frame(width: 160)
                            Text("\(Int(p.hoverDelay * 1000)) ms")
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                Toggle("Swipe gestures", isOn: $p.swipeGestures)
                    .help("On the island: swipe up to close, down to open, left or right to skip tracks.")
                Toggle("Haptic feedback", isOn: $p.haptics)
            } footer: {
                Note("Hover opens the island once the pointer settles, so passing through on the way to the menu bar doesn't.")
            }
            Section {
                Picker("Show on", selection: $p.display) {
                    Text("Built-in display").tag(Preferences.DisplayChoice.builtIn)
                    Text("Main display").tag(Preferences.DisplayChoice.main)
                }
                Toggle("Use on displays without a notch", isOn: $p.showOnDisplaysWithoutNotch)
                Toggle("Step aside in full screen", isOn: $p.hideInFullScreen)
                    .help("While a video or app is full screen, live activities stay hidden. Alerts still appear.")
            }
        }
    }
}

// MARK: Alerts

private struct AlertsPane: View {
    @Environment(Preferences.self) private var preferences
    @Environment(IslandEngine.self) private var engine
    @Environment(PowerMonitor.self) private var power

    var body: some View {
        @Bindable var p = preferences
        Form {
            Section {
                Toggle("Caps Lock", isOn: $p.capsLockAlerts)
                Toggle("Charging and Low Power Mode", isOn: $p.powerAlerts)
                Toggle("Low battery", isOn: $p.lowBatteryAlerts)
                Toggle("Bluetooth devices", isOn: $p.deviceAlerts)
            } footer: {
                Note("Volume and brightness are left to macOS, so nothing shows twice.")
            }
            Section {
                LabeledContent("See each alert") {
                    Button("Play a Tour", action: tour)
                }
            }
        }
    }

    private func tour() {
        let level = power.hasBattery ? power.level : 82
        let alerts: [IslandAlert] = [
            .finished(FinishedInfo(title: "isle is ready", detail: "Claude worked for 12 min", symbol: "checkmark",
                                   succeeded: true)),
            .power(level: level, isCharging: true),
            .device(DeviceInfo(name: "AirPods Pro", symbol: "airpodspro", battery: 86, isConnected: true)),
            .capsLock(isOn: true),
            .lowBattery(level: 10),
        ]
        Task {
            for alert in alerts {
                engine.present(alert)
                try? await Task.sleep(for: .milliseconds(2400))
                engine.dismissAlert()
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }
}

// MARK: General

private struct GeneralPane: View {
    @Environment(Preferences.self) private var preferences
    @Environment(Updater.self) private var updater
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var p = preferences
        @Bindable var u = updater
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show in menu bar", isOn: $p.showMenuBarIcon)
            }
            Section {
                LabeledContent("Isle \(Updater.currentVersion)") {
                    Button("Check Now", action: updater.checkForUpdates)
                        .disabled(!updater.canCheck)
                }
                Toggle("Check for updates automatically", isOn: $u.automaticallyChecks)
                Toggle("Download and install automatically", isOn: $u.automaticallyDownloads)
                    .disabled(!u.automaticallyChecks)
            } header: {
                Text("Updates")
            }
            Section {
                Link("Isle on GitHub", destination: URL(string: "https://github.com/abhijitrajbanshi/isle")!)
            } footer: {
                Note("Open source. Isle does nothing until something happens: no polling, nothing ticking at rest.")
            }
        }
    }
}

/// Section footer text, aligned to the leading edge like System Settings.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
