import AppKit
import IsleKit
import SwiftUI

/// Motion language: critically damped springs, so the island settles
/// without bouncing; retargeting keeps velocity, so hovering in and out
/// mid-animation never jumps. Small state flips are quick; everything
/// degrades to plain fades under Reduce Motion.
enum Motion {
    static let expand = Animation.spring(duration: 0.44, bounce: 0)
    static let collapse = Animation.spring(duration: 0.32, bounce: 0)
    static let morph = Animation.spring(duration: 0.3, bounce: 0)
    static let snappy = Animation.spring(duration: 0.22, bounce: 0)
    static let press = Animation.spring(duration: 0.18, bounce: 0)
    /// The one playful moment: a file landing on the shelf.
    static let land = Animation.spring(duration: 0.4, bounce: 0.15)
    static let reduced = Animation.easeInOut(duration: 0.2)

    static func island(expanding: Bool, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : (expanding ? expand : collapse)
    }
}

/// Island palette. The body is pure black so it is continuous with the
/// hardware notch; content follows iOS system colours tuned for dark.
enum Palette {
    static let green = Color(red: 0.37, green: 0.83, blue: 0.55)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let red = Color(red: 1.0, green: 0.41, blue: 0.38)
    /// Waiting on you: an agent's permission request.
    static let amber = Color(red: 0.96, green: 0.65, blue: 0.14)
    static let yellow = Color(red: 1.0, green: 0.84, blue: 0.04)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)

    static let label = Color.white.opacity(0.96)
    static let secondaryLabel = Color.white.opacity(0.62)
    static let tertiaryLabel = Color.white.opacity(0.36)
    static let fill = Color.white.opacity(0.14)
    static let secondaryFill = Color.white.opacity(0.09)
    static let hairline = Color.white.opacity(0.09)

    static func battery(_ level: Int) -> Color {
        level <= 10 ? red : (level <= 20 ? yellow : green)
    }
}

/// The content colour of what the island is showing (the album art, a
/// meeting's calendar, the timer). The island itself is always opaque
/// black; only content takes colour, and only one thing at a time.
struct Ambience: Equatable {
    /// The single tinted element: level meter, progress, a state.
    var accent: Color
    /// Labels and glyphs (white; hierarchy comes from opacity).
    var tint: Color = .white
    /// The body colour: hardware black.
    var deep: Color = .black
    /// Wells and secondary buttons.
    var surface: Color = Palette.fill

    static let signature = Ambience(accent: .white)

    init(accent: Color) { self.accent = accent }

    init(_ base: IslandColor) {
        let ns = NSColor(srgbRed: base.red, green: base.green, blue: base.blue, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        // greys stay white instead of turning red
        accent = s < 0.12 ? .white : Color(hue: h, saturation: min(max(s, 0.45), 0.8), brightness: 0.98)
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(IslandColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent))
    }
}

extension EnvironmentValues {
    @Entry var ambience = Ambience.signature
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
