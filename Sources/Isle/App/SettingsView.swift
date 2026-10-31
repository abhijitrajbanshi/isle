import IsleKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(IslandEngine.self) private var engine
    @Environment(CalendarModel.self) private var calendar
    @Environment(PowerMonitor.self) private var power
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var p = preferences
        Form {
            Section {
                Header()
            }

            Section("Behaviour") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Expand on hover", isOn: $p.expandOnHover)
                if p.expandOnHover {
                    LabeledContent("Hover delay") {
                        HStack(spacing: 10) {
                            Slider(value: $p.hoverDelay, in: 0.05...0.6)
                                .frame(width: 150)
                            Text("\(Int(p.hoverDelay * 1000)) ms")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                Toggle("Swipe gestures", isOn: $p.swipeGestures)
                    .help("On the island: swipe up to close, down to open, left or right to skip tracks.")
                Toggle("Haptic feedback", isOn: $p.haptics)
                Toggle("Show in menu bar", isOn: $p.showMenuBarIcon)
            }

            Section {
                Picker("Material", selection: $p.style) {
                    ForEach(IslandStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Black blends with the notch. Liquid Glass shows the desktop through the island.")
            }

            Section("Display") {
                Picker("Show on", selection: $p.display) {
                    Text("Built-in display").tag(Preferences.DisplayChoice.builtIn)
                    Text("Main display").tag(Preferences.DisplayChoice.main)
                }
                Toggle("Use on displays without a notch", isOn: $p.showOnDisplaysWithoutNotch)
            }

            Section {
                Toggle("Now Playing", isOn: $p.nowPlaying)
                Toggle("Include browsers and all other apps", isOn: $p.allPlayers)
                    .disabled(!p.nowPlaying)
                Toggle("Upcoming events", isOn: $p.calendar)
                    .onChange(of: p.calendar) { _, on in if on, !calendar.hasAccess { calendar.requestAccess() } }
                Toggle("Camera and microphone in use", isOn: $p.privacyIndicators)
            } header: {
                Text("Live Activities")
            } footer: {
                Text("Without “all other apps”, Now Playing follows Music and Spotify only.")
            }

            Section("Alerts") {
                Toggle("Caps Lock", isOn: $p.capsLockAlerts)
                Toggle("Charging and Low Power Mode", isOn: $p.powerAlerts)
                Toggle("Low battery", isOn: $p.lowBatteryAlerts)
                Toggle("Bluetooth devices", isOn: $p.deviceAlerts)
                LabeledContent("Preview") {
                    Button("Play a Tour", action: tour)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 470)
        .frame(minHeight: 560, idealHeight: 680)
    }

    /// Shows each alert style in turn.
    private func tour() {
        let level = power.hasBattery ? power.level : 82
        let alerts: [IslandAlert] = [
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

private struct Header: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Isle").font(.title2.weight(.semibold))
                Text("The Dynamic Island, for your Mac.").foregroundStyle(.secondary)
            }
            Spacer()
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
