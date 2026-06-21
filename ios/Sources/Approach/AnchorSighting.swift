import Foundation

/// One sighting of an instrumented anchor (a printed coded sticker) in the camera frame, the unit of
/// the last-50-feet final approach. The payload is the label printed on the marker ("DOOR:room-214");
/// the bearing is the coarse third of the frame it sits in.
///
/// No distance is ever derived from vision: a vision distance is unreliable and a confident wrong one
/// is dangerous to a blind wearer who cannot catch it. `distanceMeters` is filled from the LiDAR band
/// at the marker when a depth frame is available, and is nil otherwise. This is the input to the
/// final-approach beacon, a later piece to be shaped with blind co-designers; it carries data only and
/// never drives the belt safety reflex. See ios/LAST-50-FEET-SCOPING.md.
struct AnchorSighting: Sendable, Equatable, Identifiable {
    var id: String { payload }

    /// The full decoded payload, e.g. "DOOR:room-214".
    let payload: String
    /// 0 at the far left of the upright frame, 1 at the far right: the marker's horizontal centroid.
    let centroidX: Double
    /// The decoder's confidence in this read, 0...1.
    let confidence: Double
    /// Coarse LiDAR distance to the marker's band, in meters. Nil when no depth was available. Never a
    /// vision-derived figure.
    var distanceMeters: Double?

    /// The "TYPE" half of a "TYPE:label" payload, or "" when there is no colon.
    var type: String {
        guard let colon = payload.firstIndex(of: ":") else { return "" }
        return String(payload[..<colon])
    }

    /// The "label" half of a "TYPE:label" payload, or the whole payload when there is no colon. This is
    /// what a spoken destination is matched against.
    var label: String {
        guard let colon = payload.firstIndex(of: ":") else { return payload }
        return String(payload[payload.index(after: colon)...])
    }

    /// Coarse bearing from the centroid: the third of the frame the marker sits in. Derived from the
    /// Vision upright frame (`boundingBox.midX` with orientation `.right`), the same convention
    /// `PersonDetector.horizontalNorm` uses. It is calibrated INDEPENDENTLY of the LiDAR
    /// `lidarBandsMirrored` flag, which only resolves the depth-buffer rows: flipping that flag does not
    /// re-orient anchor bearing. The on-device "hard left" check must confirm the anchor-bearing side as
    /// well as the LiDAR band side, since the two ride different calibrations.
    enum Bearing: String, Sendable { case left, center, right }
    var bearing: Bearing {
        centroidX < 0.34 ? .left : (centroidX > 0.66 ? .right : .center)
    }
}
