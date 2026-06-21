import SwiftUI

/// The full-bleed camera feed that fills the Demo HUD: the wearer's-eye view with the vision model's
/// detection boxes drawn on top. The frame and the boxes both come from the one `DepthService`
/// ARSession, so the camera, the LiDAR depth, and the detector all run off a single rear-camera
/// session. When depth is not running it shows a dark prompt instead of an empty frame.
///
/// The feed is pinned to the exact viewport size and clipped, so the camera frame (whatever its
/// native resolution or aspect) never grows the layout or bleeds past the screen. It fills by
/// cropping, so the aspect stays true and the image is not stretched.
struct CameraBackdrop: View {
    let depth: DepthService
    let detections: DetectionStore

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = depth.previewImage {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    DetectionOverlay(detections: detections.detections)
                    // A soft top-and-bottom scrim so the white HUD text stays legible over a bright frame.
                    LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    placeholder
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemGray4), Color(.systemGray6)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 10) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.secondary)
                Text(placeholderText)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
            }
        }
    }

    private var placeholderText: String {
        guard depth.isSupported else { return "LiDAR is not supported on this device" }
        return depth.isRunning ? "Starting camera…" : "Tap Start camera to bring up the live view"
    }
}
