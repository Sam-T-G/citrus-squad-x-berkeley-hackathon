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
            return nil                                              // centerline forward, no tap
        case 10..<60:
            return Cue(event: .turnSlight, mask: .right)
        case 60..<120:
            return Cue(event: .turnNow, mask: .farRight)
        case 120..<240:
            return Cue(event: .turnAround, mask: .bothFar)
        case 240..<300:
            return Cue(event: .turnNow, mask: .farLeft)
        case 300..<350:
            return Cue(event: .turnSlight, mask: .left)
        default:
            return nil
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
}
