import Foundation

/// A body-forward, true-north heading plus where it came from. The live cue path steers off `degrees`.
struct ResolvedHeading: Equatable, Sendable {
    enum Source: String, Sendable { case course, compass }
    var degrees: Double
    var source: Source
}

/// Picks the most reliable body-forward heading from the phone's two independent sources.
///
/// The product is a torso belt full of vibration motors (permanent magnets) right next to the phone,
/// which biases the magnetometer by tens of degrees and drifts it as the motors fire. So while the
/// wearer is moving, this prefers GPS course over ground: the true-north direction of actual travel,
/// derived from position deltas, immune to magnetic interference, and needing no calibration. The
/// compass is the fallback for when the wearer is stopped (course needs motion to be valid), and only
/// when it reports a usable accuracy.
///
/// Pure and static, like `Bearing`, so every gate is unit-tested with no device. This is the fix for
/// the live-mode heading bug: the old path subtracted the absolute compass heading captured at
/// calibration from an absolute route bearing, injecting a constant rotation that steered the wearer
/// off the sidewalk. Here the live heading is already body-forward true north, so no offset is applied.
enum HeadingResolver {
    struct Config: Sendable {
        /// Minimum ground speed (m/s) for GPS course to be trusted. Below this the wearer is standing
        /// or shuffling and course is noise.
        var minSpeedMetersPerSecond: Double
        /// Reject course readings worse than this (degrees). A negative course accuracy means the
        /// platform did not supply one; the speed gate alone then decides.
        var maxCourseAccuracyDegrees: Double
        /// Reject compass readings worse than this (degrees). The belt can push the magnetometer past
        /// it, in which case a stopped wearer simply gets no heading until they move again.
        var maxHeadingAccuracyDegrees: Double

        static let `default` = Config(
            minSpeedMetersPerSecond: CitrusSquadConfig.courseMinSpeedMetersPerSecond,
            maxCourseAccuracyDegrees: CitrusSquadConfig.courseMaxAccuracyDegrees,
            maxHeadingAccuracyDegrees: CitrusSquadConfig.headingMaxAccuracyDegrees)
    }

    /// Resolve a body-forward heading, or nil when neither source is trustworthy (the caller holds its
    /// last good heading rather than steering off noise).
    ///
    /// - Parameter mountOffset: the fixed phone-to-body rotation for the compass fallback. Zero for a
    ///   forward-facing mount. This is NOT the absolute calibration heading the old path subtracted;
    ///   feeding an absolute heading here is exactly the bug that steered the wearer into the street.
    static func resolve(course: Double, courseAccuracy: Double, speed: Double,
                        trueHeading: Double, headingAccuracy: Double,
                        mountOffset: Double = 0,
                        config: Config = .default) -> ResolvedHeading? {
        // Moving: trust GPS course. It is the true-north travel direction and ignores the magnetometer.
        let courseUsable = speed >= config.minSpeedMetersPerSecond
            && course >= 0
            && (courseAccuracy < 0 || courseAccuracy <= config.maxCourseAccuracyDegrees)
        if courseUsable {
            return ResolvedHeading(degrees: Bearing.normalize(course), source: .course)
        }

        // Stopped or course unavailable: fall back to the compass, corrected only by the mount
        // rotation, and only when its accuracy is usable.
        let compassUsable = trueHeading >= 0
            && headingAccuracy >= 0
            && headingAccuracy <= config.maxHeadingAccuracyDegrees
        if compassUsable {
            return ResolvedHeading(degrees: Bearing.bodyHeading(phoneTrueHeading: trueHeading,
                                                                calibrationOffset: mountOffset),
                                   source: .compass)
        }
        return nil
    }
}
