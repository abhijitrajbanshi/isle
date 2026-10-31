import Foundation
import IOKit.ps
import IsleKit
import Observation

/// Battery and power source, driven by IOKit power-source notifications.
@MainActor
@Observable
final class PowerMonitor {
    private(set) var level = 100
    private(set) var isCharging = false
    private(set) var isPluggedIn = false
    private(set) var hasBattery = false
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    @ObservationIgnored var post: (IslandAlert) -> Void = { _ in }
    @ObservationIgnored var powerAlerts: () -> Bool = { true }
    @ObservationIgnored var lowBatteryAlerts: () -> Bool = { true }
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var warned = Set<Int>()
    @ObservationIgnored private var started = false

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.read() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerModeChanged() }
        }
        read()
        started = true
    }

    private func lowPowerModeChanged() {
        let on = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard on != isLowPowerMode else { return }
        isLowPowerMode = on
        if powerAlerts() { post(.lowPowerMode(isOn: on, level: level)) }
    }

    private func read() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let newLevel = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            let plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let wasPlugged = isPluggedIn

            hasBattery = true
            if level != newLevel { level = newLevel }
            if isPluggedIn != plugged { isPluggedIn = plugged }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            if isCharging != charging { isCharging = charging }

            guard started else { return }
            if plugged != wasPlugged, powerAlerts() {
                post(.power(level: newLevel, isCharging: plugged))
            }
            if plugged { warned.removeAll() }
            if !plugged, let threshold = [10, 20].first(where: { newLevel <= $0 && !warned.contains($0) }) {
                warned.formUnion([10, 20].filter { $0 >= threshold })
                if lowBatteryAlerts() { post(.lowBattery(level: newLevel)) }
            }
            return
        }
    }

    func preview(level: Int, charging: Bool) {
        hasBattery = true
        self.level = level
        isPluggedIn = charging
        isCharging = charging
    }
}
