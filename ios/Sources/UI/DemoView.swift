import SwiftUI

/// The demo visualizer, laid out like a first-person navigation HUD so judges can read the whole
/// system at a glance: the live camera fills the screen as the wearer's-eye view, a circular radar
/// minimap sits in the corner, the next direction reads large across the top, and a slim status bar
/// shows the live belt cue, the active motor, what the vision tier sees, and how close the LiDAR
/// thinks an obstacle is. The wearer is blind; this screen is for the sighted room.
///
/// Each piece is backed by the same state the belt acts on, so what the judges read matches what the
/// wearer feels. Controls to bring the camera up and drive a route sit in the bottom tray.
struct DemoView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            CameraBackdrop(depth: model.depth, detections: model.detections)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topRow
                Spacer(minLength: 0)
                bottomStack
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Top: directions + radar

    private var topRow: some View {
        HStack(alignment: .top, spacing: 12) {
            DirectionsBanner(model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
            Minimap(model: model, diameter: 116)
        }
    }

    // MARK: - Bottom: status + controls

    private var bottomStack: some View {
        VStack(spacing: 10) {
            if let flag = model.interference.active {
                EarlyWarningPill(flag: flag)
            }
            StatusBar(model: model)
            controls
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if model.depth.isRunning {
                    hudButton("Stop camera", tint: .gray) { model.depth.stop() }
                } else {
                    hudButton("Start camera", tint: .accentColor) { model.depth.start() }
                        .disabled(!model.depth.isSupported)
                }
                hudButton("Load route", tint: .gray) { model.loadDemoRoute() }
                if model.isDriving {
                    hudButton("Stop", tint: .gray) { model.stopDriving() }
                } else {
                    hudButton("Run sim", tint: .accentColor) { model.startSimulation() }
                }
            }
            if !model.isDriving {
                hudButton("Walk (live GPS)", tint: .gray) { model.startLiveWalk() }
                    .disabled(model.route.path.count < 2 || model.location.location == nil)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func hudButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }
}

// MARK: - Directions banner

/// The big, glanceable instruction across the top: the next turn and how far to it, with the trip
/// remaining and a rough walking time underneath. Reads the navigation cue the belt follows, so it
/// matches what the wearer is told. Hazards show on the status bar below, not here, the same way a
/// nav app keeps the road instruction steady.
private struct DirectionsBanner: View {
    let model: AppModel

    var body: some View {
        let visual = ProductionView.visual(for: bannerCue)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: visual.symbol)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(visual.color)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(visual.text)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(distanceToNextText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if hasRoute {
                HStack(spacing: 14) {
                    Label(remainingText, systemImage: "flag.checkered")
                    Label(etaText, systemImage: "clock")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(visual.text), \(distanceToNextText)")
    }

    /// The route turn to show. Falls back to a calm "Walk on" so the banner never blanks mid-route.
    private var bannerCue: ResolvedCue {
        guard let cue = model.route.currentCue else { return .idle }
        return ResolvedCue(event: cue.event, mask: cue.mask, intensity: 0, source: .turn)
    }

    private var hasRoute: Bool { model.route.path.count >= 2 }

    private var distanceToNextText: String {
        let distance = model.route.distanceToNext
        guard distance >= 0 else { return "follow the route" }
        return String(format: "in %.0f m", distance)
    }

    private var remainingMeters: Double {
        if model.route.remaining >= 0 { return model.route.remaining }
        guard let position = model.navPosition else { return 0 }
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
}

// MARK: - Status bar

/// The live readout under the camera: the cue the belt is actually firing (which preempts to a hazard
/// when one is active), which motor that lights, what the vision tier counts, and how close the LiDAR
/// reads ahead. This is the proof line, the place the safety story shows itself during a walk.
private struct StatusBar: View {
    let model: AppModel

    var body: some View {
        let visual = ProductionView.visual(for: model.resolved)
        return HStack(spacing: 10) {
            cueChip(visual)
                .layoutPriority(1)
            BeltMini(mask: model.resolved.mask, accent: visual.color)
            stats
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func cueChip(_ visual: (text: String, symbol: String, color: Color)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: visual.symbol)
                .font(.title3.bold())
                .foregroundStyle(visual.color)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 0) {
                Text(visual.text)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(model.resolved.source.rawValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
    }

    private var stats: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Label("\(model.detections.detections.count)", systemImage: "eye")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
            depthReadout
        }
    }

    @ViewBuilder
    private var depthReadout: some View {
        if model.depth.isRunning {
            let hazard = model.depth.currentHazard
            HStack(spacing: 4) {
                Image(systemName: hazard == nil ? "checkmark.circle" : "exclamationmark.triangle.fill")
                Text(hazard.map { String(format: "%.1f m", $0.distanceMeters) } ?? "clear")
            }
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(hazard == nil ? .green : .orange)
        } else {
            Text("LiDAR off")
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// A compact four-dot belt in a plus layout for the HUD: the active quadrant glows in the cue color.
/// The full belt diagram lives in `BeltView`; this is the small always-on version for the status bar.
private struct BeltMini: View {
    let mask: QuadrantMask
    var accent: Color = .blue

    var body: some View {
        Grid(horizontalSpacing: 5, verticalSpacing: 5) {
            GridRow { spacer; dot(.front); spacer }
            GridRow { dot(.left); spacer; dot(.right) }
            GridRow { spacer; dot(.back); spacer }
        }
        .animation(.easeOut(duration: 0.15), value: mask)
        .accessibilityLabel("Active motors: \(activeLabel)")
    }

    private var spacer: some View { Color.clear.frame(width: 12, height: 12) }

    private func dot(_ quadrant: QuadrantMask) -> some View {
        let active = mask.contains(quadrant)
        return Circle()
            .fill(active ? accent : Color.white.opacity(0.22))
            .frame(width: 12, height: 12)
            .shadow(color: active ? accent.opacity(0.8) : .clear, radius: active ? 5 : 0)
    }

    private var activeLabel: String {
        var names: [String] = []
        if mask.contains(.front) { names.append("front") }
        if mask.contains(.left) { names.append("left") }
        if mask.contains(.right) { names.append("right") }
        if mask.contains(.back) { names.append("back") }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}

/// The early-warning advisory, surfaced as a slim pill above the status bar when the bearing tracker
/// flags a centered, looming object before LiDAR has a return.
private struct EarlyWarningPill: View {
    let flag: InterferenceFlag

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(headline).font(.caption.bold().monospaced())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.9), in: Capsule())
        .foregroundStyle(.black)
    }

    private var headline: String {
        let ttc = flag.timeToContactSeconds.map { String(format: "%.1fs", $0) } ?? "--"
        return "Heads up: \(flag.label) ahead, \(ttc)"
    }

    private var tint: Color {
        switch flag.confidence {
        case .low: return .yellow
        case .medium: return .orange
        case .high: return .red
        }
    }
}

#Preview {
    DemoView(model: AppModel())
}
