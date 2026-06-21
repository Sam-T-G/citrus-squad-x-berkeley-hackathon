import Foundation
import Observation

/// One belt cue: which event pattern, on which quadrant(s).
struct Cue: Sendable, Equatable {
    var event: LC2Event
    var mask: QuadrantMask
}

/// Turns a body-relative bearing into a belt cue. The bands come straight from the quadrant
/// mapping table in `docs/04-phone-side.md`. Pure and static so it is trivially testable.
///
/// The bands tile the circle with no gaps, so `cue(forRelativeBearing:)` is the same hard-band
/// mapping as before. The hysteresis used to smooth the belt lives in `NavigationCueSmoother`,
/// which widens the held band by a margin (`Band.contains(_:margin:)`) before it will switch.
enum QuadrantMapper {
    /// One arc of the quadrant table: a clockwise span `[lower, lower + width)` on the compass and
    /// the cue it fires. `isTurnAround` flags the wide rear band so the smoother can give it a wider
    /// deadband (`docs/04` calls for ±10° there versus ±5° on the adjacent boundaries).
    struct Band: Equatable {
        let lower: Double       // inclusive lower edge, normalized to [0, 360)
        let width: Double       // arc width in degrees, measured clockwise from `lower`
        let cue: Cue
        let isTurnAround: Bool

        /// True when `angle` lies in this band widened by `margin` on each side. Circular, so the
        /// Front band's wrap across north is handled. A margin of 0 gives the raw band.
        func contains(_ angle: Double, margin: Double = 0) -> Bool {
            let span = width + 2 * margin
            if span >= 360 { return true }
            let offset = Bearing.normalize(angle - (lower - margin))
            return offset < span
        }
    }

    /// The quadrant table, in order, covering the full circle exactly once.
    static let bands: [Band] = [
        Band(lower: 350, width: 20,  cue: Cue(event: .forward,    mask: .front),  isTurnAround: false), // 350–10 on course
        Band(lower: 10,  width: 50,  cue: Cue(event: .turnSlight, mask: .right),  isTurnAround: false), // gentle right
        Band(lower: 60,  width: 60,  cue: Cue(event: .turnNow,    mask: .right),  isTurnAround: false), // sharp right
        Band(lower: 120, width: 120, cue: Cue(event: .turnAround, mask: .rotate), isTurnAround: true),  // U-turn
        Band(lower: 240, width: 60,  cue: Cue(event: .turnNow,    mask: .left),   isTurnAround: false), // sharp left
        Band(lower: 300, width: 50,  cue: Cue(event: .turnSlight, mask: .left),   isTurnAround: false), // gentle left
    ]

    /// The raw band a bearing falls in, with no hysteresis.
    static func band(forRelativeBearing bearing: Double) -> Band {
        let angle = Bearing.normalize(bearing)
        return bands.first { $0.contains(angle) } ?? bands[0]
    }

    static func cue(forRelativeBearing bearing: Double) -> Cue? {
        band(forRelativeBearing: bearing).cue
    }
}

/// Holds the calibration offset and the current cue. In this base version the route bearing is a
/// settable value, so the operator can bench-test the full heading-to-cue path: calibrate, set a
/// target bearing, rotate the phone, and watch the cue change and transmit.
///
/// Route mode follows the dense Maps polyline by pure pursuit: project the wearer onto the path,
/// aim at a look-ahead point a few meters ahead on it, and cue toward that bearing every tick. The
/// drawn line and the belt then steer the same path, rounding sidewalk corners instead of cutting
/// straight to the destination.
@MainActor
@Observable
final class RouteEngine {
    private(set) var calibrationOffset: Double = 0
    private(set) var isCalibrated = false
    private(set) var bodyHeading: Double = 0
    private(set) var currentCue: Cue?

    // Route mode: the dense polyline the wearer follows, walked by GPS or the simulator.
    private(set) var path: [GeoPoint] = []
    private(set) var pivots: [Int] = []                 // corner vertices in `path`
    private(set) var maneuvers: [Maneuver] = []         // one per pivot plus the final destination
    private(set) var activeIndex = 0                     // pivots already passed
    private(set) var distanceToNext: Double = -1         // meters to the next pivot (drives the banner)
    private(set) var remaining: Double = -1              // meters left to the destination

    /// The true-north bearing the wearer should be walking toward. Set from the bench slider now,
    /// from the cached Maps route later.
    var targetRouteBearing: Double = 0

    /// Resistance on the route-following turn cue (hysteresis + dwell) so the belt does not chatter
    /// between adjacent taps on heading jitter. Drives the belt path only; the bench `update` stays
    /// raw so the operator sees the unfiltered heading-to-cue mapping.
    private var turnSmoother = NavigationCueSmoother()

    func calibrate(phoneHeading: Double) {
        calibrationOffset = phoneHeading
        isCalibrated = true
    }

    func update(phoneHeading: Double) {
        let body = Bearing.bodyHeading(phoneTrueHeading: phoneHeading, calibrationOffset: calibrationOffset)
        bodyHeading = body
        let relative = Bearing.relative(routeBearing: targetRouteBearing, bodyHeading: body)
        currentCue = QuadrantMapper.cue(forRelativeBearing: relative)
    }

