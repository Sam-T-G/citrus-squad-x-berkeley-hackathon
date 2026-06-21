import SwiftUI

/// The Demo tab's map card: a live Google map with the wearer's position and route, the navigation
/// banner over it, and the few controls a demo run needs. Until a Maps key is entered it shows a
/// short prompt instead of an empty map.
///
/// The map, the location dot, and the banner are all free to render. The only billed action on this
/// card is "Fetch route", which goes through the governed `DirectionsService`; the usage counters
/// for it live on the Diagnostics screen.
struct MapSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live map", systemImage: "map").font(.headline)

            ZStack(alignment: .top) {
                mapOrPrompt
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if hasKey {
                    NavigationOverlay(model: model)
                        .padding(8)
                }
            }

            controls
            Text("Map and location are free to render. Only a route fetch is billed, and it is capped.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// The map is gated on the observable key so SwiftUI re-renders the moment a key is entered.
    /// Setting the key also hands it to the SDK (AppModel `didSet`), so by the time this is true the
    /// SDK is keyed and the map can be created.
    private var hasKey: Bool { !model.directionsAPIKey.isEmpty }

    @ViewBuilder
    private var mapOrPrompt: some View {
        if hasKey {
            GoogleMapView(waypoints: model.simulator.waypoints,
                          position: model.navPosition,
                          heading: model.navHeading,
                          isFollowing: model.isDriving,
                          onTapCoordinate: setDestination)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "map").font(.largeTitle).foregroundStyle(.secondary)
                Text("Enter your Google Maps key in Diagnostics to load the live map.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGray5))
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button("Load demo route") { model.loadDemoRoute() }
                    .buttonStyle(.bordered)
                if model.isDriving {
                    Button("Stop") { model.stopDriving() }.buttonStyle(.bordered)
                } else {
                    Button("Run sim") { model.startSimulation() }.buttonStyle(.borderedProminent)
                }
                Button("Fetch") { model.fetchRoute() }
                    .buttonStyle(.bordered)
                    .disabled(model.directionsAPIKey.isEmpty || model.isFetchingRoute)
            }
            if !model.isDriving {
                Button("Walk (live GPS)") { model.startLiveWalk() }
                    .buttonStyle(.bordered)
                    .disabled(model.route.path.count < 2 || model.location.location == nil)
            }
            Text(model.routeStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A tap sets the destination from the raw coordinate, no geocoding. The model seeds the origin
    /// from the live GPS fix when it is empty, so "Fetch" works in one tap.
    private func setDestination(_ point: GeoPoint) {
        model.setDestinationFromTap(point)
    }
}
