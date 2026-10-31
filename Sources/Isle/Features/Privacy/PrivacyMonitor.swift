import CoreAudio
import CoreMediaIO
import Observation
import SwiftUI

/// Camera and microphone in use by any app (the iPhone's green / orange dot).
///
/// Fully event-driven: CoreAudio and CoreMediaIO property listeners on each
/// device's "running somewhere" flag, plus the device lists themselves. No
/// polling, so it's free while nothing changes.
@MainActor
@Observable
final class PrivacyMonitor {
    private(set) var isCameraInUse = false
    private(set) var isMicrophoneInUse = false

    @ObservationIgnored var isEnabled: () -> Bool = { true }
    @ObservationIgnored private var audioListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var cameraListener: CMIOObjectPropertyListenerBlock?
    @ObservationIgnored private var audioDevices: [AudioObjectID] = []
    /// macOS 14.2+: audio *processes* that are capturing input.
    @ObservationIgnored private var audioProcesses: [AudioObjectID] = []
    @ObservationIgnored private var tracksProcesses = false
    @ObservationIgnored private var cameraDevices: [CMIOObjectID] = []

    var isActive: Bool { isEnabled() && (isCameraInUse || isMicrophoneInUse) }
    var tint: Color { isCameraInUse ? Palette.green : Palette.orange }
    var symbol: String { isCameraInUse ? "video.fill" : "mic.fill" }

    func start() {
        let audio: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshMicrophone() }
        }
        audioListener = audio
        if #available(macOS 14.2, *) {
            // Per-process input state: a headset playing music has a running
            // device but no process recording, so it must not light the dot.
            tracksProcesses = true
            var processList = Self.audioAddress(kAudioHardwarePropertyProcessObjectList, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processList, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.attachProcesses() }
            }
            attachProcesses()
        } else {
            var audioList = Self.audioAddress(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &audioList, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.attachMicrophones() }
            }
            attachMicrophones()
        }

        let camera: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshCamera() }
        }
        cameraListener = camera
        var cameraList = Self.cameraAddress(kCMIOHardwarePropertyDevices)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &cameraList, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachCameras() }
        }
        attachCameras()
    }

    // MARK: Microphone

    @available(macOS 14.2, *)
    private func attachProcesses() {
        guard let audioListener else { return }
        var input = Self.audioAddress(kAudioProcessPropertyIsRunningInput, scope: kAudioObjectPropertyScopeGlobal)
        for process in audioProcesses {
            AudioObjectRemovePropertyListenerBlock(process, &input, .main, audioListener)
        }
        audioProcesses = Self.objects(kAudioHardwarePropertyProcessObjectList)
        for process in audioProcesses {
            AudioObjectAddPropertyListenerBlock(process, &input, .main, audioListener)
        }
        refreshMicrophone()
    }

    private func attachMicrophones() {
        guard let audioListener else { return }
        var running = Self.audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioDevicePropertyScopeInput)
        for device in audioDevices {
            AudioObjectRemovePropertyListenerBlock(device, &running, .main, audioListener)
        }
        audioDevices = Self.inputDevices()
        for device in audioDevices {
            AudioObjectAddPropertyListenerBlock(device, &running, .main, audioListener)
        }
        refreshMicrophone()
    }

    private func refreshMicrophone() {
        if tracksProcesses, #available(macOS 14.2, *) {
            var input = Self.audioAddress(kAudioProcessPropertyIsRunningInput, scope: kAudioObjectPropertyScopeGlobal)
            let inUse = audioProcesses.contains { process in
                var running: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                return AudioObjectGetPropertyData(process, &input, 0, nil, &size, &running) == noErr && running != 0
            }
            if inUse != isMicrophoneInUse { isMicrophoneInUse = inUse }
            return
        }
        var address = Self.audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioDevicePropertyScopeInput)
        let inUse = audioDevices.contains { device in
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
        }
        if inUse != isMicrophoneInUse { isMicrophoneInUse = inUse }
    }

    /// An object list (devices, processes) of the audio system object.
    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = audioAddress(selector, scope: kAudioObjectPropertyScopeGlobal)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func inputDevices() -> [AudioObjectID] {
        objects(kAudioHardwarePropertyDevices).filter { device in
            var streams = audioAddress(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr && streamSize > 0
        }
    }

    private static func audioAddress(_ selector: AudioObjectPropertySelector,
                                     scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: Camera

    private func attachCameras() {
        guard let cameraListener else { return }
        var running = Self.cameraAddress(kCMIODevicePropertyDeviceIsRunningSomewhere, wildcard: true)
        for device in cameraDevices {
            CMIOObjectRemovePropertyListenerBlock(device, &running, .main, cameraListener)
        }
        cameraDevices = Self.cameras()
        for device in cameraDevices {
            CMIOObjectAddPropertyListenerBlock(device, &running, .main, cameraListener)
        }
        refreshCamera()
    }

    private func refreshCamera() {
        var address = Self.cameraAddress(kCMIODevicePropertyDeviceIsRunningSomewhere, wildcard: true)
        let inUse = cameraDevices.contains { device in
            var running: UInt32 = 0
            var used: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size),
                                             &used, &running) == 0 && running != 0
        }
        if inUse != isCameraInUse { isCameraInUse = inUse }
    }

    private static func cameras() -> [CMIOObjectID] {
        var address = cameraAddress(kCMIOHardwarePropertyDevices)
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return [] }
        return devices
    }

    private static func cameraAddress(_ selector: Int, wildcard: Bool = false) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: wildcard ? CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard)
                             : CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: wildcard ? CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
                               : CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
}

struct PrivacyCompactLeading: View {
    @Environment(PrivacyMonitor.self) private var privacy

    var body: some View {
        Image(systemName: privacy.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(privacy.tint)
    }
}

struct PrivacyDot: View {
    @Environment(PrivacyMonitor.self) private var privacy

    var body: some View {
        Circle().fill(privacy.tint).frame(width: 7, height: 7)
            .shadow(color: privacy.tint.opacity(0.7), radius: 3)
    }
}
