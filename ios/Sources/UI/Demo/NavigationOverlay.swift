import SwiftUI

/// The turn-by-turn banner that sits over the map. It reads the same nav state the belt acts on, so
/// what the judges read matches what the wearer feels: the next maneuver, how far to it, and the
/// distance and rough time left on the route.
///
/// Everything here is local arithmetic on data the app already has. No Google call is made to draw
/// or update this, so it costs nothing to leave running through the whole demo.
struct NavigationOverlay: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            maneuverRow
            if hasRoute {
                Divider()
                tripRow
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Next maneuver

    private var maneuverRow: some View {
        let visual = ProductionView.visual(for: bannerCue)
        return HStack(spacing: 14) {
            Image(systemName: visual.symbol)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(visual.color)
                .frame(width: 44)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(visual.text)
                    .font(.title3.bold())
                    .foregroundStyle(visual.color)
                Text(distanceToNextText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(visual.text), \(distanceToNextText)")
    }

    /// The route/turn cue to display. Falls back to a calm "Walk on" when no turn is staged, so the
    /// banner never goes blank mid-route. Hazard cues are the belt's job; this banner is navigation.
    private var bannerCue: ResolvedCue {
        guard let cue = model.route.currentCue else { return .idle }
        return ResolvedCue(event: cue.event, mask: cue.mask, intensity: 0, source: .turn)
    }

    private var distanceToNextText: String {
        let distance = model.route.distanceToNext
        guard distance >= 0 else { return "follow the route" }
        return String(format: "in %.0f m", distance)
    }

    // MARK: - Trip remaining

    private var tripRow: some View {
        HStack {
            Label(remainingText, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Label(etaText, systemImage: "clock")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    private var hasRoute: Bool { model.route.path.count >= 2 }

    /// Meters left to the destination. Prefers the route engine's live figure (set while driving in
    /// either simulate or live-GPS mode); falls back to measuring from the current position.
    private var remainingMeters: Double {
        if model.route.remaining >= 0 { return model.route.remaining }
        guard let position = currentPosition else { return 0 }
        return RouteMath.remainingDistance(from: position, along: model.route.path, segmentIndex: 0)
    }

    private var remainingText: String {
        let meters = remainingMeters
        if meters >= 1000 { return String(format: "%.1f km left", meters / 1000) }
        return String(format: "%.0f m left", meters)
    }

    private var etaText: String {
        let seconds = RouteMath.walkingETASeconds(forDistance: remainingMeters)
        guard seconds > 0 else { return "arrived" }
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes <= 1 ? "~1 min" : "~\(minutes) min"
    }

    /// Where the wearer is, per the active drive mode (simulated walker or live GPS fix).
    private var currentPosition: GeoPoint? { model.navPosition }
}
