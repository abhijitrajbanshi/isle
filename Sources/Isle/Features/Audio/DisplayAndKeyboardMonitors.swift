import AppKit
import IsleKit
import Observation

/// Built-in display brightness via DisplayServices (private, loaded at
/// runtime). Driven by DisplayServices' own change notifications, so it
/// costs nothing while brightness isn't changing.
@MainActor
@Observable
final class BrightnessMonitor {
    private(set) var level: Double = 0

    @ObservationIgnored var post: (IslandAlert) -> Void = { _ in }
    @ObservationIgnored var isEnabled: () -> Bool = { true }

    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias Register = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?, CFNotificationCallback) -> Int32

    @ObservationIgnored private var get: Get?
    @ObservationIgnored private var set: Set?
    @ObservationIgnored private var display = CGMainDisplayID()
    @ObservationIgnored private var fallbackPoll: Task<Void, Never>?
    /// Start of the current burst of changes, to tell key presses from auto-brightness.
    @ObservationIgnored private var burst: (date: Date, level: Double) = (.distantPast, 0)
    @ObservationIgnored private var lastStep = Date.distantPast

    @ObservationIgnored private var register: Register?
    /// The built-in display currently watched; nil when there's none (desktop
    /// Macs, clamshell mode), in which case nothing runs at all.
    @ObservationIgnored private var watched: CGDirectDisplayID?
    @ObservationIgnored private var registered = Swift.Set<CGDirectDisplayID>()

    func start() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let getter = dlsym(handle, "DisplayServicesGetBrightness") else { return }
        get = unsafeBitCast(getter, to: Get.self)
        if let setter = dlsym(handle, "DisplayServicesSetBrightness") { set = unsafeBitCast(setter, to: Set.self) }
        if let symbol = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications") {
            register = unsafeBitCast(symbol, to: Register.self)
        }
        // displays come and go (lid opened after a clamshell launch, external monitors)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retarget() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fallbackPoll?.cancel() }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retarget(force: true) }
        }
        retarget()
    }

    /// Watches the built-in display, via change notifications where available.
    private func retarget(force: Bool = false) {
        let builtIn = Self.builtInDisplay()
        guard force || builtIn != watched else { return }
        fallbackPoll?.cancel()
        watched = builtIn
        guard let builtIn else { return }
        display = builtIn
        level = read() ?? level

        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let monitor = Unmanaged<BrightnessMonitor>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { monitor.brightnessChanged() } }
        }
        if registered.contains(builtIn) { return }   // registrations persist; never double up
        if let register, register(builtIn, Unmanaged.passUnretained(self).toOpaque(), callback) == 0 {
            registered.insert(builtIn)
            return
        }
        // No notifications on this system: poll slowly, letting the OS coalesce wakeups.
        fallbackPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250), tolerance: .milliseconds(100))
                self?.brightnessChanged()
            }
        }
    }

    func setLevel(_ value: Double) {
        guard watched != nil else { return }
        let v = max(0, min(1, value))
        _ = set?(display, Float(v))
        level = v
        lastStep = .now
        if isEnabled() { post(.brightness(level: v)) }
    }

    private func read() -> Double? {
        var v: Float = 0
        guard let get, get(display, &v) == 0 else { return nil }
        return Double(v)
    }

    private func brightnessChanged() {
        guard watched != nil, let v = read(), abs(v - level) > 0.0005 else { return }
        let now = Date.now
        // A key press moves brightness by 1/16 within a few hundred ms (animated
        // in small increments); auto-brightness drifts slowly and stays silent.
        if now.timeIntervalSince(burst.date) > 0.4 { burst = (now, level) }
        if abs(v - burst.level) >= 0.025 { lastStep = now }
        level = v
        if now.timeIntervalSince(lastStep) < 0.6, isEnabled() { post(.brightness(level: v)) }
    }

    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }
}

/// Caps Lock, event-driven where the system allows it.
///
/// A `flagsChanged` monitor costs nothing between key presses. Whether macOS
/// delivers it without Input Monitoring varies, so a slow, coalesced poll
/// covers the gap and switches itself off the first time an event arrives.
@MainActor
final class CapsLockMonitor {
    var post: (IslandAlert) -> Void = { _ in }
    var isEnabled: () -> Bool = { true }
    private var isOn = NSEvent.modifierFlags.contains(.capsLock)
    private var monitors: [Any] = []
    private var fallbackPoll: Task<Void, Never>?
    /// Set once the event monitor has delivered; polling is then never needed.
    private var monitorIsLive = false

    func start() {
        // Only the global monitor proves events reach Isle while other apps are
        // in front; key presses in Isle's own Settings window prove nothing.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.monitorIsLive = true
                self?.fallbackPoll?.cancel()
                self?.update(event.modifierFlags.contains(.capsLock))
            }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.update(event.modifierFlags.contains(.capsLock)) }
            return event
        }) {
            monitors.append(local)
        }
        // nobody sees an alert while the display sleeps; don't poll then
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fallbackPoll?.cancel() }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startFallbackPoll() }
        }
        startFallbackPoll()
    }

    private func startFallbackPoll() {
        guard !monitorIsLive else { return }
        fallbackPoll?.cancel()
        fallbackPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400), tolerance: .milliseconds(200))
                self?.update(NSEvent.modifierFlags.contains(.capsLock))
            }
        }
    }

    private func update(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if isEnabled() { post(.capsLock(isOn: on)) }
    }
}
