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

    // MARK: - Path following (pure pursuit)

    /// Where on a polyline the wearer is: which segment, the foot of the perpendicular, and how far
    /// off the line they are. This is what lets guidance track the drawn path even when the GPS fix
    /// is a few meters to the side of it.
    struct PathProjection: Equatable {
        var segmentIndex: Int       // segment is path[segmentIndex] -> path[segmentIndex + 1]
        var point: GeoPoint         // closest point on that segment
        var distanceMeters: Double  // perpendicular distance from the input point to the path
    }

    /// Closest point on a polyline to `p`, scanning every segment. Returns nil for a path with fewer
    /// than two points.
    static func closestPoint(on path: [GeoPoint], to p: GeoPoint) -> PathProjection? {
        guard path.count >= 2 else { return nil }
        var best: PathProjection?
        for i in 0..<(path.count - 1) {
            let foot = closestPointOnSegment(p, a: path[i], b: path[i + 1])
            let d = distance(from: p.coordinate, to: foot.coordinate)
            if best == nil || d < best!.distanceMeters {
                best = PathProjection(segmentIndex: i, point: foot, distanceMeters: d)
            }
        }
        return best
    }

    /// A point `distance` meters further along the path from a projection. Walks vertex to vertex
    /// from the projection's foot; clamps to the final vertex if the path ends first. This is the
    /// pure-pursuit look-ahead target: aiming here makes the wearer round corners with the sidewalk
    /// instead of cutting across.
    static func point(on path: [GeoPoint], aheadOf projection: PathProjection, by distance: Double) -> GeoPoint {
        guard path.count >= 2 else { return path.first ?? projection.point }
        var current = projection.point
        var remaining = max(0, distance)
        var vertex = projection.segmentIndex + 1
        while vertex < path.count {
            let next = path[vertex]
            let leg = self.distance(from: current.coordinate, to: next.coordinate)
            if leg >= remaining {
                let t = leg > 0 ? remaining / leg : 0
                return lerp(current, next, t)
            }
            remaining -= leg
            current = next
            vertex += 1
        }
        return path[path.count - 1]
    }

    /// Closest point on a single segment a->b to p, computed in a local meters frame around `a` so
    /// the projection is accurate at city-block scale.
    static func closestPointOnSegment(_ p: GeoPoint, a: GeoPoint, b: GeoPoint) -> GeoPoint {
        let metersPerDegLat = 111_320.0
        let metersPerDegLng = 111_320.0 * cos(a.latitude.radians)
        let bx = (b.longitude - a.longitude) * metersPerDegLng
        let by = (b.latitude - a.latitude) * metersPerDegLat
        let px = (p.longitude - a.longitude) * metersPerDegLng
        let py = (p.latitude - a.latitude) * metersPerDegLat
        let denom = bx * bx + by * by
        let t = denom > 0 ? min(1, max(0, (px * bx + py * by) / denom)) : 0
        return lerp(a, b, t)
    }

    /// Linear interpolation between two coordinates. Fine over the short segments of a walking route.
    static func lerp(_ a: GeoPoint, _ b: GeoPoint, _ t: Double) -> GeoPoint {
        GeoPoint(latitude: a.latitude + (b.latitude - a.latitude) * t,
                 longitude: a.longitude + (b.longitude - a.longitude) * t)
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
