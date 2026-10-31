import AppKit
import IsleKit

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
