import CoreAudio
import Observation
import SwiftUI

/// Sound output switching and a system-wide microphone mute.
///
/// Event-driven like `PrivacyMonitor`: CoreAudio listeners on the device
/// list, the default devices and the input's mute, so nothing runs while
/// nothing changes.
@MainActor
@Observable
final class AudioModel {
    struct Device: Identifiable, Equatable {
        let id: AudioObjectID
        let name: String
        let transport: UInt32

        /// AirPods and headphones, speakers, displays and TVs, or a generic output.
        var symbol: String {
            let lower = name.lowercased()
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            switch transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                return lower.contains("speaker") ? "hifispeaker.fill" : "headphones"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
            case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
            case kAudioDeviceTransportTypeBuiltIn:
                return lower.contains("headphone") ? "headphones" : "laptopcomputer"
            case kAudioDeviceTransportTypeUSB: return "cable.connector"
            default: return "hifispeaker.fill"
            }
        }
    }

    private(set) var outputs: [Device] = []
    private(set) var currentOutput: AudioObjectID = 0
    /// The default input is muted (system-wide: every app hears silence).
    private(set) var isMicMuted = false
    private(set) var canMuteMic = false

    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var observedInput: AudioObjectID = 0
    /// For inputs without a mute control: their volume before muting.
    @ObservationIgnored private var volumeBeforeMute: Float32?

    var current: Device? { outputs.first { $0.id == currentOutput } }

    func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        listener = block
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main, block)
        }
        refresh()
    }

    func select(_ device: Device) {
        var id = device.id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &id)
        // keep system sounds on the same device, as the Sound menu does
        var system = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &system, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &id)
        currentOutput = device.id
    }

    func toggleMicMute() {
        let input = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        guard input != 0 else { return }
        let mute = !isMicMuted
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        if AudioObjectHasProperty(input, &address) {
            var value: UInt32 = mute ? 1 : 0
            AudioObjectSetPropertyData(input, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        } else {
            // no mute control: silence it through its volume instead
            var volume = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput)
            if mute { volumeBeforeMute = Self.float(input, &volume) ?? 1 }
            var value: Float32 = mute ? 0 : (volumeBeforeMute ?? 1)
            AudioObjectSetPropertyData(input, &volume, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
        refreshMic()
    }

    // MARK: State

    private func refresh() {
        let devices = Self.outputDevices()
        if outputs != devices { outputs = devices }
        let output = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        if currentOutput != output { currentOutput = output }
        observeInput()
        refreshMic()
    }

    /// Follows the default input so its mute changes (from any app) show here.
    private func observeInput() {
        let input = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        guard input != observedInput, let listener else { return }
        for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
            var address = Self.address(selector, scope: kAudioObjectPropertyScopeInput)
            if observedInput != 0 { AudioObjectRemovePropertyListenerBlock(observedInput, &address, .main, listener) }
            if input != 0, AudioObjectHasProperty(input, &address) {
                AudioObjectAddPropertyListenerBlock(input, &address, .main, listener)
            }
        }
        observedInput = input
        volumeBeforeMute = nil
    }

    private func refreshMic() {
        let input = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        var mute = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        var volume = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput)
        let muted: Bool
        if input != 0, AudioObjectHasProperty(input, &mute) {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            muted = AudioObjectGetPropertyData(input, &mute, 0, nil, &size, &value) == 0 && value != 0
        } else if input != 0, let level = Self.float(input, &volume) {
            muted = level == 0
        } else {
            muted = false
        }
        let canMute = input != 0 && (AudioObjectHasProperty(input, &mute) || AudioObjectHasProperty(input, &volume))
        if isMicMuted != muted { isMicMuted = muted }
        if canMuteMic != canMute { canMuteMic = canMute }
    }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var address = address(selector)
        var id: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func float(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Float32? {
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == 0 ? value : nil
    }

    /// Devices that can play sound and that the Sound menu would list.
    private static func outputDevices() -> [Device] {
        var address = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == 0 else { return [] }
        return ids.compactMap { id in
            var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == 0, streamSize > 0 else { return nil }
            var hidden = Self.address(kAudioDevicePropertyIsHidden)
            var isHidden: UInt32 = 0
            var flagSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &hidden, 0, nil, &flagSize, &isHidden) == 0, isHidden != 0 { return nil }
            var transportAddress = Self.address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &flagSize, &transport)
            // aggregate and virtual devices (Zoom, Teams, recorders) aren't speakers
            if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual {
                return nil
            }
            var nameAddress = Self.address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == 0,
                  let value = name?.takeRetainedValue() as String? else { return nil }
            return Device(id: id, name: value, transport: transport)
        }
    }

    /// Fixture for previews, snapshots and the demo: never the real devices.
    func preview(outputs names: [(String, UInt32)], current index: Int, micMuted: Bool) {
        outputs = names.enumerated().map { Device(id: AudioObjectID($0.offset + 1), name: $0.element.0,
                                                  transport: $0.element.1) }
        currentOutput = AudioObjectID(index + 1)
        isMicMuted = micMuted
        canMuteMic = true
    }
}
