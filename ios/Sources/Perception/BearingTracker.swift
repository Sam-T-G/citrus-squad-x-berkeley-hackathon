import Foundation

/// A per-frame detection box, stripped to what the early-warning layer needs and nothing more.
///
/// Detector-agnostic on purpose. Map `PersonDetection` into this today (it already keeps the full
/// box), and map `CVDetection` into it the moment `ObjectDetectionService` lands. The tracker never
/// learns which detector fed it, so the signal proven against a walking person carries straight over
/// to poles and bollards with no change here.
///
/// `boxHeight` is the looming signal: the box's normalized vertical extent in the upright frame.
/// Height is steadier than width for tall thin objects (poles, people) and survives side-occlusion,
/// so it is the better expansion cue.
struct BoxObservation: Sendable, Equatable {
    var label: String
    var confidence: Double
    /// Box center, 0 at the far left of the upright frame, 1 at the far right.
    var horizontalNorm: Double
    /// Normalized vertical extent, 0...1. The looming / time-to-contact signal.
    var boxHeight: Double
}

/// How sure the layer is that this object will get in the wearer's way. Drives whether the soft
/// haptic fires and how the spoken line is phrased. It never escalates a hard stop: a stop is a
/// LiDAR-confidence decision, and this layer runs ahead of LiDAR by design.
enum InterferenceConfidence: Sendable, Equatable { case low, medium, high }

/// A pre-LiDAR collision warning: an object that is holding the wearer's heading (constant bearing)
/// and growing in the frame (looming). Both conditions together are the flag; either one alone is
/// a false positive (a far thing dead ahead, or a near thing drifting past).
struct InterferenceFlag: Sendable, Equatable {
    var label: String
    /// Belt side to cue. Centered is the only firing case today, so this is `.front`. Kept on the
    /// type so a future off-center variant has somewhere to land.
    var side: QuadrantMask
    /// Consecutive frames the object has held the center band under low self-rotation.
    var centeredFrames: Int
    /// Monocular time-to-contact in seconds, from the box expansion rate. Nil when not closing.
    var timeToContactSeconds: Double?
    var confidence: InterferenceConfidence
}

/// Threshold library for the early-warning layer, in the house style of `MotionParameters`: every
/// tunable number named in one place, no AI compensating for bad values. Tune against demo-site
/// footage, rebuild, re-test. The decision logic that reads these lives in `BearingTracker.evaluate`,
/// a pure static function, so each threshold's effect is unit-tested without a camera.
enum InterferenceParameters {
    // MARK: - Pipeline rate

    /// Frame rate the early-warning tracker runs at. Tied to the live person tier so the
    /// time-to-contact math uses the real elapsed time between processed frames. When
    /// `ObjectDetectionService` becomes the feeder (step 4), point this at its throttled rate.
    static let detectionHz: Double = CitrusSquadConfig.visionMaxHz

    // MARK: - Constant bearing (the "consistently in the middle" test)

    /// Half-width of the center band around 0.5. 1/6 makes the band the middle third of the frame,
    /// matching the left/center/right thirds the rest of the stack uses.
    static let centerHalfWidthNorm: Double = 1.0 / 6.0
    /// Consecutive centered frames (under the yaw gate) before constant bearing is trusted.
    static let heldFrames = 4
    /// Wearer yaw rate above which the frame is a head or body turn, so a centered reading is an
    /// artifact of self-rotation and does not count toward the streak. Radians per second.
    static let yawGateRadPerSecond: Double = 0.35

    // MARK: - Looming (the closing-distance test)

    /// Minimum relative box expansion per second to call an object closing. 0.06 means the box must
    /// grow ~6% per second, which screens out detector jitter on a stationary object.
    static let minLoomRatePerSecond: Double = 0.06
    /// Fire once time-to-contact drops under this. ~4 s is real lead time at a walking pace and well
    /// ahead of the ~5 m LiDAR horizon.
    static let ttcWarnSeconds: Double = 4.0
    /// Boxes shorter than this are too small for a stable expansion estimate; ignore them.
    static let minBoxHeight: Double = 0.05

