import Foundation

/// Single home for the tunable numbers so no magic values scatter across modules. Values come
/// from `docs/03-protocol.md`, `docs/04-phone-side.md`, the `docs/11-phone-app-design-spec.md`
/// build contract, and the proven `wand-phone-probe` sensor configuration.
enum CitrusSquadConfig {
    /// Distance before a maneuver at which a cue is staged. `docs/04` Maps integration.
    static let turnCommitMeters = 5.0
    /// Off-polyline distance that triggers a reroute. `docs/04` Maps integration.
    static let rerouteDeviationMeters = 25.0
    /// Heartbeat period. `docs/03` cadence.
    static let heartbeatMilliseconds = 100
    /// GPS poll rate. `docs/04`.
    static let gpsPollHz = 1.0
    /// CoreLocation heading filter. Proven in the probe's location service.
    static let headingFilterDegrees = 1.0
    /// CoreMotion update interval, 50 Hz. Proven in the probe's motion service.
    static let motionUpdateInterval = 0.02
    /// Deadband on adjacent quadrant transitions. `docs/04` quadrant mapping.
    static let hysteresisAdjacentDegrees = 5.0
    /// Deadband on the turn-around case. `docs/04` quadrant mapping.
    static let hysteresisTurnAroundDegrees = 10.0
    /// Default tap travel distance, LC2 byte 2. `docs/03`.
    static let intensityDefault: UInt8 = 192
    /// ESP32 falls back to quiet after this much silence. `docs/03` / `docs/06`, here for reference.
    static let linkSilenceTimeoutMilliseconds = 500

    // Perception / safety (docs/12)
    /// Fire the proximity cue inside this range. `docs/12` recommends ~1.8 m for demo lead time.
    static let proximityThresholdMeters = 1.8
    /// Distance at which the hazard tap is at full strength.
    static let dangerNearMeters = 0.5
    /// Lowest tap strength a graded hazard cue ever uses, so it is always felt.
    static let intensityFloor: UInt8 = 96

    // Vision person-in-path tier (docs/12 §6, mirrors the cv/ Python defaults)
    /// YOLO person-detection confidence floor. Cole's `cv/` default; err low, a missed person is
    /// worse than a false tap for a safety device.
    static let visionConfidenceThreshold: Float = 0.35
    /// Inner-crop fraction of the person box used to sample depth, dodging LiDAR edge bleed.
    static let depthCropRatio = 0.5
    /// Person detection rate. The decide loop stays at 10 Hz; running YOLO slower protects thermals.
    static let visionMaxHz = 4.0
    /// Frames a person must persist in range before the cue fires.
    static let visionSettleFrames = 3
    /// Distance band past the threshold that keeps a firing cue alive, to stop edge flicker.
    static let visionHysteresisMeters = 0.3
    /// Minimum time between cue fire-or-clear transitions.
    static let visionRefractorySeconds = 1.0

    // Obstacle avoidance (LiDAR safety layer, sits above navigation, below the person tier)
    /// Consecutive 10 Hz ticks an obstacle must persist before the avoidance cue activates.
    static let obstacleSettleTicks = 2
    /// Ticks a clear reading must persist before the avoidance cue releases, to stop flicker.
    static let obstacleHoldTicks = 3

    // Navigation
    /// How close to a maneuver point counts as reaching it (advance to the next).
    static let maneuverArriveMeters = 2.0
    /// Virtual walking speed for the route simulator, meters per second.
    static let walkingSpeed = 1.3

    // Path following (pure pursuit)
    /// How far ahead along the path the steering aims. Larger smooths the line and rounds corners
    /// sooner; smaller hugs the path more tightly but jitters. ~8 m suits a walking pace.
    static let lookAheadMeters = 8.0
    /// Heading swing between path segments that counts as a real corner (pivot) for the banner.
    static let pivotThresholdDegrees = 25.0
    /// Within this distance of the final point, the route is done and the belt cues `arrived`.
    static let pathArriveMeters = 4.0
    /// Off-path distance past which guidance steers back toward the line (and a reroute belongs).
    /// Reuses the existing reroute deviation budget.
    static let onPathToleranceMeters = rerouteDeviationMeters
}
