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

    // Navigation
    /// How close to a maneuver point counts as reaching it (advance to the next).
    static let maneuverArriveMeters = 2.0
    /// Virtual walking speed for the route simulator, meters per second.
    static let walkingSpeed = 1.3
}
