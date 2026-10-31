import Foundation
import Observation

/// User settings, observable and persisted to UserDefaults on change.
@MainActor
@Observable
final class Preferences {
    enum DisplayChoice: String, CaseIterable { case builtIn, main }

    var expandOnHover: Bool { didSet { save(expandOnHover, "expandOnHover") } }
    var hoverDelay: Double { didSet { save(hoverDelay, "hoverDelay") } }
    var haptics: Bool { didSet { save(haptics, "haptics") } }
    var swipeGestures: Bool { didSet { save(swipeGestures, "swipeGestures") } }
    var showMenuBarIcon: Bool { didSet { save(showMenuBarIcon, "showMenuBarIcon") } }
    var display: DisplayChoice { didSet { save(display.rawValue, "display") } }
    var style: IslandStyle { didSet { save(style.rawValue, "islandStyle") } }
    var showOnDisplaysWithoutNotch: Bool { didSet { save(showOnDisplaysWithoutNotch, "showOnDisplaysWithoutNotch") } }

    var nowPlaying: Bool { didSet { save(nowPlaying, "nowPlaying") } }
    var allPlayers: Bool { didSet { save(allPlayers, "allPlayers") } }
    var calendar: Bool { didSet { save(calendar, "calendar") } }
    var privacyIndicators: Bool { didSet { save(privacyIndicators, "privacyIndicators") } }

    var capsLockAlerts: Bool { didSet { save(capsLockAlerts, "capsLockAlerts") } }
    var powerAlerts: Bool { didSet { save(powerAlerts, "powerAlerts") } }
    var lowBatteryAlerts: Bool { didSet { save(lowBatteryAlerts, "lowBatteryAlerts") } }
    var deviceAlerts: Bool { didSet { save(deviceAlerts, "deviceAlerts") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool = true) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        expandOnHover = bool("expandOnHover")
        hoverDelay = defaults.object(forKey: "hoverDelay") as? Double ?? 0.14
        haptics = bool("haptics")
        swipeGestures = bool("swipeGestures")
        showMenuBarIcon = bool("showMenuBarIcon")
        display = DisplayChoice(rawValue: defaults.string(forKey: "display") ?? "") ?? .builtIn
        showOnDisplaysWithoutNotch = bool("showOnDisplaysWithoutNotch")
        style = IslandStyle(rawValue: defaults.string(forKey: "islandStyle") ?? "") ?? .glass
        nowPlaying = bool("nowPlaying")
        allPlayers = bool("allPlayers")
        calendar = bool("calendar")
        privacyIndicators = bool("privacyIndicators")
        capsLockAlerts = bool("capsLockAlerts")
        powerAlerts = bool("powerAlerts")
        lowBatteryAlerts = bool("lowBatteryAlerts")
        deviceAlerts = bool("deviceAlerts")
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}
