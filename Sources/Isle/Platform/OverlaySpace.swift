import AppKit

/// A private window-server Space that sits above every desktop Space.
///
/// `.canJoinAllSpaces` + `.stationary` isn't enough: during a Space swipe the
/// window server still slides each Space's copy of the window with its
/// desktop, so a visible island briefly appears twice. Windows moved into
/// this Space are never part of the transition and stay put.
///
/// The SkyLight calls are resolved at runtime; if a future macOS drops them,
/// Isle keeps working with the collection-behaviour fallback. The Space
/// lives as long as the app; the window server cleans it up on exit.
@MainActor
final class OverlaySpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int, CFDictionary?) -> UInt64
    private typealias SpaceSetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpacesCall = @convention(c) (Int32, CFArray) -> Int32
    private typealias WindowsCall = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private let connection: Int32
    private let space: UInt64
    private let addWindows: WindowsCall

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return nil
        }
        func load<T>(_ name: String, as: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let main = load("SLSMainConnectionID", as: MainConnection.self),
              let create = load("SLSSpaceCreate", as: SpaceCreate.self),
              let setLevel = load("SLSSpaceSetAbsoluteLevel", as: SpaceSetLevel.self),
              let show = load("SLSShowSpaces", as: SpacesCall.self),
              let add = load("SLSAddWindowsToSpaces", as: WindowsCall.self)
        else { return nil }

        connection = main()
        // flag 1: a plain overlay Space (other values make Finder draw desktop icons in it)
        space = create(connection, 1, nil)
        guard space != 0 else { return nil }
        addWindows = add
        _ = setLevel(connection, space, Int32.max)
        _ = show(connection, [NSNumber(value: space)] as CFArray)
    }

    /// Moves `window` into the overlay Space. Safe to repeat; call again
    /// after the window is (re)ordered in.
    func add(_ window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        _ = addWindows(connection, [NSNumber(value: window.windowNumber)] as CFArray,
                       [NSNumber(value: space)] as CFArray)
    }
}
