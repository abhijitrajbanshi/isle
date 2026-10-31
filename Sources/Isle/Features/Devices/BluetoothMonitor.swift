import Foundation
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
    private let launchedAt = Date.now

    func start() {
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(connected(_:device:)))
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let key = device.addressString ?? UUID().uuidString
        disconnectNotifications[key] = device.register(forDisconnectNotification: self,
                                                       selector: #selector(disconnected(_:device:)))
        // IOBluetooth replays already-connected devices at registration
        guard Date.now.timeIntervalSince(launchedAt) > 3 else { return }
        // AirPods publish battery a moment after the link comes up
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            self?.announce(device, connected: true)
        }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        if let key = device.addressString { disconnectNotifications[key] = nil }
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
