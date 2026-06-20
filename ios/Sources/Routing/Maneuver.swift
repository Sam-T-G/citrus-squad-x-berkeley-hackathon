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

    /// A short L-shaped demo route, roughly a 30 m walk: head north, then turn east. Lets the
    /// simulator and the belt run with no API key and no GPS. Coordinates are arbitrary open space.
    static let demoRoute: [GeoPoint] = [
        GeoPoint(latitude: 37.871900, longitude: -122.258500),  // start
        GeoPoint(latitude: 37.872100, longitude: -122.258500),  // ~22 m north, turn here
        GeoPoint(latitude: 37.872100, longitude: -122.258300),  // ~18 m east, destination
    ]
}
