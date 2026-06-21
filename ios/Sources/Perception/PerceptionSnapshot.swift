import Foundation

/// The structured scene at one instant, the context the Claude tier reasons over instead of a raw
/// frame. This is the piece `docs/14` flagged as its top blocker (blindspot #3) and
/// `PERCEPTION-AVOIDANCE-HANDOFF.md` §C specifies.
///
/// A pure `Sendable` value, assembled on the main actor from state that already exists: the LiDAR
/// band distances (ground truth for distance), the current fused vision hazard (what is ahead and on
/// which side), and the route context. It carries only what the sensors actually reported, so the
/// verifier can reject any spoken line the data does not support.
///
/// What it cannot fill yet: rich per-band object lists with motion. Those arrive with the YOLO-World
/// and `MotionTracker` merge (handoff Part B/C); the `Band.objects` array is shaped for them now and
/// holds at most the one fused hazard until then.
struct PerceptionSnapshot: Sendable {
    /// One detected object in a band. `motionState` is `unknown` until the motion tracker lands.
    struct ObjectSummary: Sendable, Equatable {
        var label: String
        var distanceMeters: Double      // -1 when unknown
        var motionState: MotionState
    }

    enum MotionState: String, Sendable { case unknown, stationary, approaching, receding, moving }

    /// A horizontal third of the scene. `nearestMeters` is the LiDAR floor for that third.
    struct Band: Sendable, Equatable {
        var nearestMeters: Double       // -1 when no valid return
        var objects: [ObjectSummary] = []
    }

    /// The route picture, read through `RouteEngine`'s already-published state.
    struct RouteContext: Sendable, Equatable {
        var nextTurn: String            // "left" / "right" / "straight" / "arriving" / "u-turn"
        var distanceToNextMeters: Double
        var remainingMeters: Double
        var onRoute: Bool
    }

    enum Confidence: String, Sendable { case low, medium, high }

    var left: Band
    var center: Band
    var right: Band
    var route: RouteContext?
    var confidence: Confidence

    // MARK: - Assembly

    /// Build the snapshot from the state the app already holds. Pure, so it is unit-testable without a
    /// device. `hazard` is the current fused vision/LiDAR hazard (nil when nothing is flagged); it is
    /// binned into a band by its side mask. `cameraRunning` is `DepthService.isRunning`: when the
    /// camera is off, distances are stale and confidence drops to `low`.
    static func make(bands: BandDepths,
                     hazard: Hazard?,
                     route: RouteContext?,
                     cameraRunning: Bool) -> PerceptionSnapshot {
        var left = Band(nearestMeters: bands.left)
        var center = Band(nearestMeters: bands.center)
        var right = Band(nearestMeters: bands.right)

        if let hazard, let summary = objectSummary(for: hazard) {
            // The tap is on the hazard's side (docs/12). A mask with no left/right reads as straight
            // ahead, so it goes in the center band.
            if hazard.mask.contains(.left) {
                left.objects.append(summary)
            } else if hazard.mask.contains(.right) {
                right.objects.append(summary)
            } else {
                center.objects.append(summary)
            }
        }

        return PerceptionSnapshot(left: left, center: center, right: right, route: route,
                                  confidence: confidence(bands: bands, cameraRunning: cameraRunning))
    }

    private static func objectSummary(for hazard: Hazard) -> ObjectSummary? {
        let label = hazard.isPerson ? "person" : (hazard.label ?? "obstacle")
        return ObjectSummary(label: label, distanceMeters: hazard.distanceMeters, motionState: .unknown)
    }

    /// Bias confidence low when the camera is off or LiDAR returns are sparse, high when every band
    /// has a valid distance. A low-confidence snapshot tells the verifier to hedge rather than claim a
    /// clear path the data does not support.
    private static func confidence(bands: BandDepths, cameraRunning: Bool) -> Confidence {
        guard cameraRunning else { return .low }
        let valid = [bands.left, bands.center, bands.right].filter { $0 > 0 }.count
        switch valid {
        case 3: return .high
        case 1, 2: return .medium
        default: return .low
        }
    }

    // MARK: - Serialization

    /// Serialize to XML-tagged input, not prose, so the model reads structure (Anthropic prompt
    /// guidance). This is the literal context string handed to the draft and verify calls. Distances
    /// are rounded to a tenth of a meter; an unknown distance is omitted rather than sent as -1.
    func xmlForClaude() -> String {
        var lines: [String] = ["<scene confidence=\"\(confidence.rawValue)\">"]
        lines.append(bandXML(name: "left", band: left))
        lines.append(bandXML(name: "center", band: center))
        lines.append(bandXML(name: "right", band: right))
        if let route {
            lines.append("  <route next_turn=\"\(route.nextTurn)\"" +
                         metersAttr(" distance_to_turn_m", route.distanceToNextMeters) +
                         metersAttr(" remaining_m", route.remainingMeters) +
                         " on_route=\"\(route.onRoute)\" />")
        }
        lines.append("</scene>")
        return lines.joined(separator: "\n")
    }

    private func bandXML(name: String, band: Band) -> String {
        var attrs = ""
        if band.nearestMeters > 0 {
            attrs = " nearest_m=\"\(rounded(band.nearestMeters))\""
        }
        guard !band.objects.isEmpty else { return "  <band side=\"\(name)\"\(attrs) />" }
        var out = "  <band side=\"\(name)\"\(attrs)>"
        for object in band.objects {
            out += "\n    <object label=\"\(object.label)\" motion=\"\(object.motionState.rawValue)\"" +
                   metersAttr(" distance_m", object.distanceMeters) + " />"
        }
        out += "\n  </band>"
        return out
    }

    private func metersAttr(_ name: String, _ meters: Double) -> String {
        meters > 0 ? "\(name)=\"\(rounded(meters))\"" : ""
    }

    private func rounded(_ meters: Double) -> String {
        String(format: "%.1f", meters)
    }
}
