import Testing
@testable import CitrusSquad

/// The walk-to-calibrate logic, proven without a device. The contract: a steady straight walk locks an
/// offset equal to compass-minus-course, a turn does not lock, standing still makes no progress, and
/// the circular math is correct across the 0/360 wrap.
struct HeadingCalibratorTests {

    private let cfg = HeadingCalibrator.Config(minSpeedMetersPerSecond: 0.5,
                                               maxCourseAccuracyDegrees: 30,
                                               maxHeadingAccuracyDegrees: 25,
                                               samplesNeeded: 10,
                                               consistencyToleranceDegrees: 20)

    private func walk(_ calibrator: inout HeadingCalibrator, course: Double, compass: Double, frames: Int) {
        for _ in 0..<frames {
            calibrator.ingest(course: course, courseAccuracy: 5, speed: 1.3,
                              trueHeading: compass, headingAccuracy: 10)
        }
    }

    @Test func straightWalkLocksTheMountOffset() {
        var c = HeadingCalibrator(config: cfg)
        // Phone reads 120 while actually travelling 90: a 30 degree mount offset.
        walk(&c, course: 90, compass: 120, frames: 12)
        #expect(c.isLocked)
        if case .locked(let offset) = c.state {
            #expect(abs(offset - 30) < 0.001)
        } else {
            Issue.record("expected a locked state")
        }
    }

    @Test func standingStillNeverLocks() {
        var c = HeadingCalibrator(config: cfg)
        for _ in 0..<30 {
            c.ingest(course: 90, courseAccuracy: 5, speed: 0.1, trueHeading: 120, headingAccuracy: 10)
        }
        #expect(!c.isLocked)
        #expect(c.progress == 0)
    }

    @Test func aTurnDoesNotLock() {
        var c = HeadingCalibrator(config: cfg)
        // Course sweeps through a turn while the compass lags: the offset candidates spread too far.
        for i in 0..<20 {
            let course = Double(i) * 8     // 0, 8, 16 ... a steady turn
            c.ingest(course: course, courseAccuracy: 5, speed: 1.3, trueHeading: 0, headingAccuracy: 10)
        }
        #expect(!c.isLocked)
    }

    @Test func poorSensorAccuracyIsIgnored() {
        var c = HeadingCalibrator(config: cfg)
        // Compass accuracy past the gate: no samples accepted, no progress.
        for _ in 0..<20 {
            c.ingest(course: 90, courseAccuracy: 5, speed: 1.3, trueHeading: 120, headingAccuracy: 40)
        }
        #expect(c.progress == 0)
    }

    @Test func resetReturnsToCollecting() {
        var c = HeadingCalibrator(config: cfg)
        walk(&c, course: 90, compass: 120, frames: 12)
        #expect(c.isLocked)
        c.reset()
        #expect(!c.isLocked)
        #expect(c.mountOffset == nil)
    }

    @Test func progressClimbsTowardLock() {
        var c = HeadingCalibrator(config: cfg)
        walk(&c, course: 90, compass: 120, frames: 5)   // half of samplesNeeded
        #expect(c.progress > 0 && c.progress < 1)
    }

    // MARK: - Circular statistics

    @Test func circularMeanWrapsAcrossZero() {
        // Mean of 350 and 10 is 0, not 180.
        let mean = HeadingCalibrator.circularMean([350, 10])
        #expect(abs(HeadingCalibrator.angularDifference(mean, 0)) < 0.001)
    }

    @Test func offsetLocksAcrossTheWrap() {
        var c = HeadingCalibrator(config: cfg)
        // Travelling 10, phone reads 350: offset is -20, i.e. 340.
        walk(&c, course: 10, compass: 350, frames: 12)
        #expect(c.isLocked)
        if case .locked(let offset) = c.state {
            #expect(abs(HeadingCalibrator.angularDifference(offset, 340)) < 0.001)
        }
    }
}
