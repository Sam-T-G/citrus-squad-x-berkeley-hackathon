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
/// Hysteresis on the band boundaries (±5° adjacent, ±10° turn-around) is a follow-up; this base
/// version uses hard bands. See the table in the phone-side doc.
enum QuadrantMapper {
    static func cue(forRelativeBearing bearing: Double) -> Cue? {
        let angle = Bearing.normalize(bearing)
        switch angle {
        case 0..<10, 350..<360:
            return Cue(event: .forward, mask: .front)              // on course, tap Front
        case 10..<60:
            return Cue(event: .turnSlight, mask: .right)           // gentle right
        case 60..<120:
            return Cue(event: .turnNow, mask: .right)              // sharp right
        case 120..<240:
            return Cue(event: .turnAround, mask: .rotate)          // U-turn, both rotate motors
        case 240..<300:
            return Cue(event: .turnNow, mask: .left)               // sharp left
        case 300..<350:
            return Cue(event: .turnSlight, mask: .left)            // gentle left
        default:
            return Cue(event: .forward, mask: .front)
        }
    }
}

/// Holds the calibration offset and the current cue. In this base version the route bearing is a
/// settable value, so the operator can bench-test the full heading-to-cue path: calibrate, set a
/// target bearing, rotate the phone, and watch the cue change and transmit.
///
/// Live Maps polyline playback (the M5 path in `docs/04-phone-side.md`) drops in here later: feed
/// real maneuver bearings into `targetRouteBearing` from a cached route instead of the slider.
@MainActor
@Observable
final class RouteEngine {
    private(set) var calibrationOffset: Double = 0
    private(set) var isCalibrated = false
    private(set) var bodyHeading: Double = 0
    private(set) var currentCue: Cue?

    // Route mode: a cached list of maneuvers walked by GPS or the simulator.
    private(set) var maneuvers: [Maneuver] = []
    private(set) var activeIndex = 0
    private(set) var distanceToNext: Double = -1

    /// The true-north bearing the wearer should be walking toward. Set from the bench slider now,
    /// from the cached Maps route later.
    var targetRouteBearing: Double = 0

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

    func loadRoute(_ maneuvers: [Maneuver]) {
        self.maneuvers = maneuvers
        activeIndex = 0
        distanceToNext = -1
        currentCue = nil
    }

    /// Decide the cue from a position and heading walking the cached route. Used by live GPS and by
    /// the simulator. Stages a cue only once within the turn-commit distance of the active maneuver,
    /// emits `arrived` at the final one, and advances past a maneuver once it is reached.
    func updateRoute(location: GeoPoint, phoneHeading: Double) {
        bodyHeading = Bearing.bodyHeading(phoneTrueHeading: phoneHeading, calibrationOffset: calibrationOffset)
        guard activeIndex < maneuvers.count else {
            currentCue = nil
            distanceToNext = -1
            return
        }
        let maneuver = maneuvers[activeIndex]
        let distance = Bearing.distance(from: location.coordinate, to: maneuver.coordinate)
        distanceToNext = distance

        guard distance <= CitrusSquadConfig.turnCommitMeters else {
            currentCue = nil
            return
        }
        if maneuver.isFinal {
            currentCue = Cue(event: .arrived, mask: .all)
        } else {
            let relative = Bearing.relative(routeBearing: maneuver.turnToBearing, bodyHeading: bodyHeading)
            currentCue = QuadrantMapper.cue(forRelativeBearing: relative)
            if distance <= CitrusSquadConfig.maneuverArriveMeters {
                activeIndex += 1
            }
        }
    }
}
