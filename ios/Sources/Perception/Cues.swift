import Foundation

/// A sensed hazard from any source: LiDAR depth today, Cole's OpenCV detector next, a network
/// feed after that. A value type so it crosses isolation boundaries freely.
struct Hazard: Sendable, Equatable {
    enum Kind: Sendable {
        case obstacle   // raw proximity, emits LC2 0x40 obstacle-near
        case person     // person-in-path, emits LC2 0x10 vision-danger
    }

    var kind: Kind
    /// Which side the hazard is on. `docs/12` convention: the tap is on the hazard's side.
    var mask: QuadrantMask
    /// Distance in meters if known, used for intensity grading. -1 if unknown.
    var distanceMeters: Double = -1

    var event: LC2Event {
        switch kind {
        case .obstacle: return .obstacleNear
        case .person: return .visionDanger
        }
    }
}

/// Anything that can report the current hazard, polled once per tick by `AppModel`.
///
/// This is the input endpoint. `DepthService` conforms today. Cole's OpenCV object detector
/// conforms as a drop-in: build a class that produces a `Hazard?` and the arbitration picks it up
/// alongside LiDAR with no change to the core loop. `VisionHazardSource` is the ready-made shell.
@MainActor
protocol HazardSource: AnyObject {
    var currentHazard: Hazard? { get }
}

/// The single cue the system decided to emit this tick, after safety-over-direction arbitration.
/// This is what every output consumes, so the belt, the audio layer, and any logger all see the
/// exact same decision.
struct ResolvedCue: Sendable, Equatable {
    enum Source: String, Sendable { case hazard, turn, idle }

    var event: LC2Event
    var mask: QuadrantMask
    var intensity: UInt8
    var source: Source

    static let idle = ResolvedCue(event: .idle, mask: [], intensity: 0, source: .idle)

    /// Distance-graded tap strength per `docs/12`: closer means a harder tap, floored so it is
    /// always felt. Falls back to the flat default when distance is unknown.
    static func intensity(forDistance distance: Double) -> UInt8 {
        guard distance > 0 else { return WANDConfig.intensityDefault }
        let near = WANDConfig.dangerNearMeters
        let far = WANDConfig.proximityThresholdMeters
        if distance <= near { return 255 }
        if distance >= far { return WANDConfig.intensityFloor }
        let t = (distance - near) / (far - near)          // 0 at near, 1 at far
        let value = 255.0 - t * Double(255 - Int(WANDConfig.intensityFloor))
        return UInt8(min(255, max(Double(WANDConfig.intensityFloor), value)))
    }
}

/// Anything that consumes the resolved cue each tick: the belt transmitter, audio, logging.
///
/// This is the output endpoint. Josh's audio layer conforms as a drop-in: build a class that
/// reacts to `emit(_:)` and register it, and it receives every decided cue without touching the
/// core loop. `AudioCueSink` is the ready-made shell.
@MainActor
protocol CueSink: AnyObject {
    func emit(_ cue: ResolvedCue)
}
