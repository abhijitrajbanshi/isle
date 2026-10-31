import AudioToolbox
import CoreAudio
import IsleKit
import Observation

/// Output volume and mute of the default device.
@MainActor
@Observable
final class VolumeMonitor {
    private(set) var volume: Double = 0
    private(set) var isMuted = false

    @ObservationIgnored var post: (IslandAlert) -> Void = { _ in }
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    @ObservationIgnored private var device = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var listening: [AudioObjectPropertyAddress] = []

    private static let volumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    func start() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachToDefaultDevice() }
        }
        attachToDefaultDevice()
    }

    func setVolume(_ value: Double) {
        var level = Float32(max(0, min(1, value)))
        var address = Self.address(Self.volumeSelector)
        guard AudioObjectHasProperty(device, &address) else { return }
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
        if isMuted, level > 0 {
            var off: UInt32 = 0
            var mute = Self.address(kAudioDevicePropertyMute)
            AudioObjectSetPropertyData(device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &off)
        }
    }

    private func attachToDefaultDevice() {
        if let listener {
            for var a in listening { AudioObjectRemovePropertyListenerBlock(device, &a, .main, listener) }
        }
        listening.removeAll()

        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        device = id

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.read(announce: true) }
        }
        listener = block
        for selector in [Self.volumeSelector, kAudioDevicePropertyMute] {
            var a = Self.address(selector)
            if AudioObjectHasProperty(device, &a), AudioObjectAddPropertyListenerBlock(device, &a, .main, block) == noErr {
                listening.append(a)
            }
        }
        read(announce: false) // switching outputs is not a volume change
    }

    private func read(announce: Bool) {
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(Self.volumeSelector)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr else { return }
        var muted: UInt32 = 0
        var mute = Self.address(kAudioDevicePropertyMute)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &mute) { AudioObjectGetPropertyData(device, &mute, 0, nil, &size, &muted) }

        let changed = abs(Double(level) - volume) > 0.001 || (muted != 0) != isMuted
        volume = Double(level)
        isMuted = muted != 0
        if announce, changed, isEnabled() { post(.volume(level: volume, muted: isMuted)) }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
