import SwiftUI

/// The full-screen route map, raised from the HUD's corner radar when it is tapped. Unlike the radar
/// it does not follow the wearer: it fits the whole route so the room can see the path end to end, and
/// allows pan and zoom to explore it. The wearer's live position still shows as the map's blue dot.
/// A close control stows it back to the corner.
struct ExpandedMapView: View {
    let model: AppModel
    /// Stow the map and return to the HUD.
    var onClose: () -> Void

    private var hasKey: Bool { !model.directionsAPIKey.isEmpty }
    private var hasRoute: Bool { model.route.path.count >= 2 }

    var body: some View {
        ZStack(alignment: .top) {
            mapOrPlaceholder
                .ignoresSafeArea()
            topBar
        }
        .background(.black)
    }

    @ViewBuilder
    private var mapOrPlaceholder: some View {
        if hasKey {
            // isFollowing: false makes the camera fit the whole route once, so the path shows end to
            // end; gestures let the room explore it. Tapping a coordinate is a no-op here: this is a
            // viewer, not a place to change the destination.
            GoogleMapView(waypoints: model.simulator.waypoints,
                          position: model.navPosition,
                          heading: model.navHeading,
                          isFollowing: false,
                          showsChrome: false,
                          allowsGestures: true,
                          onTapCoordinate: { _ in })
        } else {
            ZStack {
                Color.black
                VStack(spacing: 8) {
                    Image(systemName: "map").font(.largeTitle)
                    Text("Enter your Google Maps key in Diagnostics to load the map.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding()
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close map")

            Spacer()

            Text(summaryText)
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var summaryText: String {
        guard hasRoute else { return "No route loaded" }
        let meters = model.route.remaining
        guard meters >= 0 else { return "Route" }
        if meters >= 1000 { return String(format: "%.1f km left", meters / 1000) }
        return String(format: "%.0f m left", meters)
    }
}
