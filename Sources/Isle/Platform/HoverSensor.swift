import AppKit

/// An invisible window over the island's hit area that reports the pointer
/// arriving, and files being dragged onto the notch.
///
/// This replaces a global mouse-moved monitor: the window server only wakes
/// Isle when the pointer actually crosses the island, not on every mouse move
/// anywhere on screen.
final class HoverSensorPanel: NSPanel {
    var onEnter: () -> Void = {}
    var onFileDrag: () -> Void = {}

    init(level: NSWindow.Level) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        // explicitly false: receive events even though every pixel is clear
        ignoresMouseEvents = false

        let sensor = SensorView()
        sensor.onEnter = { [weak self] in self?.onEnter() }
        sensor.onFileDrag = { [weak self] in self?.onFileDrag() }
        contentView = sensor
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SensorView: NSView {
    var onEnter: () -> Void = {}
    var onFileDrag: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onFileDrag()
        return .copy
    }
}

/// Root view of the island panel. While the panel accepts the mouse it
/// watches for the pointer leaving the island's hit area.
final class IslandRootContainer: NSView {
    var onExit: () -> Void = {}
    /// Pointer speed over the island, in points per second.
    var onMove: (Double) -> Void = { _ in }
    private var lastMoveTime: TimeInterval?

    /// Hit area in this view's coordinates.
    var trackingRect: CGRect = .zero {
        didSet { if trackingRect != oldValue { rebuildTrackingArea() } }
    }

    private var area: NSTrackingArea?

    /// Re-reads the pointer's position so the next event is the right one.
    func refreshTrackingArea() { rebuildTrackingArea() }

    private func rebuildTrackingArea() {
        if let area { removeTrackingArea(area) }
        // moves are reported only inside the island, so this costs nothing elsewhere
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways]
        // if the pointer is already inside, the next event must be the exit
        if let window, trackingRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            options.insert(.assumeInside)
        }
        let area = NSTrackingArea(rect: trackingRect, options: options, owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseExited(with event: NSEvent) {
        lastMoveTime = nil
        onExit()
    }

    override func mouseMoved(with event: NSEvent) {
        // raw deltas, not positions: pushing against the top of the screen
        // still counts as moving, and the first event inside has a speed too
        let elapsed = lastMoveTime.map { event.timestamp - $0 } ?? 1.0 / 60
        lastMoveTime = event.timestamp
        guard elapsed > 0.001 else { return }
        onMove(hypot(event.deltaX, event.deltaY) / min(elapsed, 0.1))
    }
}
