import AppKit
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: IsleContainer!
    private var islandWindow: IslandWindowController!
    private var updater: Updater!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let id = Bundle.main.bundleIdentifier ?? "Isle"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).count <= 1 else {
            NSApp.terminate(nil)
            return
        }
        updater = Updater()
        container = IsleContainer()
        container.openSettings = { [weak self] in self?.showSettings() }
        islandWindow = IslandWindowController(container: container)
        container.start()
        observeMenuBarPreference()
    }

    /// Opening Isle again (from Finder, Spotlight or the Dock) shows Settings:
    /// there's no window otherwise, and nothing would seem to happen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        container?.stop()
    }

    // MARK: Menu bar item

    private func observeMenuBarPreference() {
        withObservationTracking {
            updateStatusItem(visible: container.preferences.showMenuBarIcon)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMenuBarPreference() }
        }
    }

    private func updateStatusItem(visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "capsule.portrait.fill", accessibilityDescription: "Isle")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            item.button?.image?.isTemplate = true
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Isle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    // MARK: Settings

    @objc func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView().isleEnvironment(container).environment(updater))
            controller.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: controller)
            window.title = "Isle"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
