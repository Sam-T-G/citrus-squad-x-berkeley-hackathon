import Foundation
import CoreLocation
import Observation

/// Walks a cached route in software so the whole navigation-to-belt path can be exercised with no
/// GPS and no walking. It advances a virtual wearer along the waypoints at walking speed, facing
/// along the current segment, and hands each tick's (position, heading) to the `RouteEngine`. The
/// engine, the arbitration, the transmitter, and the belt cannot tell this from a real walk, which
/// is the point: the demo path and the field path are the same code.
@MainActor
@Observable
final class RouteSimulator {
    private(set) var waypoints: [GeoPoint] = []
    private(set) var position: GeoPoint?
    private(set) var heading: Double = 0
    private(set) var isRunning = false
    private(set) var segmentIndex = 0

    /// Meters per second of the virtual walk. Bump it up to run a route faster while testing.
    var speedMetersPerSecond = WANDConfig.walkingSpeed

    func load(_ waypoints: [GeoPoint]) {
        self.waypoints = waypoints
        segmentIndex = 0
        position = waypoints.first
        heading = waypoints.count >= 2
            ? Bearing.initial(from: waypoints[0].coordinate, to: waypoints[1].coordinate)
            : 0
        isRunning = false
    }

    func start() { isRunning = true }
    func stop() { isRunning = false }
    func reset() { load(waypoints) }

    /// Advance one tick. Returns the new (position, heading), or nil once the route is finished.
    func step(dt: Double) -> (GeoPoint, Double)? {
        guard isRunning, let current = position else { return nil }
        guard segmentIndex + 1 < waypoints.count else {
            isRunning = false
            return (current, heading)
        }

        let target = waypoints[segmentIndex + 1]
        heading = Bearing.initial(from: current.coordinate, to: target.coordinate)
        let remaining = Bearing.distance(from: current.coordinate, to: target.coordinate)
        let stepDistance = speedMetersPerSecond * dt

        if stepDistance >= remaining {
            position = target
            segmentIndex += 1   // heading swings to the next segment on the following tick
        } else {
            position = Self.move(from: current, bearing: heading, meters: stepDistance)
        }
        return (position!, heading)
    }

    /// Move a point `meters` along a `bearing` (great-circle), for the virtual walk.
    static func move(from point: GeoPoint, bearing: Double, meters: Double) -> GeoPoint {
        let earthRadius = 6_371_000.0
        let angular = meters / earthRadius
        let bearingRad = bearing * .pi / 180
        let lat1 = point.latitude * .pi / 180
        let lon1 = point.longitude * .pi / 180

        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearingRad))
        let lon2 = lon1 + atan2(sin(bearingRad) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sin(lat2))
        return GeoPoint(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}
