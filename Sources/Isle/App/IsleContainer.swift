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
    let privacy = PrivacyMonitor()
    let audio = AudioModel()
    let keepAwake = KeepAwakeModel()
    let hub = ActivityHub()
    let github = GitHubModel()
    let servers = ServersModel()
    private lazy var server = ActivityServer { [hub] line in await hub.handle(line) }
    /// The island opened itself for an agent's request (so it closes again once answered).
    private var openedForRequest = false
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
            if hub.hasAgent { live.append(.agent) }
            if hub.hasTask { live.append(.task) }
            if hub.isNearLimit { live.append(.usage) }
            if !github.live.isEmpty { live.append(.ci) }
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
        capsLock.post = post
        capsLock.isEnabled = { p.capsLockAlerts }
        bluetooth.post = post
        bluetooth.isEnabled = { p.deviceAlerts }
        calendar.post = post
        calendar.isEnabled = { p.calendar }
        privacy.isEnabled = { p.privacyIndicators }
        nowPlaying.isEnabled = { p.nowPlaying }
        timer.onFinish = { [unowned self] in engine.present(.timerDone) }
        hub.isEnabled = { p.agents }
        hub.onFinish = { [unowned self] in engine.present(.finished($0)) }
        hub.onLimit = { [unowned self] in engine.present(.limit($0)) }
        hub.onNotice = { [unowned self] in engine.present(.notice($0)) }
        hub.onPush = { [unowned self] folder, host in github.pushed(from: folder, host: host) }
        github.ciEnabled = { p.githubCI }
        github.reviewsEnabled = { p.githubReviews }
        github.isInFront = { [unowned self] host in host != nil && host == hub.frontmost }
        github.onFinish = { [unowned self] in engine.present(.finished($0)) }
        github.onPullRequest = { [unowned self] item in
            let event: PullRequestInfo.Event? = switch item.kind {
            case .reviewRequested: .reviewRequested
            case .approved: .approved
            case .changesRequested: .changesRequested
            case .activity: nil
            }
            if let event {
                engine.present(.pullRequest(PullRequestInfo(title: item.title, repo: item.repo, number: item.number, event: event)))
            }
        }
        // the open shelf already shows the result; the banner is for when you've moved on
        shelf.onFinish = { [unowned self] in if !engine.isExpanded { engine.present(.finished($0)) } }
        hub.onRequest = { [unowned self] in
            guard preferences.openForRequests, !engine.isExpanded else { return }
            engine.tab = .home
            engine.expand()
            openedForRequest = true
        }
        closeAfterRequests()

        syncEngineWithPreferences()
    }

    /// Closes the island it opened for a request once nothing is waiting,
    /// unless you've since moved onto it.
    private func closeAfterRequests() {
        withObservationTracking {
            _ = hub.needsYou
        } onChange: { [weak self] in
            Task { @MainActor in self?.requestsChanged() }
        }
    }

    private func requestsChanged() {
        if openedForRequest, hub.needsYou == nil {
            openedForRequest = false
            if !engine.isHovering { engine.collapse() }
        }
        closeAfterRequests()
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
        capsLock.start()
        privacy.start()
        audio.start()
        hub.start()
        server.start()
        ClaudeConnector.upgradeIfNeeded()
        github.start()
        bluetooth.start()
        calendar.start()
    }

    func stop() {
        nowPlayingService.stop()
        keepAwake.stop()
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
            .environment(c.privacy)
            .environment(c.audio)
            .environment(c.keepAwake)
            .environment(c.hub)
            .environment(c.github)
            .environment(c.servers)
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
