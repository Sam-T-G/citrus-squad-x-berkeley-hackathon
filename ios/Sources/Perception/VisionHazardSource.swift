import Foundation
import Observation

/// Cole's plug point for OpenCV object detection.
///
/// The core loop already polls this as a `HazardSource` alongside LiDAR. To wire in the OpenCV
/// model, run the detector wherever it lives (on-device through the OpenCV iOS framework, or on a
/// laptop feeding results over the network) and call `report(...)` whenever it sees something in
/// the path, then `clear()` when the path is clear. The arbitration in `AppModel` does the rest:
/// it fuses this with the LiDAR distance and decides whether the belt fires.
///
/// Nothing else needs to change. Replace the body of `report` with the real detection callback and
/// the system treats CV exactly like the built-in depth sensor.
@MainActor
@Observable
final class VisionHazardSource: HazardSource {
    /// Turn the source on or off without unregistering it.
    var isEnabled = true

    /// The latest detection, or nil for a clear path. Set through `report` / `clear`.
    private(set) var detected: Hazard?

    var currentHazard: Hazard? {
        isEnabled ? detected : nil
    }

    /// Call from the OpenCV pipeline when a target is in the path.
    /// - Parameters:
    ///   - kind: `.person` for a person-in-path (emits vision-danger), `.obstacle` otherwise.
    ///   - side: which belt quadrant to fire, per the side-is-the-hazard convention in `docs/12`.
    ///   - distanceMeters: best distance estimate, ideally fused with LiDAR depth. -1 if unknown.
    func report(kind: Hazard.Kind, side: QuadrantMask, distanceMeters: Double = -1) {
        detected = Hazard(kind: kind, mask: side, distanceMeters: distanceMeters)
    }

    /// Call when the detector no longer sees a target in the path.
    func clear() {
        detected = nil
    }
}
