import SwiftUI

/// Live camera with the vision model's detections drawn on top. Both the preview frame and the
/// detection boxes come from the one `DepthService` ARSession, so the camera, the LiDAR depth, and
/// the person detector all run together off a single rear-camera session. The detections come from
/// `DetectionStore`, which the YOLO tier fills; "Sample box" injects a fake one to show the overlay.
struct CameraPanel: View {
    let depth: DepthService
    let detections: DetectionStore
    let interference: InterferenceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Camera + vision", systemImage: "camera.viewfinder").font(.headline)

            ZStack {
                if let image = depth.previewImage {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                    DetectionOverlay(detections: detections.detections)
                    if let flag = interference.active {
                        EarlyWarningBanner(flag: flag)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray5))
                        .overlay {
                            Text(placeholder)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text("Detections: \(detections.detections.count)   Early warnings: \(interference.flaggedFrameCount)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("One session powers the camera, LiDAR depth, and the detector together.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            controls
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var placeholder: String {
        guard depth.isSupported else { return "LiDAR not supported on this device" }
        return depth.isRunning ? "Starting camera…" : "Start depth to show the camera + detections"
    }

    private var controls: some View {
        HStack {
            if depth.isRunning {
                Button("Stop depth") { depth.stop() }.buttonStyle(.bordered)
            } else {
                Button("Start depth") { depth.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!depth.isSupported)
            }
            Spacer()
            Button("Sample box") { detections.injectSample() }.buttonStyle(.bordered)
            Button("Clear") { detections.clear() }.buttonStyle(.bordered)
        }
    }
}

/// The early-warning readout, shown over the preview when the bearing tracker raises a flag: an
/// object holding the wearer's heading and looming before LiDAR can see it. Diagnostics for the demo
/// console; the soft cue this previews is wired in a later step.
struct EarlyWarningBanner: View {
    let flag: InterferenceFlag

    var body: some View {
        VStack {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(headline)
                    .font(.caption.bold().monospaced())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint, in: Capsule())
            .foregroundStyle(.black)
            .padding(.top, 8)
            Spacer()
        }
    }

    private var headline: String {
        let ttc = flag.timeToContactSeconds.map { String(format: "%.1fs", $0) } ?? "--"
        return "\(flag.label) ahead, \(ttc) (\(confidenceLabel))"
    }

    private var confidenceLabel: String {
        switch flag.confidence {
        case .low: return "low"
        case .medium: return "med"
        case .high: return "high"
        }
    }

    private var tint: Color {
        switch flag.confidence {
        case .low: return .yellow
        case .medium: return .orange
        case .high: return .red
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
