import Testing
@testable import CitrusSquad

/// The live-heading resolver's gates, proven without a device. The contract: GPS course wins while
/// moving, the compass fills in when stopped, bad accuracy is rejected, and the resolved value is a
/// body-forward true-north heading with no absolute-calibration rotation baked in (the old bug).
struct HeadingResolverTests {

    private let cfg = HeadingResolver.Config(minSpeedMetersPerSecond: 0.5,
                                             maxCourseAccuracyDegrees: 30,
                                             maxHeadingAccuracyDegrees: 25)

    @Test func movingUsesGpsCourse() {
        let r = HeadingResolver.resolve(course: 90, courseAccuracy: 5, speed: 1.3,
                                        trueHeading: 200, headingAccuracy: 10, config: cfg)
        #expect(r == ResolvedHeading(degrees: 90, source: .course))
    }

    @Test func stoppedFallsBackToCompass() {
        let r = HeadingResolver.resolve(course: 90, courseAccuracy: 5, speed: 0.1,
                                        trueHeading: 200, headingAccuracy: 10, config: cfg)
        #expect(r == ResolvedHeading(degrees: 200, source: .compass))
    }

    @Test func movingButInvalidCourseFallsBackToCompass() {
        let r = HeadingResolver.resolve(course: -1, courseAccuracy: -1, speed: 1.3,
                                        trueHeading: 200, headingAccuracy: 10, config: cfg)
        #expect(r == ResolvedHeading(degrees: 200, source: .compass))
    }

    @Test func courseWithUnknownAccuracyStillUsedWhenMoving() {
        // courseAccuracy < 0 means the platform gave none; the speed gate alone decides.
        let r = HeadingResolver.resolve(course: 45, courseAccuracy: -1, speed: 1.3,
                                        trueHeading: 200, headingAccuracy: 10, config: cfg)
        #expect(r?.source == .course)
        #expect(r?.degrees == 45)
    }

    @Test func badCourseAccuracyWhileMovingFallsBackToCompass() {
        let r = HeadingResolver.resolve(course: 45, courseAccuracy: 80, speed: 1.3,
                                        trueHeading: 200, headingAccuracy: 10, config: cfg)
        #expect(r == ResolvedHeading(degrees: 200, source: .compass))
    }

    @Test func badCompassAccuracyWhileStoppedReturnsNil() {
        let r = HeadingResolver.resolve(course: -1, courseAccuracy: -1, speed: 0.0,
                                        trueHeading: 200, headingAccuracy: 40, config: cfg)
        #expect(r == nil)
    }

    @Test func bothUnusableReturnsNil() {
        let r = HeadingResolver.resolve(course: -1, courseAccuracy: -1, speed: 0.0,
                                        trueHeading: -1, headingAccuracy: -1, config: cfg)
        #expect(r == nil)
    }

    // The regression guard for the original bug: the compass path applies only the mount rotation,
    // not an absolute heading. With a forward mount (offset 0), body heading equals the true heading,
    // so a wearer facing east reads 90, not 90 minus their calibration facing.
    @Test func compassPathDoesNotRotateByAbsoluteHeading() {
        let r = HeadingResolver.resolve(course: -1, courseAccuracy: -1, speed: 0.0,
                                        trueHeading: 90, headingAccuracy: 10, mountOffset: 0, config: cfg)
        #expect(r == ResolvedHeading(degrees: 90, source: .compass))
    }

    @Test func compassPathAppliesMountOffsetOnly() {
        // A 30 degree mount rotation: phone reads 120, body forward is 90.
        let r = HeadingResolver.resolve(course: -1, courseAccuracy: -1, speed: 0.0,
                                        trueHeading: 120, headingAccuracy: 10, mountOffset: 30, config: cfg)
        #expect(r == ResolvedHeading(degrees: 90, source: .compass))
    }
}
