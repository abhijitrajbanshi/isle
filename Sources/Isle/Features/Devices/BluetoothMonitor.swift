import AppKit
import IOBluetooth
import IsleKit

/// Connect / disconnect alerts for Bluetooth devices, with battery when the
/// device reports it.
@MainActor
final class BluetoothMonitor: NSObject {
    var post: (IslandAlert) -> Void = { _ in }
    var isEnabled: () -> Bool = { true }

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    /// No alerts until then: at launch IOBluetooth replays connected devices,
    /// and around sleep keyboards and mice drop and reconnect by themselves.
    private var quietUntil = Date.now.addingTimeInterval(3)

    func start() {
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(connected(_:device:)))
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quietUntil = .distantFuture }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quietUntil = .now.addingTimeInterval(8) }
        }
    }

    private var isQuiet: Bool { Date.now < quietUntil }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let key = device.addressString ?? UUID().uuidString
        disconnectNotifications[key] = device.register(forDisconnectNotification: self,
                                                       selector: #selector(disconnected(_:device:)))
        guard !isQuiet else { return }
        // AirPods publish battery a moment after the link comes up
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            // a link that dropped again meanwhile already showed "Disconnected"
            guard device.isConnected() else { return }
            self?.announce(device, connected: true)
        }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        if let key = device.addressString { disconnectNotifications[key] = nil }
        guard !isQuiet else { return }
        announce(device, connected: false)
    }

    private func announce(_ device: IOBluetoothDevice, connected: Bool) {
        guard isEnabled() else { return }
        post(.device(DeviceInfo(name: device.name ?? "Bluetooth Device", symbol: Self.symbol(for: device),
                                battery: connected ? Self.battery(of: device) : nil, isConnected: connected)))
    }

    /// Long-standing private IOBluetoothDevice properties; absent → no ring.
    private static func battery(of device: IOBluetoothDevice) -> Int? {
        for key in ["batteryPercentCombined", "batteryPercentSingle", "batteryPercentLeft", "batteryPercentRight"]
        where device.responds(to: NSSelectorFromString(key)) {
            if let value = device.value(forKey: key) as? Int, value > 0 { return value }
        }
        return nil
    }

    static func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        let byName: [(String, String)] = [
            ("airpods max", "airpodsmax"), ("airpods pro", "airpodspro"), ("airpods", "airpods"),
            ("beats", "beats.headphones"), ("keyboard", "keyboard.fill"),
            ("trackpad", "rectangle.and.hand.point.up.left.fill"), ("mouse", "magicmouse.fill"),
        ]
        if let match = byName.first(where: { name.contains($0.0) }) { return match.1 }
        switch device.deviceClassMajor {
        case 0x04: return "headphones"
        case 0x05:
            let minor = device.deviceClassMinor
            if minor & 0x10 != 0 { return "keyboard.fill" }
            if minor & 0x20 != 0 { return "computermouse.fill" }
            return "gamecontroller.fill"
        case 0x02: return "iphone"
        default: return "wave.3.right"
        }
    }
}
