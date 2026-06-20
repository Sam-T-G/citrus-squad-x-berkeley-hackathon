import Foundation
import AVFoundation
import Observation
import SwiftUI
import UIKit

/// Runs the rear camera for the demo visualizer and owns the preview. Cole's vision model attaches
/// to `session` (add an `AVCaptureVideoDataOutput`) to read frames, runs OpenCV, and writes results
/// into `DetectionStore`; the camera panel draws them. This service stays out of the CV business.
///
/// Note: the rear camera is exclusive. ARKit scene depth (`DepthService`) and this camera cannot
/// both run at once, so stop depth before starting the camera, or vice versa.
@MainActor
@Observable
final class CameraService: NSObject {
    /// Exposed so the vision model can attach its own output. Touched only on `queue` for session
    /// mutation; safe because all session calls funnel through that serial queue.
    nonisolated(unsafe) let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.citrussquad.camera.session")

    private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var isRunning = false

    var isAuthorized: Bool { authorization == .authorized }

    func requestPermission() {
        Task { @MainActor in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorization = granted ? .authorized : .denied
        }
    }

    func start() {
        guard isAuthorized, !isRunning else { return }
        isRunning = true
        let session = self.session
        queue.async { Self.configureAndStart(session) }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        let session = self.session
        queue.async { session.stopRunning() }
    }

    nonisolated private static func configureAndStart(_ session: AVCaptureSession) {
        if session.inputs.isEmpty {
            session.beginConfiguration()
            session.sessionPreset = .high
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
        }
        session.startRunning()
    }
}

/// SwiftUI wrapper around an `AVCaptureVideoPreviewLayer`.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
