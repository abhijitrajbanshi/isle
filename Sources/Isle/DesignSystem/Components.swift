import AppKit
import SwiftUI

// MARK: - Transitions

/// Blur + scale + fade: how iOS swaps content inside the island.
private struct BlurFade: ViewModifier {
    let isActive: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: isActive ? 6 : 0)
            .opacity(isActive ? 0 : 1)
            .scaleEffect(isActive ? 0.9 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(isActive: true), identity: BlurFade(isActive: false))
                .animation(.spring(duration: 0.4, bounce: 0.1).delay(0.06)),
            removal: .modifier(active: BlurFade(isActive: true), identity: BlurFade(isActive: false))
                .animation(.easeOut(duration: 0.1)))
    }
}

// MARK: - Artwork

struct ArtworkView: View {
    let image: NSImage?
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                Group {
                    LinearGradient(colors: [Color(white: 0.24), Color(white: 0.13)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(Palette.secondaryLabel)
                }
                .transition(.opacity)
            }
        }
        // crossfade between tracks instead of an abrupt swap
        .animation(.easeInOut(duration: 0.25), value: image.map(ObjectIdentifier.init))
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Waveform

/// The music activity's live level meter.
///
/// Built from Core Animation layers with looping keyframe animations, so the
/// motion runs in the window server: Isle does no per-frame work at all while
/// music plays. Holds still under Reduce Motion and Low Power Mode.
struct Waveform: View {
    var color: Color
    var isPlaying: Bool
    var bars = 4
    var height: CGFloat = 14
    var barWidth: CGFloat = 2.5
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.prefersStillness) private var prefersStillness

    var body: some View {
        let spacing = barWidth * 0.8
        let width = CGFloat(bars) * barWidth + CGFloat(bars - 1) * spacing
        Group {
            if isSnapshot || prefersStillness {
                // a still level meter: static heights while playing, flat when paused
                HStack(spacing: spacing) {
                    ForEach(0..<bars, id: \.self) { i in
                        Capsule().fill(color)
                            .frame(width: barWidth, height: isPlaying ? height * WaveformLayers.restingLevel(i, of: bars) : barWidth)
                    }
                }
            } else {
                WaveformLayers(color: NSColor(color), isAnimating: isPlaying, bars: bars,
                               barWidth: barWidth, spacing: spacing)
            }
        }
        .frame(width: width, height: height)
        .animation(Motion.snappy, value: isPlaying)
        .accessibilityHidden(true)
    }
}

private struct WaveformLayers: NSViewRepresentable {
    let color: NSColor
    let isAnimating: Bool
    let bars: Int
    let barWidth: CGFloat
    let spacing: CGFloat

    /// Per-bar keyframes (fraction of full height); first equals last so loops are seamless.
    private static let patterns: [[CGFloat]] = [
        [0.35, 0.9, 0.5, 1.0, 0.4, 0.75, 0.35],
        [0.6, 0.3, 1.0, 0.55, 0.85, 0.3, 0.6],
        [0.45, 1.0, 0.35, 0.8, 0.5, 0.95, 0.45],
        [0.8, 0.4, 0.7, 0.3, 1.0, 0.5, 0.8],
        [0.3, 0.7, 0.95, 0.4, 0.6, 0.85, 0.3],
    ]
    private static let durations: [CFTimeInterval] = [1.3, 1.1, 1.45, 1.2, 1.35]

    static func restingLevel(_ i: Int, of count: Int) -> CGFloat {
        [0.55, 0.85, 0.65, 0.4, 0.7][i % 5] * centreWeight(i, of: count)
    }

    /// Middle bars reach higher, like a spectrum.
    static func centreWeight(_ i: Int, of count: Int) -> CGFloat {
        1 - abs(CGFloat(i) - CGFloat(count - 1) / 2) / CGFloat(count) * 0.5
    }

    func makeNSView(context: Context) -> WaveformView { WaveformView() }

    func updateNSView(_ view: WaveformView, context: Context) {
        view.configure(color: color.cgColor, isAnimating: isAnimating, bars: bars, barWidth: barWidth, spacing: spacing)
    }

    final class WaveformView: NSView {
        private var barLayers: [CALayer] = []
        private var isAnimating = false
        private var geometry: (bars: Int, width: CGFloat, spacing: CGFloat) = (0, 0, 0)

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func configure(color: CGColor, isAnimating animating: Bool, bars: Int, barWidth: CGFloat, spacing: CGFloat) {
            if geometry != (bars, barWidth, spacing) {
                geometry = (bars, barWidth, spacing)
                barLayers.forEach { $0.removeFromSuperlayer() }
                barLayers = (0..<bars).map { _ in
                    let bar = CALayer()
                    bar.cornerRadius = barWidth / 2
                    layer?.addSublayer(bar)
                    return bar
                }
                isAnimating = false
                needsLayout = true
            }
            barLayers.forEach { $0.backgroundColor = color }
            if animating != isAnimating {
                isAnimating = animating
                animating ? start() : stop()
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, bar) in barLayers.enumerated() {
                let x = CGFloat(i) * (geometry.width + geometry.spacing) + geometry.width / 2
                bar.position = CGPoint(x: x, y: bounds.midY)
                bar.bounds.size = CGSize(width: geometry.width, height: restingHeight(i))
            }
            CATransaction.commit()
            if isAnimating { start() }
        }

