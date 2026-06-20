import SwiftUI

/// Live camera with the vision model's detections drawn on top. The camera feed and the overlay
/// renderer are here; the detections come from `DetectionStore`, which Cole's OpenCV model fills.
/// Until then, "Sample box" injects a fake detection so the overlay is visibly working.
struct CameraPanel: View {
    let camera: CameraService
    let detections: DetectionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Camera + vision", systemImage: "camera.viewfinder").font(.headline)

            ZStack {
                if camera.isRunning {
                    CameraPreview(session: camera.session)
                    DetectionOverlay(detections: detections.detections)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray5))
                        .overlay {
                            Text(camera.isAuthorized ? "Camera stopped" : "Camera permission needed")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text("Detections: \(detections.detections.count)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("Stop Depth (LiDAR) before starting the camera; they share the rear camera.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            controls
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        HStack {
            if camera.isAuthorized {
                if camera.isRunning {
                    Button("Stop") { camera.stop() }.buttonStyle(.bordered)
                } else {
                    Button("Start camera") { camera.start() }.buttonStyle(.borderedProminent)
                }
            } else {
                Button("Allow camera") { camera.requestPermission() }.buttonStyle(.borderedProminent)
            }
            Spacer()
            Button("Sample box") { detections.injectSample() }.buttonStyle(.bordered)
            Button("Clear") { detections.clear() }.buttonStyle(.bordered)
        }
    }
}

/// Draws normalized detection boxes over whatever fills its frame.
struct DetectionOverlay: View {
    let detections: [Detection]

    var body: some View {
        GeometryReader { geo in
            ForEach(detections) { detection in
                let rect = CGRect(
                    x: detection.box.minX * geo.size.width,
                    y: detection.box.minY * geo.size.height,
                    width: detection.box.width * geo.size.width,
                    height: detection.box.height * geo.size.height
                )
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.green, lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: .topLeading) {
                        Text("\(detection.label) \(Int(detection.confidence * 100))%")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .background(.green)
                            .foregroundStyle(.black)
                            .offset(y: -16)
                    }
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}
