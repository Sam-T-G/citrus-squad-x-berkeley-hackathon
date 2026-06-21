import Foundation

/// Classification of an object's movement relative to the wearer.
enum MotionState: Sendable, Equatable {
    /// Not enough history to classify yet (< settleFrames).
    case unknown
    /// Negligible change in position or depth across recent frames.
    case stationary
    /// Moving laterally but not closing distance.
    case moving
    /// Distance decreasing at or above threshold — highest priority for belt + Claude.
    case approaching
    /// Distance increasing — lower priority, may be ignored.
    case receding
}

/// A YOLO detection enriched with per-object motion history.
/// Produced by `MotionTracker.update(detections:frameIndex:)` each pipeline frame.
struct TrackedObject: Sendable {
    var label: String
    var confidence: Float
    var horizontalNorm: Double
    var distanceMeters: Double
    var motionState: MotionState
    /// Positive = approaching (distance decreasing). m/s. Zero until history is long enough.
    var approachRateMetersPerSecond: Double
    /// Lateral speed in normalized screen units per second. Sign = direction (pos = right).
    var lateralRateNormPerSecond: Double
    /// How many consecutive frames this object identity has been matched.
    var framesTracked: Int
}

/// Parameter library for motion classification.
///
/// Mirrors the Mira parameter-based approach: explicit named thresholds, no AI, fully
/// testable by setting values here and checking `MotionTracker` outputs against recordings.
/// Tune against real demo-site footage. Do not rely on AI/ML to compensate for bad thresholds.
enum MotionParameters {
    // MARK: - Classification thresholds

    /// Minimum depth decrease per second (m/s) to call an object approaching.
    /// ~0.15 m/s = a slow walk toward the wearer at 5 m.
    static let approachThresholdMetersPerSecond: Double = 0.15

    /// Minimum lateral displacement per second (norm/s) to call an object moving (not stationary).
    /// 0.04 norm/s at 5 Hz = 0.008 norm per frame = barely perceptible shift.
    static let lateralThresholdNormPerSecond: Double = 0.04

    // MARK: - Settle filter

    /// Consecutive frames a candidate motion state must hold before it is confirmed.
    /// Prevents single-frame jitter from flipping the classification.
    static let settleFrames = 3

    // MARK: - Track management

    /// Frames without a matching detection before a track is dropped.
    static let expiryFrames = 8

    /// Maximum normalized horizontal gap to match a new detection to an existing track.
    /// Set wide enough for a walking person but narrow enough to avoid swapping two adjacent people.
    static let matchRadiusNorm: Double = 0.15

    /// Depth and horizontal history length (in frames) for velocity averaging.
    static let historyLength = 6

    // MARK: - Approach urgency

    /// Approach rate (m/s) that jumps a tracked object to urgent — passed to CollisionPredictor.
    static let urgentApproachRateMetersPerSecond: Double = 0.6

    // MARK: - Pipeline rate

    /// Frame rate of the detection pipeline (ObjectDetectionService throttles to 1-in-2 of DepthService's 10 Hz).
    static let detectionHz: Double = 5.0
}
