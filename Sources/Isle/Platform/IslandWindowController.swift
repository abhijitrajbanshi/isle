import AppKit
import IsleKit
import Observation
import SwiftUI

/// Hosts the island and translates system input into engine events.
///
/// Energy: Isle never watches the mouse globally. A sensor window over the
/// island reports the pointer arriving; a tracking area on the island
/// reports it leaving; the only global monitor is for clicks (to dismiss),
/// which are rare.
@MainActor
final class IslandWindowController {
    private let panel = NotchPanel()
    private let sensor: HoverSensorPanel
    private let root = IslandRootContainer()
    /// Keeps the island out of Space-switch animations (nil if unavailable).
    private let overlaySpace = OverlaySpace()
    private let container: IsleContainer
    private var engine: IslandEngine { container.engine }
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var swipe = SwipeInterpreter()
    private var verifyTask: Task<Void, Never>?

    /// Panel size: large enough for the expanded island plus its shadow.
    private static let canvas = CGSize(width: 840, height: 280)

    init(container: IsleContainer) {
        self.container = container
        sensor = HoverSensorPanel(level: NSWindow.Level(rawValue: panel.level.rawValue - 1))

        let host = IslandHostingView(rootView: IslandView().isleEnvironment(container))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)
        panel.contentView = root
        host.frame = root.bounds

        sensor.onEnter = { [weak self] in self?.pointerArrived() }
        sensor.onFileDrag = { [weak self] in self?.fileDragArrived() }
        root.onExit = { [weak self] in self?.pointerLeft() }

        place()
        observeSystem()
        installEventMonitors()
        trackHitArea()
    }

    // MARK: Placement

    func place() {
        guard let screen = ScreenLocator.screen(for: container.preferences) else {
            panel.orderOut(nil)
            sensor.orderOut(nil)
            return
        }
        let metrics = ScreenLocator.metrics(for: screen)
        if engine.metrics != metrics { engine.metrics = metrics }
        let frame = CGRect(x: (screen.frame.midX - Self.canvas.width / 2).rounded(),
                           y: screen.frame.maxY - Self.canvas.height,
                           width: Self.canvas.width, height: Self.canvas.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        orderFront()
        syncHitArea()
    }

    private func orderFront() {
        panel.orderFrontRegardless()
        sensor.orderFrontRegardless()
        overlaySpace?.add(panel)
        overlaySpace?.add(sensor)
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            },
            workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.orderFront() }
            },
        ]
        observeDisplayPreference()
    }

    private func observeDisplayPreference() {
        withObservationTracking {
            _ = container.preferences.display
            _ = container.preferences.showOnDisplaysWithoutNotch
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.place()
                self?.observeDisplayPreference()
            }
        }
    }

    // MARK: Hit area

    /// Keeps the sensor and the exit tracking area on the island's current
    /// hit area; re-arms on every shape change.
    private func trackHitArea() {
        withObservationTracking {
            _ = engine.hitRect
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncHitArea()
                self?.trackHitArea()
            }
        }
    }

    private func syncHitArea() {
        let rect = engine.hitRect
        if sensor.frame != rect { sensor.setFrame(rect, display: false) }
        root.trackingRect = rect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        // the shape may have moved under a pointer that hasn't: not intent
        setPointerInside(rect.contains(NSEvent.mouseLocation), byMotion: false)
    }

    /// The pointer moved onto the island.
    private func pointerArrived() {
        setPointerInside(true, byMotion: true)
        root.refreshTrackingArea()
        // A quick flick can leave before the panel starts taking mouse events,
        // in which case no exit event ever comes; confirm with the geometry.
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            if !self.engine.hitRect.contains(NSEvent.mouseLocation) { self.setPointerInside(false, byMotion: true) }
        }
    }

    private func setPointerInside(_ inside: Bool, byMotion: Bool) {
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        // a drag that left the island with no button held has ended (cancelled
        // or dropped elsewhere), even if its mouse-up never reached us
        if !inside, engine.isDraggingFile, NSEvent.pressedMouseButtons & 1 == 0 { engine.fileDragEnded() }
        engine.pointerMoved(inside: inside, byMotion: byMotion)
    }

    private func pointerLeft() {
        // tracking areas can report an exit at the edge; trust the geometry
        setPointerInside(engine.hitRect.contains(NSEvent.mouseLocation), byMotion: true)
    }

    private func fileDragArrived() {
        panel.ignoresMouseEvents = false
        engine.fileDragEnteredDropZone()
    }

    // MARK: Clicks and swipes

    private func installEventMonitors() {
        // clicks only: needed to dismiss on outside clicks and to end file drags
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleGlobalClick(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseUp], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .scrollWheel { self?.handleScroll(event) } else { self?.engine.fileDragEnded() }
            }
            return event
        }) { monitors.append(local) }
    }

    private func handleGlobalClick(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            engine.fileDragEnded()
        } else if !engine.hitRect.contains(NSEvent.mouseLocation) {
            engine.clickedOutside()
        }
    }

    /// Two-finger swipes: up collapses, down expands, left / right skip tracks.
    private func handleScroll(_ event: NSEvent) {
        // only scrolls on the island itself, not in Settings or other Isle windows
        guard event.window === panel, container.preferences.swipeGestures, event.hasPreciseScrollingDeltas else { return }
        if event.phase == .began { swipe.reset() }
        guard event.phase == .changed || event.phase == .began else { return }
        // finger motion, independent of the natural-scrolling setting
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        guard let gesture = swipe.feed(dx: event.scrollingDeltaX * sign, dy: event.scrollingDeltaY * sign) else { return }
        switch gesture {
        case .up: engine.collapse()
        case .down: engine.expand()
        case .left where engine.isExpanded && engine.tab == .home: container.nowPlaying.next()
        case .right where engine.isExpanded && engine.tab == .home: container.nowPlaying.previous()
        default: return
        }
        if container.preferences.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }
}
