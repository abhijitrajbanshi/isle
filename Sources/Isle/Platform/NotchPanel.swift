import AppKit
import IsleKit
import SwiftUI

/// Borderless, transparent, non-activating panel above the menu bar on every
/// Space. Mouse events are accepted only while the pointer is on the island
/// (see `IslandWindowController`), so everything around it stays clickable.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    // Never key: clicking a control on the island must not take keyboard
    // focus away from the app the user is typing in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that takes the first click (no "activate, then click").
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum ScreenLocator {
    /// The screen the island should live on, honouring the display preference.
    @MainActor
    static func screen(for preferences: Preferences) -> NSScreen? {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        switch preferences.display {
        case .main: return NSScreen.main ?? notched
        case .builtIn:
            if let notched { return notched }
            return preferences.showOnDisplaysWithoutNotch ? (NSScreen.main ?? NSScreen.screens.first) : nil
        }
    }

    static func metrics(for screen: NSScreen) -> NotchMetrics {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The notch is what the two auxiliary areas leave between them.
            let width = right.minX - left.maxX
            return NotchMetrics(size: CGSize(width: width, height: top), hasNotch: true, screenFrame: screen.frame)
        }
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return NotchMetrics(size: CGSize(width: 180, height: min(menuBar, 32)), hasNotch: false,
                            screenFrame: screen.frame)
    }
}
