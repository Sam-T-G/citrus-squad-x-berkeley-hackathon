import Testing
import CoreLocation
@testable import WAND

struct BearingTests {
    @Test func dueNorthIsZero() {
        let from = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)
        let to = CLLocationCoordinate2D(latitude: 37.1, longitude: -122.0)
        #expect(abs(Bearing.initial(from: from, to: to)) < 0.5)
    }

    @Test func dueEastIsNinety() {
        let from = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.0)
        let to = CLLocationCoordinate2D(latitude: 0.0, longitude: 0.1)
        #expect(abs(Bearing.initial(from: from, to: to) - 90) < 0.5)
    }

    @Test func bodyHeadingAppliesOffset() {
        #expect(Bearing.bodyHeading(phoneTrueHeading: 100, calibrationOffset: 30) == 70)
        #expect(Bearing.bodyHeading(phoneTrueHeading: 10, calibrationOffset: 30) == 340)
    }

    @Test func relativeBearingWraps() {
        #expect(Bearing.relative(routeBearing: 10, bodyHeading: 350) == 20)
        #expect(Bearing.relative(routeBearing: 350, bodyHeading: 10) == 340)
    }

    @Test func normalizeFoldsIntoRange() {
        #expect(Bearing.normalize(-10) == 350)
        #expect(Bearing.normalize(370) == 10)
        #expect(Bearing.normalize(720) == 0)
    }
}

/// Walks the quadrant table from `docs/04-phone-side.md`. These eight checks are the M4 gate.
struct QuadrantMapperTests {
    @Test func centerlineIsNoTap() {
        #expect(QuadrantMapper.cue(forRelativeBearing: 0) == nil)
        #expect(QuadrantMapper.cue(forRelativeBearing: 5) == nil)
        #expect(QuadrantMapper.cue(forRelativeBearing: 355) == nil)
    }

    @Test func slightRight() {
        #expect(QuadrantMapper.cue(forRelativeBearing: 30) == Cue(event: .turnSlight, mask: .right))
    }

    @Test func sharpRight() {
        #expect(QuadrantMapper.cue(forRelativeBearing: 90) == Cue(event: .turnNow, mask: .farRight))
    }

    @Test func turnAround() {
        #expect(QuadrantMapper.cue(forRelativeBearing: 180) == Cue(event: .turnAround, mask: .bothFar))
    }

    @Test func sharpLeft() {
        #expect(QuadrantMapper.cue(forRelativeBearing: 270) == Cue(event: .turnNow, mask: .farLeft))
    }

    @Test func slightLeft() {
        #expect(QuadrantMapper.cue(forRelativeBearing: 320) == Cue(event: .turnSlight, mask: .left))
    }
}
