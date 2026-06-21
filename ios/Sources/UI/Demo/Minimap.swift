import SwiftUI

/// A small circular map in the corner of the Demo HUD, styled like a video-game radar: heading-up,
/// the wearer at the center, the route drawn as a line, framed by a ring with a forward pip at the
/// top. It reuses the same free Google map as the big map and stays locked on the wearer, so nothing
/// here is billed; only a route fetch ever is.
struct Minimap: View {
    let model: AppModel
    var diameter: CGFloat = 136

    private var hasKey: Bool { !model.directionsAPIKey.isEmpty }

    var body: some View {
        ZStack {
            mapOrPlaceholder
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.85), lineWidth: 3) }
        .overlay(alignment: .top) { forwardPip }
        .overlay(alignment: .bottom) { distanceChip }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    @ViewBuilder
    private var mapOrPlaceholder: some View {
        if hasKey {
            // Always follow the wearer so the radar stays centered and heading-up, walking or idle.
            GoogleMapView(waypoints: model.simulator.waypoints,
                          position: model.navPosition,
                          heading: model.navHeading,
                          isFollowing: model.navPosition != nil,
                          showsChrome: false,
                          allowsGestures: false,
                          onTapCoordinate: { _ in })
        } else {
            ZStack {
                Color.black.opacity(0.55)
                VStack(spacing: 4) {
                    Image(systemName: "map").font(.title3)
                    Text("Map key in\nDiagnostics")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    /// The triangle at the top edge: on a heading-up radar, up is always the way the wearer faces, so
    /// this reads as "forward."
    private var forwardPip: some View {
        Triangle()
            .fill(.white)
            .frame(width: 16, height: 11)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .offset(y: -5)
    }

    /// Meters left on the route, the one number a glance at the radar wants.
    private var distanceChip: some View {
        Text(remainingText)
            .font(.caption2.bold().monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
            .padding(.bottom, 8)
    }

    private var remainingText: String {
        let meters = model.route.remaining
        guard meters >= 0, model.route.path.count >= 2 else { return "no route" }
        if meters >= 1000 { return String(format: "%.1f km", meters / 1000) }
        return String(format: "%.0f m", meters)
    }
}

/// An upward-pointing triangle for the radar's forward pip.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
