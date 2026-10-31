import IsleKit
import SwiftUI

/// Motion language. Springs are tuned against the iPhone island: expansion
/// overshoots a hair, collapse settles without bounce, small state flips are
/// quick. Everything degrades to plain fades under Reduce Motion.
enum Motion {
    static let expand = Animation.spring(duration: 0.5, bounce: 0.24)
    static let collapse = Animation.spring(duration: 0.42, bounce: 0.08)
    static let morph = Animation.spring(duration: 0.46, bounce: 0.18)
    static let snappy = Animation.spring(duration: 0.26, bounce: 0.1)
    static let press = Animation.spring(duration: 0.2, bounce: 0.2)
    static let reduced = Animation.easeInOut(duration: 0.2)

    static func island(expanding: Bool, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : (expanding ? expand : collapse)
    }
}

/// Island palette. The body is pure black so it is continuous with the
/// hardware notch; content follows iOS system colours tuned for dark.
enum Palette {
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let yellow = Color(red: 1.0, green: 0.84, blue: 0.04)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)

    static let label = Color.white
    static let secondaryLabel = Color.white.opacity(0.6)
    static let tertiaryLabel = Color.white.opacity(0.34)
    static let fill = Color.white.opacity(0.13)
    static let secondaryFill = Color.white.opacity(0.075)
    static let hairline = Color.white.opacity(0.09)

    static func battery(_ level: Int) -> Color {
        level <= 10 ? red : (level <= 20 ? yellow : green)
    }
}

extension IslandColor {
    var color: Color { Color(red: red, green: green, blue: blue) }

    init(_ ns: NSColor?) {
        let c = (ns ?? .systemBlue).usingColorSpace(.sRGB) ?? .systemBlue
        self.init(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }
}

/// SF Pro at the island's sizes. Numbers are rounded + monospaced so
/// countdowns and percentages never jitter.
extension Font {
    static func island(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func islandNumber(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

enum Clock {
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
