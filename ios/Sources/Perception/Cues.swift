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
    /// The detected object class for a vision hazard (`person`, `backpack`, `bed`, ...), when the
    /// detector knows it. Drives what the demo and the spoken tier say; nil for a raw LiDAR obstacle.
    var label: String? = nil

    var event: LC2Event {
        switch kind {
        case .obstacle: return .obstacleNear
        case .person: return .visionDanger
        }
    }

    /// True only when the detector actually recognized a person, not just any in-path object. The
    /// vision tier fires the same belt cue for any close navigation-class object, so the wire event
    /// stays `visionDanger`; this only governs whether the demo and voice say "person."
    var isPerson: Bool { label?.lowercased() == "person" }
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
    enum Source: String, Sendable { case hazard, turn, earlyWarning, idle }

    var event: LC2Event
    var mask: QuadrantMask
    var intensity: UInt8
    var source: Source
    /// The detected object class behind a vision hazard, carried so the demo and the spoken tier can
    /// name what is ahead ("person", "backpack", ...) instead of always saying "person". Nil for turn,
    /// LiDAR, idle, and early-warning cues.
    var label: String? = nil

    static let idle = ResolvedCue(event: .idle, mask: [], intensity: 0, source: .idle)

    /// The soft pre-LiDAR heads-up from the early-warning tier: a gentle tap on the Front motor for
    /// an object holding the wearer's heading and looming before LiDAR has a return. It rides the
    /// existing vision-danger wire event so the firmware needs no new code, but carries the
    /// `.earlyWarning` source so audio and the UI render it as an advisory rather than a confirmed
    /// person. Floored intensity per `docs/12`, so it is felt but clearly gentler than a graded
    /// hazard, and it is arbitrated below the person and LiDAR tiers so it never masks a real cue.
    static let earlyWarning = ResolvedCue(event: .visionDanger, mask: .front,
                                          intensity: CitrusSquadConfig.intensityFloor, source: .earlyWarning)

    /// Distance-graded tap strength per `docs/12`: closer means a harder tap, floored so it is
    /// always felt. Falls back to the flat default when distance is unknown.
    static func intensity(forDistance distance: Double) -> UInt8 {
        guard distance > 0 else { return CitrusSquadConfig.intensityDefault }
        let near = CitrusSquadConfig.dangerNearMeters
        let far = CitrusSquadConfig.proximityThresholdMeters
        if distance <= near { return 255 }
        if distance >= far { return CitrusSquadConfig.intensityFloor }
        let t = (distance - near) / (far - near)          // 0 at near, 1 at far
        let value = 255.0 - t * Double(255 - Int(CitrusSquadConfig.intensityFloor))
        return UInt8(min(255, max(Double(CitrusSquadConfig.intensityFloor), value)))
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
