import Foundation

/// Captures the phone-to-body mount offset for the compass by walking, not by aiming. While the wearer
/// takes a few steps, it pairs each GPS course (the true travel direction) with the compass reading
/// and, once they agree, locks the offset = compass minus course. Anchoring to GPS course means there
/// is no aiming step to get wrong, and the single offset folds in both the mount angle and the current
/// magnetic bias from the belt's motors. `HeadingResolver` then applies it to the compass fallback, so
/// even a standing wearer steers true and the demo never opens on a few-degrees-off heading.
///
/// Pure value type, like `Bearing` and `HeadingResolver`: feed it telemetry, read its state, every gate
/// unit-tested with no device.
struct HeadingCalibrator: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Gathering consistent walking samples. `progress` counts toward `Config.samplesNeeded`.
        case collecting(progress: Int)
        /// Locked: the mount offset in degrees is ready for the compass fallback.
        case locked(offsetDegrees: Double)
    }

    struct Config: Equatable, Sendable {
        /// Below this ground speed (m/s) a sample is not from real walking, so it is ignored.
        var minSpeedMetersPerSecond: Double
        /// Reject course readings worse than this (degrees); negative accuracy is treated as unknown.
        var maxCourseAccuracyDegrees: Double
        /// Reject compass readings worse than this (degrees).
        var maxHeadingAccuracyDegrees: Double
        /// Walking samples (at the decide-loop rate) needed before a lock.
        var samplesNeeded: Int
        /// Maximum spread among the samples to accept a lock, so it locks on a straight settled walk
        /// and not mid-turn.
        var consistencyToleranceDegrees: Double

        static let `default` = Config(
            minSpeedMetersPerSecond: CitrusSquadConfig.courseMinSpeedMetersPerSecond,
            maxCourseAccuracyDegrees: CitrusSquadConfig.courseMaxAccuracyDegrees,
            maxHeadingAccuracyDegrees: CitrusSquadConfig.headingMaxAccuracyDegrees,
            samplesNeeded: CitrusSquadConfig.calibrationSamplesNeeded,
            consistencyToleranceDegrees: CitrusSquadConfig.calibrationConsistencyDegrees)
    }

    var config: Config = .default
    private(set) var state: State = .collecting(progress: 0)
    /// Recent compass-minus-course candidates, newest last, capped at `samplesNeeded`.
    private var candidates: [Double] = []
    /// True only after a confident walking lock. A provisional (manual) lock leaves this false so the
    /// walk can still refine the offset; a refined lock is final.
    private var refined = false

    var isLocked: Bool { if case .locked = state { return true } else { return false } }
    /// Locked, but on the provisional (compass-as-forward) offset, still open to a walking refinement.
    var isProvisional: Bool { isLocked && !refined }
    var mountOffset: Double? { if case .locked(let offset) = state { return offset } else { return nil } }
    /// 0...1 toward a lock, for a progress readout.
    var progress: Double {
        switch state {
        case .locked: return 1
        case .collecting(let n): return min(1, Double(n) / Double(max(1, config.samplesNeeded)))
        }
    }

    /// Feed one frame of telemetry. Adds a sample only while the wearer is moving with both sensors
    /// usable; otherwise it holds, so a pause between steps does not lose progress. Locks once the
    /// window is full and the samples agree (a straight, settled walk), so it never locks mid-turn.
    mutating func ingest(course: Double, courseAccuracy: Double, speed: Double,
                         trueHeading: Double, headingAccuracy: Double) {
        // A refined (walked) lock is final. A provisional lock keeps gathering so the walk can upgrade
        // it to the accurate offset, and a plain collecting state gathers as before.
        if refined { return }

        let usable = speed >= config.minSpeedMetersPerSecond
            && course >= 0 && (courseAccuracy < 0 || courseAccuracy <= config.maxCourseAccuracyDegrees)
            && trueHeading >= 0 && headingAccuracy >= 0 && headingAccuracy <= config.maxHeadingAccuracyDegrees
        guard usable else { return }

        candidates.append(Bearing.normalize(trueHeading - course))
        if candidates.count > config.samplesNeeded { candidates.removeFirst() }

        if candidates.count >= config.samplesNeeded,
           Self.spread(candidates) <= config.consistencyToleranceDegrees {
            state = .locked(offsetDegrees: Self.circularMean(candidates))
            refined = true
        } else if !isLocked {
            // Hold a provisional lock while gathering; only advance the progress when not yet locked.
            state = .collecting(progress: candidates.count)
        }
    }

    /// Restart calibration (the Recalibrate action, or the start of a fresh live walk).
    mutating func reset() {
        candidates.removeAll()
        refined = false
        state = .collecting(progress: 0)
    }

    /// Lock immediately on a provisional mount offset so live cues flow at once, indoors or on the
    /// bench, where the walk-based lock can never gather GPS-course samples. The default offset of 0
    /// trusts the compass as body-forward. Stays provisional: a later straight walk refines it to the
    /// accurate offset (which also folds in the belt's magnetic bias) with no further action.
    mutating func lockManually(offsetDegrees: Double = 0) {
        state = .locked(offsetDegrees: offsetDegrees)
        refined = false
    }

    // MARK: - Circular statistics (pure, unit tested)

    /// The mean of angles, by averaging their unit vectors, so it is correct across the 0/360 wrap.
    static func circularMean(_ degrees: [Double]) -> Double {
        guard !degrees.isEmpty else { return 0 }
        var x = 0.0, y = 0.0
        for d in degrees {
            let r = d * .pi / 180
            x += cos(r)
            y += sin(r)
        }
        return Bearing.normalize(atan2(y, x) * 180 / .pi)
    }

    /// The largest angular deviation of any sample from the circular mean, in degrees.
    static func spread(_ degrees: [Double]) -> Double {
        guard degrees.count > 1 else { return 0 }
        let mean = circularMean(degrees)
        return degrees.map { abs(angularDifference($0, mean)) }.max() ?? 0
    }

    /// The signed smallest angle from `b` to `a`, folded into (-180, 180].
    static func angularDifference(_ a: Double, _ b: Double) -> Double {
        var diff = (a - b).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return diff
    }
}
