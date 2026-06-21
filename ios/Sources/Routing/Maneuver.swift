import Foundation
import CoreLocation

/// A plain lat/lng pair. Sendable value type so it crosses from the Directions network call back
/// to the main actor without dragging a non-Sendable `CLLocationCoordinate2D` across.
struct GeoPoint: Sendable, Equatable, Codable {
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A point on the route where the wearer must turn, plus the bearing of the segment that follows.
/// `turnToBearing` is the direction to head after the turn, which is what the cue points at.
struct Maneuver: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    var turnToBearing: Double
    var isFinal: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Builds the maneuver list from a sequence of waypoints. Each waypoint after the start becomes a
/// maneuver: its location is the turn point, its `turnToBearing` is the bearing of the next
/// segment. The last waypoint is the destination, marked final, which cues `arrived`.
enum RouteMath {
    static func maneuvers(from waypoints: [GeoPoint]) -> [Maneuver] {
        guard waypoints.count >= 2 else { return [] }
        var result: [Maneuver] = []
        for index in 1..<waypoints.count {
            let isFinal = index == waypoints.count - 1
            let turnTo = isFinal
                ? 0
                : Bearing.initial(from: waypoints[index].coordinate, to: waypoints[index + 1].coordinate)
            result.append(Maneuver(latitude: waypoints[index].latitude,
                                   longitude: waypoints[index].longitude,
                                   turnToBearing: turnTo,
                                   isFinal: isFinal))
        }
        return result
    }

    /// Meters left to walk from `position` to the end of the route, following the waypoints from
    /// `segmentIndex` onward. The leg the wearer is on is measured from the live position to the
    /// next waypoint; full legs after that are summed. Pure geometry, no network, so the nav overlay
    /// can show progress for free. Returns 0 once the last waypoint is reached.
    static func remainingDistance(from position: GeoPoint,
                                  along waypoints: [GeoPoint],
                                  segmentIndex: Int) -> Double {
        guard waypoints.count >= 2, segmentIndex >= 0, segmentIndex + 1 < waypoints.count else {
            return 0
        }
        var total = Bearing.distance(from: position.coordinate,
                                     to: waypoints[segmentIndex + 1].coordinate)
        var index = segmentIndex + 1
        while index + 1 < waypoints.count {
            total += Bearing.distance(from: waypoints[index].coordinate,
                                      to: waypoints[index + 1].coordinate)
            index += 1
        }
        return total
    }

    /// Rough walking ETA in seconds for a remaining distance, at the configured walking speed.
    /// Local arithmetic, never a Maps call. Returns 0 for a non-positive speed or distance.
    static func walkingETASeconds(forDistance meters: Double,
                                  speedMetersPerSecond: Double = CitrusSquadConfig.walkingSpeed) -> Double {
        guard meters > 0, speedMetersPerSecond > 0 else { return 0 }
        return meters / speedMetersPerSecond
    }

    /// The corner vertices of a dense polyline: indices where the heading swings by more than the
    /// pivot threshold from one segment to the next. These are the real turns the wearer makes, so
    /// the nav banner counts down to them and the belt can lean into them. The straight runs of a
    /// densely-sampled sidewalk produce no pivots; only actual corners do.
    static func pivots(from path: [GeoPoint],
                       thresholdDegrees: Double = CitrusSquadConfig.pivotThresholdDegrees) -> [Int] {
        guard path.count >= 3 else { return [] }
        var result: [Int] = []
        for i in 1..<(path.count - 1) {
            let incoming = Bearing.initial(from: path[i - 1].coordinate, to: path[i].coordinate)
            let outgoing = Bearing.initial(from: path[i].coordinate, to: path[i + 1].coordinate)
            let swing = abs(signedDelta(from: incoming, to: outgoing))
            if swing >= thresholdDegrees { result.append(i) }
        }
        return result
    }

    /// Smallest signed angle (degrees, -180...180) to turn from bearing `a` to bearing `b`.
    static func signedDelta(from a: Double, to b: Double) -> Double {
        let raw = Bearing.normalize(b - a)
        return raw > 180 ? raw - 360 : raw
    }

    /// The default demo route for the hackathon: start on the sidewalk outside the MLK Jr. Student
    /// Union and walk straight west down Bancroft Way, roughly 240 m. The points are collinear, so it
    /// produces a steady forward cue with no false turns. Runs with no API key and no GPS, and lines
    /// up with the real street so a live-GPS walk from MLK tracks it. Coordinates are approximate;
    /// nudge them if the line sits off the sidewalk on the map.
    static let demoRoute: [GeoPoint] = [
        GeoPoint(latitude: 37.868833, longitude: -122.259222),  // outside MLK, on Bancroft Way
        GeoPoint(latitude: 37.868784, longitude: -122.259502),  // west down Bancroft
        GeoPoint(latitude: 37.868734, longitude: -122.259781),  // west
        GeoPoint(latitude: 37.868685, longitude: -122.260061),  // destination, ~75 m down Bancroft
    ]
}