    // MARK: - Track management

    /// Horizontal and height history length, in frames, for the expansion estimate.
    static let historyLength = 8
    /// Maximum normalized horizontal gap to match a new box to an existing track.
    static let matchRadiusNorm: Double = 0.15
    /// Frames without a match before a track is dropped.
    static let expiryFrames = 8
}

/// Tracks detection boxes across frames and flags the ones on a collision course before LiDAR has a
/// return. The signal is two monocular cues, neither needing depth:
///
/// 1. Constant bearing: a box whose center holds near the wearer's heading across frames is on a
///    collision course (the maritime "constant bearing, decreasing range" rule). Discounted while the
///    wearer is turning, since self-rotation slides everything sideways.
/// 2. Looming: the box growing in height means closing distance. Time-to-contact is size over the
///    rate of size growth, no depth required.
///
/// Centered AND looming together is the flag. The output is a soft, additive advisory: it buys lead
/// time, it never overrides or delays the LiDAR reflex or the depth collision cue. Same discipline as
/// the Claude path in `PERCEPTION-AVOIDANCE-HANDOFF.md`.
///
/// Concurrency: not actor-isolated. Store as `nonisolated(unsafe)` and call only from the ARKit
/// callback queue, the same serial-queue pattern as `MotionTracker` and `DepthService.frameTick`.
/// Only the `Sendable` `InterferenceFlag` values leave.
final class BearingTracker {

    // MARK: - Private state

    private struct Track {
        var label: String
        var confidence: Double
        /// Oldest to newest, capped at `historyLength`.
        var horizontalHistory: [Double]
        var heightHistory: [Double]
        /// Consecutive centered frames under the yaw gate.
        var centeredStreak: Int
        var framesTracked: Int
        var lastSeenFrame: Int
    }

    private var tracks: [Track] = []

    // MARK: - Frame update

    /// Feed the current frame's boxes plus the wearer's yaw rate. Returns one flag per object that
    /// currently meets the centered-and-looming bar. Call once per detection frame.
    func update(observations: [BoxObservation], yawRateRadPerSecond: Double,
                frameIndex: Int) -> [InterferenceFlag] {
        expireStale(currentFrame: frameIndex)

        let turning = abs(yawRateRadPerSecond) >= InterferenceParameters.yawGateRadPerSecond
        var matched = Set<Int>()
        var flags: [InterferenceFlag] = []

        for obs in observations where obs.boxHeight >= InterferenceParameters.minBoxHeight {
            let idx = bestMatch(for: obs, excluding: matched) ?? appendTrack(from: obs, frameIndex: frameIndex)
            matched.insert(idx)
            updateTrack(at: idx, with: obs, frameIndex: frameIndex, turning: turning)

            let t = tracks[idx]
            if let flag = Self.evaluate(label: t.label, centeredStreak: t.centeredStreak,
                                        heightHistory: t.heightHistory, framesTracked: t.framesTracked,
                                        hz: InterferenceParameters.detectionHz) {
                flags.append(flag)
            }
        }
        return flags
    }

    // MARK: - Matching

    private func bestMatch(for obs: BoxObservation, excluding: Set<Int>) -> Int? {
        var bestIdx: Int?
        var bestDistance = InterferenceParameters.matchRadiusNorm
        for (idx, track) in tracks.enumerated() {
            guard !excluding.contains(idx), track.label == obs.label else { continue }
            let d = abs((track.horizontalHistory.last ?? 0) - obs.horizontalNorm)
            if d < bestDistance {
                bestDistance = d
                bestIdx = idx
            }
        }
        return bestIdx
    }

