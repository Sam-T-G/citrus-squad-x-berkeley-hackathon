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

    // The bands tile the circle exactly, so the raw band at each boundary still matches the table.
    @Test func bandBoundariesMatchTheTable() {
        #expect(QuadrantMapper.band(forRelativeBearing: 9.9).cue == Cue(event: .forward, mask: .front))
        #expect(QuadrantMapper.band(forRelativeBearing: 10).cue == Cue(event: .turnSlight, mask: .right))
        #expect(QuadrantMapper.band(forRelativeBearing: 60).cue == Cue(event: .turnNow, mask: .right))
        #expect(QuadrantMapper.band(forRelativeBearing: 350).cue == Cue(event: .forward, mask: .front))
    }

    // A widened band reaches past each boundary by the margin, with the Front band's wrap handled.
    @Test func widenedBandCoversTheMargin() {
        let front = QuadrantMapper.bands[0] // 350–10, widened by 5° becomes 345–15
        #expect(front.contains(12, margin: 5))    // 2° past the 10° edge, inside the 5° margin
        #expect(!front.contains(16, margin: 5))   // 6° past, outside it
        #expect(front.contains(348, margin: 5))   // 2° below the 350° edge, inside the low margin
        #expect(!front.contains(343, margin: 5))  // 7° below, outside it
    }
}

/// The resistance on the route-following turn cue: heading jitter near a band boundary holds the
/// current cue (hysteresis), and a new band must persist a few ticks before the belt switches to it
/// (dwell). Replaying a bearing sequence makes the state machine deterministic to check.
struct NavigationCueSmootherTests {
    private func replay(_ bearings: [Double]) -> [Cue] {
        var smoother = NavigationCueSmoother()
        return bearings.map { smoother.update(relativeBearing: $0) }
    }

    private let front = Cue(event: .forward, mask: .front)
    private let slightRight = Cue(event: .turnSlight, mask: .right)
    private let sharpRight = Cue(event: .turnNow, mask: .right)

    @Test func firstReadingCommitsImmediately() {
        // No history, so the belt is correct from the first tick instead of holding a stale cue.
        var smoother = NavigationCueSmoother()
        #expect(smoother.update(relativeBearing: 90) == sharpRight)
    }

    @Test func jitterAcrossABoundaryHoldsTheCue() {
        // Start on course, then dither a few degrees past the 10° boundary. Inside the deadband, so
        // the belt stays on Front instead of flicking to a slight-right tap every frame.
        let cues = replay([5, 11, 14, 8, 13])
        #expect(cues.allSatisfy { $0 == front })
    }

    @Test func aSingleFrameSpikeDoesNotSwitch() {
        // One frame jumps well past the deadband, then it is gone. Dwell swallows it.
        let cues = replay([0, 90, 0])
        #expect(cues == [front, front, front])
    }

    @Test func aSustainedTurnCommitsAfterTheDwell() {
        // Held past the deadband for the full dwell, the belt commits to the new band.
        let cues = replay([0, 90, 90, 90])
        #expect(cues[0] == front)        // on course
        #expect(cues[1] == front)        // candidate, not yet committed
        #expect(cues[2] == front)        // still pending
        #expect(cues[3] == sharpRight)   // dwell satisfied (navCueDwellTicks = 3)
    }

    @Test func crossingTheDeadbandThenSettlingCommitsTheBand() {
        // Move clearly into slight-right (20°, past the 10°+5° deadband) and stay: commits after dwell.
        let cues = replay([0, 20, 20, 20])
        #expect(cues[3] == slightRight)
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

/// The path-following geometry that makes the belt trace the drawn route. All pure, so it is the
/// high-value place to test the new pure-pursuit behavior without a device.
struct PathFollowingTests {
    @Test func decodesGooglePolylineGoldenVector() {
        // The canonical example from Google's encoded-polyline documentation.
        let points = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        #expect(points.count == 3)
        #expect(abs(points[0].latitude - 38.5) < 1e-5)
        #expect(abs(points[0].longitude - (-120.2)) < 1e-5)
        #expect(abs(points[1].latitude - 40.7) < 1e-5)
        #expect(abs(points[2].latitude - 43.252) < 1e-5)
        #expect(abs(points[2].longitude - (-126.453)) < 1e-5)
    }

    @Test func projectsOntoNearestSegment() {
        // North-running segment; a point to the east projects back onto the line.
        let path = [GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 0.001, longitude: 0)]
        let off = GeoPoint(latitude: 0.0005, longitude: 0.0002)
        let projection = Bearing.closestPoint(on: path, to: off)
        #expect(projection != nil)
        #expect(abs(projection!.point.longitude - 0) < 1e-6)        // foot is back on the line
        #expect(abs(projection!.point.latitude - 0.0005) < 1e-4)    // halfway up
        #expect(projection!.distanceMeters > 10)                    // ~22 m east of the line
    }

    @Test func lookAheadRoundsTheCorner() {
        // L path: north then east. From the start, a look-ahead longer than the first leg should
        // land on the east leg, proving it follows the path around the corner instead of cutting.
        let path = [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0.001, longitude: 0),        // ~111 m north (the corner)
            GeoPoint(latitude: 0.001, longitude: 0.001),    // ~111 m east
        ]
        let projection = Bearing.closestPoint(on: path, to: path[0])!
        let target = Bearing.point(on: path, aheadOf: projection, by: 150)
        #expect(abs(target.latitude - 0.001) < 1e-4)   // reached the corner's latitude
        #expect(target.longitude > 0.0002)             // and turned east along the second leg
    }

    @Test func lookAheadClampsToEnd() {
        let path = [GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 0, longitude: 0.001)]
        let projection = Bearing.closestPoint(on: path, to: path[0])!
        let target = Bearing.point(on: path, aheadOf: projection, by: 10_000)
        #expect(abs(target.longitude - 0.001) < 1e-9)   // clamped to the final vertex
    }

    @Test func pivotsFindACornerNotStraightRuns() {
        // An L path: north then east. Exactly one real corner, no false pivots on the straight runs.
        let lPath = [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0.0005, longitude: 0),       // north
            GeoPoint(latitude: 0.001, longitude: 0),        // north (corner is the next vertex)
            GeoPoint(latitude: 0.001, longitude: 0.0005),   // east
            GeoPoint(latitude: 0.001, longitude: 0.001),    // east
        ]
        #expect(RouteMath.pivots(from: lPath) == [2])
    }

    @Test func demoRouteIsAStraightWalk() {
        // The Bancroft Way demo route is collinear, so it has no corners.
        #expect(RouteMath.pivots(from: RouteMath.demoRoute).isEmpty)
    }

    @Test func signedDeltaTakesTheShortWay() {
        #expect(abs(RouteMath.signedDelta(from: 350, to: 10) - 20) < 1e-9)
        #expect(abs(RouteMath.signedDelta(from: 10, to: 350) - (-20)) < 1e-9)
    }
}
