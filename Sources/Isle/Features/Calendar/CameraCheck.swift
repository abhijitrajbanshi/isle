import AVFoundation
import AppKit
import SwiftUI

/// A small live mirror for checking yourself before a call. The camera runs
/// only while you're looking at it: it starts on a click and stops when the
/// card goes away (or on a second click).
struct CameraCheck: View {
    var size: CGFloat = 76
    @State private var session = CameraSession()
    @State private var isOn = false
    @State private var denied = false
    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.secondaryFill)
                if isOn {
                    CameraPreview(session: session)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: denied ? "video.slash.fill" : "person.crop.circle")
                            .font(.system(size: 22, weight: .regular))
                        Text(denied ? "No access" : "Check camera")
                            .font(.island(10.5, .semibold))
                    }
                    .foregroundStyle(isHovering ? Palette.label : Palette.secondaryLabel)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
        .animation(Motion.morph, value: isOn)
        .onDisappear { session.stop() }
        .accessibilityLabel(isOn ? "Turn camera preview off" : "Check camera")
    }

    private func toggle() {
        if isOn {
            session.stop()
            isOn = false
            return
        }
        if denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            return
        }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                denied = true
                return
            }
            session.start()
            isOn = true
        }
    }
}

/// The capture session, started and stopped off the main thread (both block).
final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "Isle.camera")
    private var configured = false

    func start() {
        queue.async { [self] in
            if !configured {
                configured = true
                session.sessionPreset = .medium
                if let device = AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: CameraSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session.session)
        layer.videoGravity = .resizeAspectFill
        // a mirror, as you'd expect to see yourself
        layer.connection?.automaticallyAdjustsVideoMirroring = false
        layer.connection?.isVideoMirrored = true
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