    private func appendTrack(from obs: BoxObservation, frameIndex: Int) -> Int {
        tracks.append(Track(label: obs.label, confidence: obs.confidence,
                            horizontalHistory: [obs.horizontalNorm], heightHistory: [obs.boxHeight],
                            centeredStreak: 0, framesTracked: 1, lastSeenFrame: frameIndex))
        return tracks.count - 1
    }

    private func updateTrack(at idx: Int, with obs: BoxObservation, frameIndex: Int, turning: Bool) {
        tracks[idx].confidence = obs.confidence
        tracks[idx].lastSeenFrame = frameIndex
        tracks[idx].framesTracked += 1
        append(obs.horizontalNorm, to: &tracks[idx].horizontalHistory)
        append(obs.boxHeight, to: &tracks[idx].heightHistory)

        // A centered frame only counts toward the streak when the wearer is not turning, otherwise
        // the centering is an artifact of self-rotation. A turn or a drift off-center resets it.
        if !turning && Self.isCentered(obs.horizontalNorm) {
            tracks[idx].centeredStreak += 1
        } else {
            tracks[idx].centeredStreak = 0
        }
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > InterferenceParameters.historyLength { history.removeFirst() }
    }

    private func expireStale(currentFrame: Int) {
        tracks.removeAll { currentFrame - $0.lastSeenFrame > InterferenceParameters.expiryFrames }
    }

    // MARK: - Pure decision logic (unit tested)

    /// Whether a box center sits inside the center band.
    static func isCentered(_ horizontalNorm: Double) -> Bool {
        abs(horizontalNorm - 0.5) <= InterferenceParameters.centerHalfWidthNorm
    }

    /// Relative box expansion per second, the looming rate. Positive means growing (closing). Uses
    /// the log-derivative (`ln(last / first) / elapsed`) so a steady approach reads the same rate no
    /// matter how full the history window is, which a plain `(last - first) / last` would not. Its
    /// reciprocal is the time-to-contact. Nil with too little history.
    static func loomRatePerSecond(heightHistory: [Double], hz: Double) -> Double? {
        guard heightHistory.count >= 2, hz > 0,
              let first = heightHistory.first, let last = heightHistory.last,
              first > 0, last > 0 else { return nil }
        let elapsed = Double(heightHistory.count - 1) / hz
        guard elapsed > 0 else { return nil }
        return log(last / first) / elapsed
    }

    /// The flag decision. A track fires only when it has held constant bearing for `heldFrames` and
    /// is looming fast enough that time-to-contact is inside the warn window. Either cue alone returns
    /// nil. Pure, so every threshold's effect is testable without a camera.
    static func evaluate(label: String, centeredStreak: Int, heightHistory: [Double],
                         framesTracked: Int, hz: Double) -> InterferenceFlag? {
        guard centeredStreak >= InterferenceParameters.heldFrames else { return nil }
        guard let loom = loomRatePerSecond(heightHistory: heightHistory, hz: hz),
              loom >= InterferenceParameters.minLoomRatePerSecond else { return nil }

        let ttc = 1.0 / loom                       // tau: size over rate-of-growth
        guard ttc <= InterferenceParameters.ttcWarnSeconds else { return nil }

        return InterferenceFlag(label: label, side: .front, centeredFrames: centeredStreak,
                                timeToContactSeconds: ttc,
                                confidence: confidence(centeredStreak: centeredStreak, ttc: ttc))
    }

    /// Confidence scales with how long the bearing has held and how short the contact time is. The
    /// reasoning tier and the spoken phrasing lean on this: a low-confidence flag says "something
    /// ahead," a high-confidence one names a closing object.
    static func confidence(centeredStreak: Int, ttc: Double) -> InterferenceConfidence {
        let held = centeredStreak >= InterferenceParameters.heldFrames * 2
        let close = ttc <= InterferenceParameters.ttcWarnSeconds / 2
        switch (held, close) {
        case (true, true): return .high
        case (false, false): return .low
        default: return .medium
        }
    }
}
