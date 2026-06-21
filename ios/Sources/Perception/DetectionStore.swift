import Foundation
import CoreGraphics

/// One object the vision model found in the camera frame. `box` is normalized to 0...1 in image
/// space (origin top-left), so the overlay can draw it at any preview size.
struct Detection: Identifiable, Sendable, Equatable {
    let id = UUID()
    var label: String
    var confidence: Double
    var box: CGRect
}

/// Cole's plug point for computer vision. The camera panel draws whatever is in here over the live
/// preview. Wire the OpenCV (or Vision) model to call `update(_:)` with its detections each frame,
/// normalized to 0...1, and the overlay renders them. Nothing else changes.
///
/// `injectSample()` drops in a fake box so the overlay can be demoed before the model is wired.
@MainActor
@Observable
final class DetectionStore {
    private(set) var detections: [Detection] = []
    var isEnabled = true

    func update(_ detections: [Detection]) {
        self.detections = isEnabled ? detections : []
    }

    func clear() {
        detections = []
    }

    func injectSample() {
        detections = [
            Detection(label: "person", confidence: 0.92,
                      box: CGRect(x: 0.34, y: 0.28, width: 0.32, height: 0.55))
        ]
    }
}
