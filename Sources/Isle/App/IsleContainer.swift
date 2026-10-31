import AppKit
import IsleKit
import Observation
import SwiftUI

/// Composition root: owns every model and service, wires alerts into the
/// engine and preferences into features. Nothing else constructs features.
@MainActor
final class IsleContainer {
    let preferences: Preferences
    let engine: IslandEngine

    let nowPlaying = NowPlayingModel()
    let timer = TimerModel()
    let calendar = CalendarModel()
    let power = PowerMonitor()
    let volume = VolumeMonitor()
    let brightness = BrightnessMonitor()
    let privacy = PrivacyMonitor()
    let shelf: ShelfModel

    private let capsLock = CapsLockMonitor()
    private let bluetooth = BluetoothMonitor()
    private lazy var nowPlayingService = NowPlayingService(model: nowPlaying, preferences: preferences)

    var openSettings: () -> Void = {}

    init(preferences: Preferences = Preferences(), metrics: NotchMetrics = .preview,
         defaults: UserDefaults = .standard) {
        self.preferences = preferences
        self.engine = IslandEngine(metrics: metrics)
        self.shelf = ShelfModel(defaults: defaults)
        wire()
    }

    private func wire() {
        engine.activities = { [unowned self] in
            var live: [LiveActivity] = []
            if timer.isActive { live.append(.timer) }
            if nowPlaying.isActive { live.append(.nowPlaying) }
            if calendar.current() != nil { live.append(.calendar) }
            if privacy.isActive { live.append(.privacy) }
            return live
        }
        engine.onExpand = { [unowned self] in
            if preferences.haptics {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }

        let post: (IslandAlert) -> Void = { [unowned self] in engine.present($0) }
        let p = preferences
        power.post = post
        power.powerAlerts = { p.powerAlerts }
        power.lowBatteryAlerts = { p.lowBatteryAlerts }
        volume.post = post
        volume.isEnabled = { p.volumeAlerts }
        brightness.post = post
        brightness.isEnabled = { p.brightnessAlerts }
        capsLock.post = post
        capsLock.isEnabled = { p.capsLockAlerts }
        bluetooth.post = post
        bluetooth.isEnabled = { p.deviceAlerts }
        calendar.post = post
        calendar.isEnabled = { p.calendar }
        privacy.isEnabled = { p.privacyIndicators }
        nowPlaying.isEnabled = { p.nowPlaying }
        timer.onFinish = { [unowned self] in engine.present(.timerDone) }

        syncEngineWithPreferences()
    }

    /// Keeps engine behaviour in step with Settings, re-arming on every change.
    private func syncEngineWithPreferences() {
        withObservationTracking {
            engine.expandsOnHover = preferences.expandOnHover
            engine.hoverDelay = .milliseconds(Int(preferences.hoverDelay * 1000))
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncEngineWithPreferences() }
        }
    }

    func start() {
        nowPlayingService.start()
        power.start()
        volume.start()
        brightness.start()
        capsLock.start()
        privacy.start()
        bluetooth.start()
        calendar.start()
    }

    func stop() {
        nowPlayingService.stop()
    }
}

extension View {
    /// Injects every model the island's views read.
    func isleEnvironment(_ c: IsleContainer) -> some View {
        environment(c.engine)
            .environment(c.preferences)
            .environment(c.nowPlaying)
            .environment(c.timer)
            .environment(c.calendar)
            .environment(c.power)
            .environment(c.volume)
            .environment(c.brightness)
            .environment(c.privacy)
            .environment(c.shelf)
            .environment(\.openIsleSettings, OpenSettingsAction { c.openSettings() })
    }
}

struct OpenSettingsAction {
    let action: @MainActor () -> Void
    @MainActor func callAsFunction() { action() }
}

extension EnvironmentValues {
    @Entry var openIsleSettings = OpenSettingsAction {}
}
