import AppKit

/// Answers "is this app filling this display?", for hiding the island while
/// the app that's playing media is full screen.
///
/// Only called in response to events (Space and app switches, track changes,
/// clicks); it never polls. Two kinds of full screen are recognised:
/// * the system's: the display's current Space is a full-screen Space the
///   app owns (browsers' full-screen video, QuickTime, IINA, TV);
/// * an app's own (VLC by default, many games): one of its windows covers
///   the whole display, menu bar area included, on a normal Space.
@MainActor
enum FullScreenDetector {
    enum Kind: String { case space = "full-screen Space", window = "own full-screen window" }

    /// How `bundleID`'s app fills `screen`, or nil if it doesn't.
    static func app(_ bundleID: String, fills screen: NSScreen) -> Kind? {
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { NowPlayingService.appBundleID(for: $0.bundleIdentifier) == bundleID }
            .map(\.processIdentifier))
        guard !pids.isEmpty else { return nil }
        if let owner = fullScreenSpaceOwner(on: screen) {
            // the current Space is somebody's full-screen Space: decisive either way
            return pids.contains(owner) ? .space : nil
        }
        // An app's own full screen only counts while it's in front: while
        // switching away its window lingers in the list for a moment.
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, pids.contains(front) else {
            return nil
        }
        return hasCoveringWindow(on: screen, ownedBy: pids) ? .window : nil
    }

    // MARK: System full screen

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let skyLight: (MainConnection, CopyDisplaySpaces)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let main = dlsym(handle, "SLSMainConnectionID"),
              let copy = dlsym(handle, "SLSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(main, to: MainConnection.self), unsafeBitCast(copy, to: CopyDisplaySpaces.self))
    }()

    /// The app owning the display's current Space, if that Space is full screen.
    private static func fullScreenSpaceOwner(on screen: NSScreen) -> pid_t? {
        guard let (main, copy) = skyLight,
              let displays = copy(main())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let uuid = displayUUID(of: screen)
        // one entry per display, or a single "Main" one when displays share Spaces
        let display = displays.first { ($0["Display Identifier"] as? String) == uuid }
            ?? (displays.count == 1 ? displays.first : nil)
        guard let current = display?["Current Space"] as? [String: Any],
              current["type"] as? Int == 4 else { return nil } // 4: full-screen Space
        return (current["pid"] as? NSNumber)?.int32Value
    }

    private static func displayUUID(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    // MARK: An app's own full screen

    /// Reads window bounds only, which needs no Screen Recording permission.
    private static func hasCoveringWindow(on screen: NSScreen, ownedBy pids: Set<pid_t>) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        // window bounds are top-left based, relative to the primary display
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let target = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                            width: screen.frame.width, height: screen.frame.height)
        return windows.contains { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect == target
        }
    }
}
