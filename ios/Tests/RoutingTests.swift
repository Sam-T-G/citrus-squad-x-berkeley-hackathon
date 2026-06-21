import Testing
import CoreLocation
@testable import CitrusSquad

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
    @Test func onCourseTapsForward() {
        #expect(QuadrantMapper.cue(forRelativeBearing: 0) == Cue(event: .forward, mask: .front))
        #expect(QuadrantMapper.cue(forRelativeBearing: 5) == Cue(event: .forward, mask: .front))
        #expect(QuadrantMapper.cue(forRelativeBearing: 355) == Cue(event: .forward, mask: .front))
    }

    @Test func slightRight() {
        #expect(QuadrantMapper.cue(forRelativeBearing: 30) == Cue(event: .turnSlight, mask: .right))
    }

    @Test func sharpRight() {
        #expect(QuadrantMapper.cue(forRelativeBearing: 90) == Cue(event: .turnNow, mask: .right))
    }

    @Test func turnAround() {
        #expect(QuadrantMapper.cue(forRelativeBearing: 180) == Cue(event: .turnAround, mask: .rotate))
    }

    @Test func sharpLeft() {
        #expect(QuadrantMapper.cue(forRelativeBearing: 270) == Cue(event: .turnNow, mask: .left))
    }

    @Test func slightLeft() {
        #expect(QuadrantMapper.cue(forRelativeBearing: 320) == Cue(event: .turnSlight, mask: .left))
    }
}

/// The client-side trip math that drives the nav banner. Pure, so it is unit-tested; it never
/// touches Google, so the ETA and remaining-distance read-outs cost nothing.
struct TripMathTests {
    // A straight 0.2 degree run of longitude at the equator is close to 22.2 km, in two equal legs.
    private let leg = [
        GeoPoint(latitude: 0.0, longitude: 0.0),
        GeoPoint(latitude: 0.0, longitude: 0.1),
        GeoPoint(latitude: 0.0, longitude: 0.2),
    ]

    @Test func remainingSumsTheLegsAhead() {
        // Standing on the very first waypoint, the whole route is still ahead.
        let total = RouteMath.remainingDistance(from: leg[0], along: leg, segmentIndex: 0)
        let direct = Bearing.distance(from: leg[0].coordinate, to: leg[1].coordinate)
            + Bearing.distance(from: leg[1].coordinate, to: leg[2].coordinate)
        #expect(abs(total - direct) < 1.0)
    }

    @Test func remainingMeasuresFromLivePosition() {
        // Halfway along the second leg, only that half remains.
        let half = GeoPoint(latitude: 0.0, longitude: 0.15)
        let remaining = RouteMath.remainingDistance(from: half, along: leg, segmentIndex: 1)
        let expected = Bearing.distance(from: half.coordinate, to: leg[2].coordinate)
        #expect(abs(remaining - expected) < 1.0)
    }

    @Test func remainingIsZeroPastTheEnd() {
        #expect(RouteMath.remainingDistance(from: leg[2], along: leg, segmentIndex: 2) == 0)
        #expect(RouteMath.remainingDistance(from: leg[0], along: [], segmentIndex: 0) == 0)
    }

    @Test func etaScalesWithDistanceAndSpeed() {
        #expect(RouteMath.walkingETASeconds(forDistance: 130, speedMetersPerSecond: 1.3) == 100)
        #expect(RouteMath.walkingETASeconds(forDistance: 0) == 0)
        #expect(RouteMath.walkingETASeconds(forDistance: 100, speedMetersPerSecond: 0) == 0)
    }
}
