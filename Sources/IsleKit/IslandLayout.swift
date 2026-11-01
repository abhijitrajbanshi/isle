import CoreGraphics

/// Sizes for every presentation, derived from the notch so the island looks
/// right on any MacBook (and on displays without a notch).
public struct IslandLayout: Equatable, Sendable {
    public var metrics: NotchMetrics
    /// The open island is as tall as its content (measured by the view),
    /// notch row included.
    public var expandedHeight: CGFloat

    public init(metrics: NotchMetrics, expandedHeight: CGFloat = 200) {
        self.metrics = metrics
        self.expandedHeight = expandedHeight
    }

    /// The open island never grows past this; anything taller scrolls out of
    /// the bottom rather than pushing the top under the notch.
    public static let maxExpandedHeight: CGFloat = 440

    /// Width of the open island.
    public var expandedWidth: CGFloat { max(notchWidth + 375, 560) }

    public static let bubbleGap: CGFloat = 6

    private var notchWidth: CGFloat { metrics.size.width }
    private var notchHeight: CGFloat { metrics.size.height }

    public var bubbleDiameter: CGFloat { notchHeight }

    /// Corner radius that keeps a notch-height row reading as a soft pill.
    private var compactRadius: CGFloat { (notchHeight * 0.4).rounded() }

    public func shape(for presentation: Presentation, isHovering: Bool) -> IslandShape {
        switch presentation {
        case .idle:
            // Rests exactly inside the hardware notch (and is hidden there);
            // swells a touch under the pointer to show it's interactive.
            if isHovering {
                return IslandShape(width: notchWidth + 12, height: notchHeight + 5, shoulder: 6, radius: compactRadius)
            }
            return IslandShape(width: notchWidth - 8, height: notchHeight, shoulder: 4, radius: 9)

        case .compact(let primary, _):
            return IslandShape(width: notchWidth + sideWidth(for: primary) * 2, height: notchHeight,
                               shoulder: 6, radius: compactRadius)

        case .alert(let alert):
            switch alert.style {
            case .hud:
                return IslandShape(width: notchWidth + 2 * 78, height: notchHeight, shoulder: 6, radius: compactRadius)
            case .wide:
                return IslandShape(width: notchWidth + 2 * 108, height: notchHeight, shoulder: 6, radius: compactRadius)
            case .banner:
                return IslandShape(width: max(notchWidth + 196, 390), height: notchHeight + 62, shoulder: 10, radius: 26)
            }

        case .expanded:
            return IslandShape(width: expandedWidth,
                               height: min(max(expandedHeight, notchHeight + 60), Self.maxExpandedHeight),
                               shoulder: 12, radius: 30)
        }
    }

    /// Width of the content column on each side of the notch.
    public func sideWidth(for activity: LiveActivity) -> CGFloat {
        switch activity {
        case .nowPlaying: notchHeight + 10
        case .timer: 70
        case .calendar: 72
        case .privacy: notchHeight + 2
        case .task: 64
        case .agent: 84
        case .usage: 92
        case .ci: 72
        }
    }

    /// Visible frame in global screen coordinates (y up), bubble included.
    public func frame(for presentation: Presentation, isHovering: Bool) -> CGRect {
        let shape = shape(for: presentation, isHovering: isHovering)
        var width = shape.outerWidth
        if case .compact(_, .some) = presentation { width += Self.bubbleGap + bubbleDiameter }
        let screen = metrics.screenFrame
        return CGRect(x: screen.midX - shape.outerWidth / 2, y: screen.maxY - shape.height,
                      width: width, height: shape.height)
    }

    /// Where the pointer counts as "on the island". Slightly larger than the
    /// visible frame so small movements at the edges don't flicker.
    public func hitRect(for presentation: Presentation, isHovering: Bool, isDraggingFile: Bool = false) -> CGRect {
        let frame = frame(for: presentation, isHovering: isHovering)
        switch presentation {
        // exactly the notch: menu bar items sit right beside it
        case .idle: return frame.insetBy(dx: 0, dy: -3)
        case .expanded: return frame.insetBy(dx: isDraggingFile ? -40 : -4, dy: isDraggingFile ? -40 : -4)
        default: return frame.insetBy(dx: -2, dy: -2)
        }
    }
}
