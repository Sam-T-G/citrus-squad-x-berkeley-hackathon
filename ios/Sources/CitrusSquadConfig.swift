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
    /// Consecutive 10 Hz ticks a new turn band must persist before the belt switches to it, on top of
    /// the boundary hysteresis. Smooths single-frame heading spikes; ~300 ms, short enough that a real
    /// turn still feels immediate. Navigation only: the hazard tiers preempt this and stay instant.
    static let navCueDwellTicks = 3
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
    /// COCO classes the vision tier treats as in-path hazards. Kept in lockstep with
    /// `NAVIGATION_CLASSES` in `cv/detection.py` so the on-device filter and Cole's proven Python
    /// pipeline recognize the same things. The label is the only thing that varies by class: the
    /// gate, depth fusion, and intensity math downstream key on distance and side, not on identity,
    /// so widening this set never changes the safety behavior, only what the overlay, the
    /// diagnostics console, and the spoken tier can name. COCO-native candidates not yet enabled
    /// here (add to both lists together): `handbag`, `train`.
    static let visionNavigationClasses: Set<String> = [
        "person", "bicycle", "car", "motorcycle", "bus", "truck",
        "chair", "couch", "dining table", "bed",
        "stop sign", "traffic light", "fire hydrant", "parking meter", "bench", "potted plant",
        "dog", "cat", "backpack", "suitcase", "umbrella",
    ]

    // Claude reasoning tier (off the belt safety path; see AI-USAGE-AUDIT-AND-EXPANSION.md)
    /// Drafts a spoken line fast and cheap. The line is never trusted until the verifier checks it
    /// against the snapshot, so a fast model is the right call here.
    static let claudeDraftModel = "claude-haiku-4-5"
    /// Verifies the drafted line against the structured snapshot and rejects anything the data does
    /// not support. Stronger than the drafter, still well under a second on a one-sentence check.
    static let claudeVerifyModel = "claude-sonnet-4-6"
    /// Reads small text in a single camera frame (street signs, bus numbers, posted notices). Opus
    /// has the high-resolution vision the cheaper models lack for fine print.
    static let claudeVisionModel = "claude-opus-4-8"
    /// Output cap for the spoken tier. One sentence of speech is well under this; it only guards
    /// against a runaway response, and keeps the call non-streaming and fast.
    static let claudeMaxTokens = 320
    /// Default ceiling on a Claude call before the caller gives up and speaks the grounded fallback.
    /// The belt already tapped from on-device geometry, so a slow line is dropped, never blocking.
    /// Used by the manual HUD buttons, which can afford to wait a little longer than the live voice.
    static let claudeTimeoutSeconds = 6.0
    /// Tight ceiling for the live voice describe path (Tier 2). The Deepgram agent is holding the turn
    /// open while this runs, so it must come back fast or fall back to the instant grounded line.
    static let claudeVoiceTimeoutSeconds = 2.5
    /// Ceiling for the live voice vision reads (Tier 3: read a sign, find an entrance). Longer than the
    /// describe budget because a vision read is a deliberate "look for me" the wearer waits a beat for,
    /// and a real read beats a fast "I couldn't see it."
    static let claudeVisionTimeoutSeconds = 5.0

    // Obstacle avoidance (LiDAR safety layer, sits above navigation, below the person tier)
    /// Consecutive 10 Hz ticks an obstacle must persist before the avoidance cue activates.
    static let obstacleSettleTicks = 2
    /// Ticks a clear reading must persist before the avoidance cue releases, to stop flicker.
    static let obstacleHoldTicks = 3
    /// A side needs at least this much clearance to count as a way through. With the path ahead
    /// blocked and both sides closer than this, the layer stops instead of steering. Below the
    /// detection threshold, so a side can have a return and still be passable.
    static let avoidanceMinSideClearance = 1.0

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

    // Heading resolution (live walk). The belt's motors are magnets right next to the phone, so GPS
    // course over ground is preferred over the magnetometer while moving. See `HeadingResolver`.
    /// Minimum ground speed (m/s) before GPS course is trusted as the body heading. Normal walking
    /// stays above this; standing or shuffling drops below it and the compass takes over.
    static let courseMinSpeedMetersPerSecond = 0.5
    /// Reject GPS course readings worse than this (degrees). Negative course accuracy is treated as
    /// "unknown" and the speed gate decides.
    static let courseMaxAccuracyDegrees = 30.0
    /// Reject magnetometer readings worse than this (degrees). The belt can push the compass past it.
    static let headingMaxAccuracyDegrees = 25.0

    // Heading calibration (the walk-to-calibrate flow). See `HeadingCalibrator`.
    /// Walking samples at the 10 Hz decide rate before the mount offset locks. ~2 s of steady walking.
    static let calibrationSamplesNeeded = 20
    /// Maximum spread (degrees) among the samples to accept a lock, so it locks on a straight settled
    /// walk and not mid-turn. The circular mean averages out per-sample noise well inside this.
    static let calibrationConsistencyDegrees = 25.0
}
