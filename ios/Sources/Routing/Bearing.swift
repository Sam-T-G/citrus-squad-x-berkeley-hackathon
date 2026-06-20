import Foundation
import CoreLocation

/// Pure navigation geometry. No sensors, no state, all static. This is the most test-worthy
/// code in the app, so it lives apart from anything that touches hardware. Formulas match
/// `docs/04-phone-side.md`.
enum Bearing {
    /// Initial great-circle bearing from `a` to `b`, in true-north degrees, 0..<360.
    static func initial(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude.radians
        let lat2 = b.latitude.radians
        let dLon = (b.longitude - a.longitude).radians
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return normalize(atan2(y, x).degrees)
    }

    /// Haversine distance between two coordinates, in meters.
    static func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (b.latitude - a.latitude).radians
        let dLon = (b.longitude - a.longitude).radians
        let lat1 = a.latitude.radians
        let lat2 = b.latitude.radians
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Body heading after the calibration offset. `docs/04-phone-side.md`:
    /// `body = (phone_true_heading - calibration_offset + 360) % 360`.
    static func bodyHeading(phoneTrueHeading: Double, calibrationOffset: Double) -> Double {
        normalize(phoneTrueHeading - calibrationOffset)
    }

    /// How far the wearer must turn through. 0 is straight ahead, 90 is hard right, 270 is hard left.
    /// `body_relative_bearing = (route_bearing - body_heading + 360) % 360`.
    static func relative(routeBearing: Double, bodyHeading: Double) -> Double {
        normalize(routeBearing - bodyHeading)
    }

    /// Fold any angle into 0..<360.
    static func normalize(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
