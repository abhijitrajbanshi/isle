import CoreGraphics
import Observation

/// The island's state machine.
///
/// Precedence, highest first: expanded › alert › live activities › idle.
/// Pointer, click and drag input come in from the platform layer; the engine
/// decides what to show and for how long. All timing runs on Swift
/// concurrency tasks so tests can drive it with an injected sleep.
@MainActor
@Observable
public final class IslandEngine {
    public struct Timing: Sendable {
        public var collapseDelay: Duration = .milliseconds(160)
        /// How long an alert lingers after the pointer leaves it.
        public var alertLinger: Duration = .milliseconds(900)
        /// Gap between queued banners, so each reads as its own event.
        public var queueGap: Duration = .milliseconds(220)
        /// Longest an alert can be held open by hovering it.
        public var maxAlertHold: Duration = .seconds(8)
        public init() {}
    }

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    // MARK: State

    public var metrics: NotchMetrics
    public private(set) var isExpanded = false
    public private(set) var isHovering = false
    public private(set) var alert: IslandAlert?
    public private(set) var isDraggingFile = false
    public var tab: ExpandedTab = .home
    public var isDropTargeted = false

    // MARK: Configuration

    public var expandsOnHover = true
    public var hoverDelay: Duration = .milliseconds(140)
    @ObservationIgnored public var timing = Timing()
    /// Live activities, highest priority first is not required; the engine sorts.
    @ObservationIgnored public var activities: () -> [LiveActivity] = { [] }
    @ObservationIgnored public var onExpand: () -> Void = {}

    @ObservationIgnored private var queue: [IslandAlert] = []
    /// Whether the current hover began with the pointer moving onto the
    /// island (intent), rather than the island growing under a resting pointer.
    @ObservationIgnored private var hoverIsIntentional = false
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var alertTask: Task<Void, Never>?
    /// Separate from `alertTask` so hovering can't cancel a queued banner.
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private let sleep: Sleep

    public init(metrics: NotchMetrics = .preview, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.metrics = metrics
        self.sleep = sleep
    }

    // MARK: Derived

    public var layout: IslandLayout { IslandLayout(metrics: metrics) }

    public var presentation: Presentation {
        if isExpanded { return .expanded }
        if let alert { return .alert(alert) }
        let live = activities().sorted(by: >)
        guard let primary = live.first else { return .idle }
        return .compact(primary: primary, secondary: live.dropFirst().first)
    }

    public var shape: IslandShape { layout.shape(for: presentation, isHovering: isHovering) }

    public var hitRect: CGRect {
        layout.hitRect(for: presentation, isHovering: isHovering, isDraggingFile: isDraggingFile)
    }

    // MARK: Alerts

    /// Shows an alert. Banners are never lost: they queue behind other
    /// banners, step aside for HUDs, and wait while the island is expanded.
    /// HUDs and wide alerts are momentary and simply replace each other.
    public func present(_ new: IslandAlert) {
        if isExpanded {
            if new == .timerDone {
                collapse()
            } else {
                // the expanded island shows media and battery itself; banners wait
                if new.style == .banner { enqueue(new) }
                return
            }
        }
        if let current = alert {
            if current.kind == new.kind {
                alert = new                       // update in place, e.g. Caps Lock on → off
                scheduleDismissal(after: new.duration)
                return
            }
            if current.style == .banner {
                if new.style == .banner {
                    enqueue(new)                  // banners take turns
                    return
                }
                enqueue(current, first: true)     // resume it after the HUD
            }
        }
        alert = new
        scheduleDismissal(after: new.duration)
    }

    public func dismissAlert() {
        alertTask?.cancel()
        alert = nil
        showNextQueued()
    }

    private func enqueue(_ alert: IslandAlert, first: Bool = false) {
        queue.removeAll { $0.kind == alert.kind }
        if first { queue.insert(alert, at: 0) } else { queue.append(alert) }
    }

