import SwiftUI
import GoogleMaps

/// A live Google map for the demo: the wearer's real position (the SDK's free my-location dot), the
/// loaded route as a polyline, origin and destination markers, and a camera that follows the walk.
/// Tapping the map drops a destination, which writes back `lat,lng` for a governed route fetch.
///
/// Everything this view does is free: rendering a native map, the my-location layer, camera moves,
/// overlays, and reading a tapped coordinate make no billed API call. The one billed path stays the
/// Directions fetch in `DirectionsService`, triggered separately. See `ios/README.md` cost control.
///
/// The view takes plain values, not the model, so SwiftUI diffs them and drives `updateUIView`. The
/// containing section reads the observed model state and passes it in.
struct GoogleMapView: UIViewRepresentable {
    /// The route to draw, start to destination. Empty draws no line.
    var waypoints: [GeoPoint]
    /// Where to center the wearer marker: the simulated walk or the live GPS fix.
    var position: GeoPoint?
    /// Travel direction in true-north degrees, used to rotate the camera for a nav feel.
    var heading: Double
    /// When true, the camera recenters and rotates to the position each update (an active walk).
    /// When false, the wearer can pan and zoom freely.
    var isFollowing: Bool
    /// Called with the coordinate the operator taps, to set the destination with no geocoding.
    var onTapCoordinate: (GeoPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTapCoordinate: onTapCoordinate) }

    func makeUIView(context: Context) -> GMSMapView {
        let options = GMSMapViewOptions()
        // A non-zero starting frame: a GMSMapView created at .zero can come up blank until a later
        // layout pass. SwiftUI resizes it to the card immediately after.
        options.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        // A sane opening camera so the map is not staring at the ocean before the first fix.
        options.camera = GMSCameraPosition(latitude: 37.8719, longitude: -122.2585, zoom: 16)
        let mapView = GMSMapView(options: options)
        mapView.isMyLocationEnabled = true              // free blue dot, reads CoreLocation locally
        mapView.settings.myLocationButton = true        // built-in recenter control
        mapView.settings.compassButton = true
        mapView.delegate = context.coordinator
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        context.coordinator.onTapCoordinate = onTapCoordinate
        context.coordinator.redrawRoute(on: mapView, waypoints: waypoints)
        context.coordinator.follow(on: mapView,
                                   position: position,
                                   heading: heading,
                                   isFollowing: isFollowing,
                                   waypoints: waypoints)
    }

    /// Holds the map overlays so each update edits them instead of stacking duplicates, and bridges
    /// the tap delegate back to the SwiftUI callback.
    @MainActor
    final class Coordinator: NSObject, GMSMapViewDelegate {
        var onTapCoordinate: (GeoPoint) -> Void
        private var routeLine: GMSPolyline?
        private var startMarker: GMSMarker?
        private var endMarker: GMSMarker?
        private var didFitRoute = false
        private var lastWaypointCount = -1

        init(onTapCoordinate: @escaping (GeoPoint) -> Void) {
            self.onTapCoordinate = onTapCoordinate
        }

        /// Redraw the polyline and the end markers only when the route actually changes, so a
        /// per-tick camera follow does not thrash the overlays.
        func redrawRoute(on mapView: GMSMapView, waypoints: [GeoPoint]) {
            guard waypoints.count != lastWaypointCount else { return }
            lastWaypointCount = waypoints.count

            routeLine?.map = nil
            startMarker?.map = nil
            endMarker?.map = nil
            routeLine = nil
            startMarker = nil
            endMarker = nil
            didFitRoute = false

            guard waypoints.count >= 2 else { return }

            let path = GMSMutablePath()
            for point in waypoints { path.add(point.coordinate) }
            let line = GMSPolyline(path: path)
            line.strokeWidth = 5
            line.strokeColor = .systemBlue
            line.map = mapView
            routeLine = line

            if let first = waypoints.first {
                let marker = GMSMarker(position: first.coordinate)
                marker.title = "Start"
                marker.icon = GMSMarker.markerImage(with: .systemGreen)
                marker.map = mapView
                startMarker = marker
            }
            if let last = waypoints.last {
                let marker = GMSMarker(position: last.coordinate)
                marker.title = "Destination"
                marker.icon = GMSMarker.markerImage(with: .systemRed)
                marker.map = mapView
                endMarker = marker
            }
        }

        /// Move the camera. While following, track the wearer at a walking zoom and rotate to the
        /// heading. Otherwise fit the whole route once so the operator sees it before a walk starts.
        func follow(on mapView: GMSMapView,
                    position: GeoPoint?,
                    heading: Double,
                    isFollowing: Bool,
                    waypoints: [GeoPoint]) {
            if isFollowing, let position {
                let camera = GMSCameraPosition(target: position.coordinate,
                                               zoom: 18,
                                               bearing: heading,
                                               viewingAngle: 45)
                mapView.animate(to: camera)
                return
            }
            guard !didFitRoute, waypoints.count >= 2 else { return }
            let bounds = waypoints.reduce(GMSCoordinateBounds()) { $0.includingCoordinate($1.coordinate) }
            mapView.animate(with: GMSCameraUpdate.fit(bounds, withPadding: 48))
            didFitRoute = true
        }

        nonisolated func mapView(_ mapView: GMSMapView, didTapAt coordinate: CLLocationCoordinate2D) {
            let point = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
            MainActor.assumeIsolated { self.onTapCoordinate(point) }
        }
    }
}