    // MARK: - Route mode

    /// Load the dense route polyline and derive its corners. The maneuver list (one per pivot plus
    /// the destination) is kept so the banner and voice can say how many turns remain.
    func loadPath(_ path: [GeoPoint]) {
        self.path = path
        self.pivots = RouteMath.pivots(from: path)
        self.maneuvers = Self.maneuvers(forPivots: pivots, in: path)
        activeIndex = 0
        distanceToNext = -1
        remaining = -1
        currentCue = nil
        turnSmoother.reset()
    }

    /// Backwards-compatible shim: callers that still hand a maneuver list rebuild the path from the
    /// maneuver coordinates. New code should call `loadPath`.
    func loadRoute(_ maneuvers: [Maneuver]) {
        loadPath(maneuvers.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude) })
    }

    /// Decide the cue by following the path with pure pursuit. Used by live GPS and the simulator.
    /// Projects the position onto the path, aims a look-ahead point ahead along it, and cues toward
    /// that bearing every tick (continuous forward tap on a straightaway, a turn as the look-ahead
    /// rounds a corner). Emits `arrived` near the end; steers back to the line if the wearer strays.
    /// `applyCalibration` maps a real phone-compass heading to body-forward. The simulator already
    /// supplies a body-forward heading, so it passes `false` and the calibration offset is skipped;
    /// live GPS and the bench pass `true`.
    func updateRoute(location: GeoPoint, phoneHeading: Double, applyCalibration: Bool = true) {
        bodyHeading = applyCalibration
            ? Bearing.bodyHeading(phoneTrueHeading: phoneHeading, calibrationOffset: calibrationOffset)
            : Bearing.normalize(phoneHeading)
        guard path.count >= 2, let projection = Bearing.closestPoint(on: path, to: location) else {
            currentCue = nil
            distanceToNext = -1
            remaining = -1
            turnSmoother.reset()
            return
        }

        let metersToEnd = RouteMath.remainingDistance(from: projection.point,
                                                      along: path,
                                                      segmentIndex: projection.segmentIndex)
        remaining = metersToEnd
        if metersToEnd <= CitrusSquadConfig.pathArriveMeters {
            currentCue = Cue(event: .arrived, mask: .all)
            distanceToNext = metersToEnd
            activeIndex = maneuvers.count
            turnSmoother.reset()
            return
        }

        // Aim at the look-ahead point on the path, unless the wearer has strayed too far, in which
        // case aim straight back at the line first.
        let aimPoint = projection.distanceMeters > CitrusSquadConfig.onPathToleranceMeters
            ? projection.point
            : Bearing.point(on: path, aheadOf: projection, by: CitrusSquadConfig.lookAheadMeters)

        targetRouteBearing = Bearing.initial(from: location.coordinate, to: aimPoint.coordinate)
        let relative = Bearing.relative(routeBearing: targetRouteBearing, bodyHeading: bodyHeading)
        // Smooth the route-following cue so heading jitter near a band boundary does not chatter the
        // belt. The hazard tiers in AppModel preempt navigation, so this never delays a collision cue.
        currentCue = turnSmoother.update(relativeBearing: relative)

        distanceToNext = distanceToNextPivot(from: projection, remainingToEnd: remaining)
        activeIndex = pivots.filter { $0 <= projection.segmentIndex }.count
    }

    /// Distance along the path from the projection to the next corner ahead, or to the end if no
    /// corner remains. Feeds the banner's "Turn in N m" countdown.
    private func distanceToNextPivot(from projection: Bearing.PathProjection, remainingToEnd: Double) -> Double {
        guard let nextPivot = pivots.first(where: { $0 >= projection.segmentIndex + 1 }) else {
            return remainingToEnd
        }
        var total = Bearing.distance(from: projection.point.coordinate,
                                     to: path[projection.segmentIndex + 1].coordinate)
        var index = projection.segmentIndex + 1
        while index < nextPivot {
            total += Bearing.distance(from: path[index].coordinate, to: path[index + 1].coordinate)
            index += 1
        }
        return total
    }

    /// Build a maneuver per corner plus a final one at the destination, so the banner and voice can
    /// report turns remaining. The turn bearing is the direction of the segment leaving the corner.
    private static func maneuvers(forPivots pivots: [Int], in path: [GeoPoint]) -> [Maneuver] {
        guard path.count >= 2 else { return [] }
        var result: [Maneuver] = pivots.compactMap { index in
            guard index + 1 < path.count else { return nil }
            return Maneuver(latitude: path[index].latitude,
                            longitude: path[index].longitude,
                            turnToBearing: Bearing.initial(from: path[index].coordinate,
                                                           to: path[index + 1].coordinate),
                            isFinal: false)
        }
        if let last = path.last {
            result.append(Maneuver(latitude: last.latitude, longitude: last.longitude,
                                   turnToBearing: 0, isFinal: true))
        }
        return result
    }
}