    private func showNextQueued() {
        guard !queue.isEmpty, !isExpanded else { return }
        queueTask?.cancel()
        queueTask = Task { [weak self, sleep, gap = timing.queueGap] in
            try? await sleep(gap)
            guard !Task.isCancelled, let self, !self.isExpanded, self.alert == nil, !self.queue.isEmpty else { return }
            self.present(self.queue.removeFirst())
        }
    }

    private func scheduleDismissal(after duration: Duration) {
        alertTask?.cancel()
        alertTask = Task { [weak self, sleep] in
            try? await sleep(duration)
            guard !Task.isCancelled, let self else { return }
            // don't pull an alert out from under a pointer that went to it
            if self.isHovering, self.hoverIsIntentional {
                self.holdAlert()
                return
            }
            self.dismissAlert()
        }
    }

    /// Keeps the alert up while it's being used, but never indefinitely.
    private func holdAlert() {
        alertTask?.cancel()
        alertTask = Task { [weak self, sleep, cap = timing.maxAlertHold] in
            try? await sleep(cap)
            guard !Task.isCancelled else { return }
            self?.dismissAlert()
        }
    }

    // MARK: Expansion

    public func expand(tab newTab: ExpandedTab? = nil) {
        hoverTask?.cancel()
        collapseTask?.cancel()
        if let newTab { tab = newTab }
        guard !isExpanded else { return }
        alertTask?.cancel()
        queueTask?.cancel()
        alert = nil   // seen; queued banners wait until the island collapses
        isExpanded = true
        onExpand()
    }

    public func collapse() {
        hoverTask?.cancel()
        collapseTask?.cancel()
        isDropTargeted = false
        guard isExpanded else { return }
        isExpanded = false
        showNextQueued()
    }

    /// Click on the island.
    public func activate() {
        if isExpanded { return }
        if case .alert(.timerDone) = presentation { dismissAlert(); return }
        expand()
    }

    /// Click anywhere outside the island.
    public func clickedOutside() {
        if isExpanded, !isDraggingFile { collapse() }
    }

    // MARK: Pointer

    /// - Parameter byMotion: true when the pointer moved onto the island;
    ///   false when the island changed shape under a resting pointer. Only
    ///   motion counts as intent to interact.
    public func pointerMoved(inside: Bool, byMotion: Bool = true) {
        if inside == isHovering {
            // a resting pointer that now moves within the island becomes intentional
            if inside, byMotion, !hoverIsIntentional {
                hoverIsIntentional = true
                pointerEntered()
            }
            return
        }
        isHovering = inside
        hoverIsIntentional = inside && byMotion
        if !inside {
            pointerExited()
        } else if byMotion {
            pointerEntered()
        } else {
            collapseTask?.cancel()
        }
    }

    private func pointerEntered() {
        collapseTask?.cancel()
        if alert != nil {
            // keep the alert (and its controls) steady under the pointer, within limits
            holdAlert()
            return
        }
        guard !isExpanded, expandsOnHover else { return }
        hoverTask?.cancel()
        hoverTask = Task { [weak self, sleep, hoverDelay] in
            try? await sleep(hoverDelay)
            guard !Task.isCancelled, let self, self.isHovering else { return }
            self.expand()
        }
    }

    private func pointerExited() {
        hoverTask?.cancel()
        if alert != nil { scheduleDismissal(after: timing.alertLinger) }
        guard isExpanded, !isDraggingFile else { return }
        collapseTask?.cancel()
        collapseTask = Task { [weak self, sleep, delay = timing.collapseDelay] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self, !self.isHovering else { return }
            self.collapse()
        }
    }

    // MARK: File drags

    public func fileDragEnteredDropZone() {
        guard !isDraggingFile else { return }
        isDraggingFile = true
        expand(tab: .shelf)
    }

    public func fileDragEnded() {
        guard isDraggingFile else { return }
        isDraggingFile = false
        isDropTargeted = false
        if !isHovering { pointerExited() }
    }
}