        private func restingHeight(_ i: Int) -> CGFloat {
            isAnimating ? bounds.height * WaveformLayers.restingLevel(i, of: barLayers.count) : geometry.width
        }

        private func start() {
            guard bounds.height > 0 else { return }
            let now = CACurrentMediaTime()
            for (i, bar) in barLayers.enumerated() {
                let weight = WaveformLayers.centreWeight(i, of: barLayers.count)
                let pattern = WaveformLayers.patterns[i % WaveformLayers.patterns.count]
                let wave = CAKeyframeAnimation(keyPath: "bounds.size.height")
                wave.values = pattern.map { max(geometry.width, bounds.height * $0 * weight) }
                wave.calculationMode = .cubic
                wave.duration = WaveformLayers.durations[i % WaveformLayers.durations.count]
                wave.repeatCount = .infinity
                wave.beginTime = now - Double(i) * 0.37 // desynchronise the bars
                wave.isRemovedOnCompletion = false
                // a level meter reads fine at 30 fps; don't drive ProMotion at 120 Hz
                wave.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                bar.add(wave, forKey: "wave")
            }
        }

        private func stop() {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            for bar in barLayers {
                bar.removeAnimation(forKey: "wave")
                bar.bounds.size.height = geometry.width
            }
            CATransaction.commit()
        }
    }
}

extension EnvironmentValues {
    /// True under Reduce Motion or Low Power Mode: decorative motion holds still.
    @Entry var prefersStillness = false
}

// MARK: - Battery

struct BatteryGlyph: View {
    var level: Int
    var color: Color
    var isCharging = false
    var width: CGFloat = 25

    var body: some View {
        let height = width * 0.47
        HStack(spacing: width * 0.04) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.32, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.36), lineWidth: 1)
                RoundedRectangle(cornerRadius: height * 0.2, style: .continuous)
                    .fill(color)
                    .frame(width: max(2.5, (width - 4.5) * CGFloat(min(max(level, 0), 100)) / 100))
                    .padding(2.25)
            }
            .frame(width: width, height: height)
            .overlay {
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: height * 0.7, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 0.5)
                }
            }
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 1.2, topTrailingRadius: 1.2)
                .fill(Color.white.opacity(0.36))
                .frame(width: width * 0.06, height: height * 0.36)
        }
        .accessibilityElement()
        .accessibilityLabel("Battery \(level) percent\(isCharging ? ", charging" : "")")
    }
}

// MARK: - Ring

struct RingView<Center: View>: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 3.5
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.24), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.002, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
    }
}

// MARK: - Level bar

/// Draggable level (volume, brightness). Thickens under the pointer.
struct LevelBar: View {
    var level: Double
    var tint: Color = .white
    var onChange: ((Double) -> Void)?
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.fill)
                Capsule().fill(tint).frame(width: max(geo.size.height, geo.size.width * level))
            }
            .frame(height: isDragging ? 7 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    onChange?(max(0, min(1, value.location.x / geo.size.width)))
                }
                .onEnded { _ in isDragging = false })
        }
        .animation(Motion.snappy, value: level)
        .animation(Motion.snappy, value: isDragging)
        .accessibilityElement()
        .accessibilityValue("\(Int(level * 100)) percent")
        .accessibilityAdjustableAction { direction in
            onChange?(max(0, min(1, level + (direction == .increment ? 0.0625 : -0.0625))))
        }
    }
}

// MARK: - Marquee

/// Single-line text that scrolls when it overflows, with soft edges.
struct MarqueeText: View {
    @Environment(\.prefersStillness) private var prefersStillness
    let text: String
    var font: Font
    var color: Color = .white
    private let gap: CGFloat = 32
    private let speed: Double = 30
    private let pause: Double = 2.4
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflows = textWidth > geo.size.width + 0.5 && !prefersStillness
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !overflows)) { context in
                HStack(spacing: gap) {
                    label
                    if overflows { label }
                }
                .offset(x: overflows ? offset(at: context.date) : 0)
            }
            .frame(width: geo.size.width, alignment: .leading)
            .mask {
                if overflows {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                                           .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                } else {
                    Rectangle()
                }
            }
        }
        .frame(height: 19)
        .background {
            label.hidden().onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
        }
        .accessibilityElement()
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private func offset(at date: Date) -> CGFloat {
        let distance = Double(textWidth + gap)
        let cycle = distance / speed + pause
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        return phase < pause ? 0 : -CGFloat((phase - pause) * speed)
    }
}

// MARK: - Buttons

/// Circular icon button with a press response and hover highlight.
struct IslandButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 16
    var weight: Font.Weight = .semibold
    var tint: Color = .white
    var fill: Color? = nil
    var diameter: CGFloat? = nil
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace.offUp))
                .frame(width: diameter ?? size * 2.2, height: diameter ?? size * 2.2)
                .background(Circle().fill(fill ?? (isHovering ? Palette.secondaryFill : .clear)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
        .animation(Motion.snappy, value: isHovering)
        .accessibilityLabel(label)
        .help(label)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

extension NSWorkspace {
    func appIcon(bundleID: String?) -> NSImage? {
        guard let bundleID, let url = urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return icon(forFile: url.path)
    }
}
