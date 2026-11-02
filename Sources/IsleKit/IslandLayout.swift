import CoreGraphics

/// The natural width of a live activity's content either side of the notch.
public struct CompactContentWidth: Equatable, Sendable {
    public var leading: CGFloat
    public var trailing: CGFloat
    public init(leading: CGFloat, trailing: CGFloat) {
        self.leading = leading
        self.trailing = trailing
    }
}

/// Sizes for every presentation, derived from the notch so the island looks
/// right on any MacBook (and on displays without a notch).
public struct IslandLayout: Equatable, Sendable {
    public var metrics: NotchMetrics
    /// The open island is as tall as its content (measured by the view),
    /// notch row included.
    public var expandedHeight: CGFloat
    /// Measured content width either side of the notch, per activity.
    public var compactContent: [LiveActivity: CompactContentWidth]

    public init(metrics: NotchMetrics, expandedHeight: CGFloat = 200,
                compactContent: [LiveActivity: CompactContentWidth] = [:]) {
        self.metrics = metrics
        self.expandedHeight = expandedHeight
        self.compactContent = compactContent
    }

    /// Content sits this far from the notch on both sides, hugging it.
    public static let notchGap: CGFloat = 7
    /// And this far from the island's outer edge (its corner).
    public static let outerInset: CGFloat = 11

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
            let sides = sides(for: primary)
            return IslandShape(width: notchWidth + sides.leading + sides.trailing, height: notchHeight,
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
    /// Width on each side of the notch. The left holds an icon, so it's
    /// narrow (apps' menus sit there); the right holds the one word of state.
    public func sides(for activity: LiveActivity) -> (leading: CGFloat, trailing: CGFloat) {
        switch activity {
        // artwork and level meter, and the privacy dot, balance either side
        case .nowPlaying, .privacy:
            return (sideWidth(for: activity), sideWidth(for: activity))
        default:
            // once measured, each side is exactly its content, the gap to the
            // notch and the inset to the corner: short words make a short island
            guard let content = compactContent[activity] else { return (iconSide, sideWidth(for: activity)) }
            let padding = Self.notchGap + Self.outerInset
            let leading = min(max(content.leading + padding, iconSide), sideWidth(for: activity))
            let trailing = min(max(content.trailing + padding, iconSide), sideWidth(for: activity) + 12)
            return (leading.rounded(.up), trailing.rounded(.up))
        }
    }

    /// Room for one icon beside the notch.
    public var iconSide: CGFloat { notchHeight - 2 }

    /// How far the island sits right of centre so the notch stays over the
    /// hardware notch when its sides differ.
    public func offset(for presentation: Presentation) -> CGFloat {
        guard case .compact(let primary, _) = presentation else { return 0 }
        let sides = sides(for: primary)
        return (sides.trailing - sides.leading) / 2
    }

    public func sideWidth(for activity: LiveActivity) -> CGFloat {
        switch activity {
        case .nowPlaying: notchHeight + 10
        // as narrow as each one's content allows: menu bar items sit right beside the island
        case .timer: 62
        case .calendar: 66
        case .privacy: notchHeight + 2
        case .task: 52
        case .agent: 64
        case .usage: 50
        case .ci: 58
        }
    }

    /// Visible frame in global screen coordinates (y up), bubble included.
    public func frame(for presentation: Presentation, isHovering: Bool) -> CGRect {
        let shape = shape(for: presentation, isHovering: isHovering)
        var width = shape.outerWidth
        if case .compact(_, .some) = presentation { width += Self.bubbleGap + bubbleDiameter }
        let screen = metrics.screenFrame
        return CGRect(x: screen.midX - shape.outerWidth / 2 + offset(for: presentation), y: screen.maxY - shape.height,
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
