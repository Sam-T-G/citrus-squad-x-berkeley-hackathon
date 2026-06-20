import Foundation
import CoreLocation
import Observation

/// Heading and GPS from one `CLLocationManager`. Heading is the OS-fused compass
/// (magnetometer + gyro + accel). Ported from the proven `wand-phone-probe` service and
/// modernized to `@Observable` plus Swift 6 isolation.
///
/// CoreLocation delivers its delegate callbacks on the thread the manager was created on.
/// We create it on the main actor, so the callbacks arrive on main and `assumeIsolated`
/// is the correct bridge into our `@MainActor` state.
@MainActor
@Observable
final class LocationService: NSObject {
    private let manager = CLLocationManager()

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var trueHeading: Double = -1
    private(set) var magneticHeading: Double = -1
    private(set) var headingAccuracy: Double = -1
    private(set) var location: CLLocation?
    private(set) var lastError: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = CitrusSquadConfig.headingFilterDegrees
        authorization = manager.authorizationStatus
        if isAuthorized { start() }
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            self.authorization = status
            if self.isAuthorized { self.start() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Read the values off the non-Sendable CLHeading here, then hop only the Doubles.
        let trueHeading = newHeading.trueHeading
        let magneticHeading = newHeading.magneticHeading
        let accuracy = newHeading.headingAccuracy
        MainActor.assumeIsolated {
            self.trueHeading = trueHeading
            self.magneticHeading = magneticHeading
            self.headingAccuracy = accuracy
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        MainActor.assumeIsolated {
            self.location = last
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            self.lastError = message
        }
    }
}
