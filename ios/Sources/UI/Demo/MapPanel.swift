import SwiftUI
import MapKit

/// Shows the wearer's position and the cached route on a map. Reads the app's own nav data: the
/// route waypoints and either the simulated position or the live GPS fix. Functional today; no
/// teammate dependency.
struct MapPanel: View {
    let model: AppModel
    @State private var camera: MapCameraPosition = .automatic

    private var routeCoordinates: [CLLocationCoordinate2D] {
        model.simulator.waypoints.map(\.coordinate)
    }

    private var position: CLLocationCoordinate2D? {
        model.simulator.position?.coordinate ?? model.location.location?.coordinate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Map", systemImage: "map").font(.headline)

            Map(position: $camera) {
                if routeCoordinates.count >= 2 {
                    MapPolyline(coordinates: routeCoordinates)
                        .stroke(.blue, lineWidth: 4)
                }
                if let position {
                    Annotation("You", coordinate: position) {
                        Image(systemName: "location.fill")
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Circle().fill(.blue))
                    }
                }
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(positionText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var positionText: String {
        guard let position else { return "no position yet — run the simulator or get a GPS fix" }
        return String(format: "%.5f, %.5f", position.latitude, position.longitude)
    }
}
