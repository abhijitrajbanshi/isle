import CoreGraphics
import Foundation

/// The hardware notch (or the virtual one on displays without it).
public struct NotchMetrics: Equatable, Sendable {
    /// Notch size in points.
    public var size: CGSize
    public var hasNotch: Bool
    /// The screen the island lives on, in global screen coordinates.
    public var screenFrame: CGRect

    public init(size: CGSize, hasNotch: Bool, screenFrame: CGRect) {
        self.size = size
        self.hasNotch = hasNotch
        self.screenFrame = screenFrame
    }

    /// 13" / 15" MacBook Air–like geometry, for previews and tests.
    public static let preview = NotchMetrics(
        size: CGSize(width: 185, height: 32), hasNotch: true,
        screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956))
}

/// Long-running activities. Raw value is priority: the highest takes the notch,
/// the runner-up gets the detached bubble.
public enum LiveActivity: Int, Comparable, Hashable, Sendable, CaseIterable {
    case privacy
    /// Claude usage near a limit.
    case usage
    case calendar
    /// Anything posted through the activity API: builds, downloads, scripts.
    case task
    case nowPlaying
    case timer
    /// AI coding agents (Claude Code): working, waiting on you, done.
    case agent

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum ExpandedTab: String, CaseIterable, Hashable, Sendable {
    case home, timer, shelf
}

/// sRGB colour that can cross concurrency domains.
public struct IslandColor: Equatable, Hashable, Sendable {
    public var red, green, blue: Double
    public init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }
}

public struct DeviceInfo: Equatable, Sendable {
    public var name: String
    public var symbol: String
    public var battery: Int?
    public var isConnected: Bool
    public init(name: String, symbol: String, battery: Int?, isConnected: Bool) {
        self.name = name; self.symbol = symbol; self.battery = battery; self.isConnected = isConnected
    }
}

public struct EventInfo: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var color: IslandColor
    public var meeting: MeetingLink?
    public init(title: String, start: Date, color: IslandColor, meeting: MeetingLink? = nil) {
        self.title = title; self.start = start; self.color = color; self.meeting = meeting
    }
}

public struct FinishedInfo: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var symbol: String
    public var succeeded: Bool
    public init(title: String, detail: String, symbol: String, succeeded: Bool) {
        self.title = title; self.detail = detail; self.symbol = symbol; self.succeeded = succeeded
    }
}

/// A Claude usage window filling up.
public struct LimitInfo: Equatable, Sendable {
    public var percent: Int
    /// "5-hour" or "weekly".
    public var window: String
    public var resetsAt: Date
    public init(percent: Int, window: String, resetsAt: Date) {
        self.percent = percent; self.window = window; self.resetsAt = resetsAt
    }
}

/// Short-lived system alerts.
public enum IslandAlert: Equatable, Sendable {
    case capsLock(isOn: Bool)
    case power(level: Int, isCharging: Bool)
    case lowPowerMode(isOn: Bool, level: Int)
    case lowBattery(level: Int)
    case device(DeviceInfo)
    case timerDone
    case eventSoon(EventInfo)
    /// An agent or task finished (or failed).
    case finished(FinishedInfo)
    /// Claude usage crossed 80% or 95% of a window.
    case limit(LimitInfo)

    public enum Kind: Hashable, Sendable {
        case capsLock, power, lowBattery, device, timer, event, finished, limit
    }

    public enum Style: Sendable {
        /// Icon + level on either side of the notch.
        case hud
        /// Label + value on either side of the notch, wider than a HUD.
        case wide
        /// Drops below the notch with a title, subtitle and accessory.
        case banner
    }

    public var kind: Kind {
        switch self {
        case .capsLock: .capsLock
        case .power, .lowPowerMode: .power
        case .lowBattery: .lowBattery
        case .device: .device
        case .timerDone: .timer
        case .eventSoon: .event
        case .finished: .finished
        case .limit: .limit
        }
    }

    public var style: Style {
        switch self {
        case .capsLock: .hud
        case .power, .lowPowerMode: .wide
        case .lowBattery, .device, .timerDone, .eventSoon, .finished, .limit: .banner
        }
    }

    /// How long the alert stays up when the pointer isn't on it.
    public var duration: Duration {
        switch self {
        case .capsLock: .milliseconds(1500)
        case .power, .lowPowerMode: .milliseconds(2600)
        case .timerDone: .seconds(12)
        case .lowBattery, .device, .eventSoon: .seconds(4)
        case .finished, .limit: .seconds(5)
        }
    }
}

/// What the island shows.
public enum Presentation: Equatable, Sendable {
    case idle
    case compact(primary: LiveActivity, secondary: LiveActivity?)
    case alert(IslandAlert)
    case expanded

    /// Stable while the *kind* of content is unchanged, so views can key
    /// transitions on it without replaying them on every update.
    public var contentKey: String {
        switch self {
        case .idle: "idle"
        case .compact(let primary, _): "compact.\(primary)"
        case .alert(let alert): "alert.\(alert.kind)"
        case .expanded: "expanded"
        }
    }

    public var isIdle: Bool { self == .idle }
}

/// Geometry of the black body. `width` excludes the concave shoulders.
public struct IslandShape: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public var shoulder: CGFloat
    public var radius: CGFloat

    public init(width: CGFloat, height: CGFloat, shoulder: CGFloat, radius: CGFloat) {
        self.width = width; self.height = height; self.shoulder = shoulder; self.radius = radius
    }

    public var outerWidth: CGFloat { width + shoulder * 2 }
}
