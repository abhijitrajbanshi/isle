import IsleKit
import SwiftUI

struct ExpandedContent: View {
    @Environment(IslandEngine.self) private var engine

    var body: some View {
        VStack(spacing: 0) {
            ExpandedHeader().frame(height: engine.metrics.size.height)
            ZStack {
                switch engine.tab {
                case .home: HomeTab().transition(.islandContent)
                case .timer: TimerTab().transition(.islandContent)
                case .shelf: ShelfTab().transition(.islandContent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.morph, value: engine.tab)
        }
    }
}

/// Tabs to the left of the notch, status to the right.
private struct ExpandedHeader: View {
    @Environment(IslandEngine.self) private var engine
    @Environment(PowerMonitor.self) private var power
    @Environment(\.openIsleSettings) private var openSettings
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(ExpandedTab.allCases, id: \.self) { tab in
                    Button { engine.tab = tab } label: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(engine.tab == tab ? .white : Palette.tertiaryLabel)
                            .frame(width: 32, height: 22)
                            .background {
                                if engine.tab == tab {
                                    Capsule().fill(Palette.fill).matchedGeometryEffect(id: "tab", in: selection)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(tab.title)
                    .help(tab.title)
                }
            }
            Spacer(minLength: engine.metrics.size.width + 24)
            if power.hasBattery {
                HStack(spacing: 5) {
                    Text("\(power.level)%").font(.islandNumber(11.5, .medium)).foregroundStyle(Palette.secondaryLabel)
                    BatteryGlyph(level: power.level,
                                 color: power.isLowPowerMode ? Palette.yellow
                                     : (power.isPluggedIn ? Palette.green
                                         : (power.level <= 20 ? Palette.battery(power.level) : .white)),
                                 isCharging: power.isPluggedIn, width: 22)
                }
            }
            IslandButton(symbol: "gearshape.fill", label: "Settings", size: 11.5, tint: Palette.tertiaryLabel,
                         diameter: 24) {
                engine.collapse()
                openSettings()
            }
            .padding(.leading, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .animation(Motion.snappy, value: engine.tab)
    }
}

private struct HomeTab: View {
    @Environment(TimerModel.self) private var timer

    var body: some View {
        HStack(spacing: 16) {
            NowPlayingCard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Group {
                if timer.isActive { TimerWidget() } else { CalendarWidget() }
            }
            .padding(13)
            .frame(width: 168)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.secondaryFill))
        }
    }
}

extension ExpandedTab {
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .timer: "timer"
        case .shelf: "tray.full.fill"
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .timer: "Timer"
        case .shelf: "Shelf"
        }
    }
}
