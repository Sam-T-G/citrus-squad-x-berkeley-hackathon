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
    /// Whether the corner radar is raised to the full-screen route map.
    @State private var mapExpanded = false

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

            if mapExpanded {
                ExpandedMapView(model: model) {
                    withAnimation(.easeInOut(duration: 0.25)) { mapExpanded = false }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)))
                .zIndex(1)
            }
        }
    }

    // MARK: - Top: directions + radar

    private var topRow: some View {
        HStack(alignment: .top, spacing: 12) {
            DirectionsBanner(model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
            Minimap(model: model, diameter: 116)
                // A clear layer above the radar's map view captures the tap so it reliably raises the
                // full route map; a small glyph hints that the radar expands.
                .overlay {
                    Circle()
                        .fill(.clear)
                        .contentShape(Circle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { mapExpanded = true } }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                        .offset(x: -8, y: -8)
                        .allowsHitTesting(false)
                }
                .accessibilityElement()
                .accessibilityLabel("Route radar")
                .accessibilityHint("Expands the full route map")
                .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: - Bottom: status + controls

    private var bottomStack: some View {
        VStack(spacing: 10) {
            if let flag = model.interference.active {
                EarlyWarningPill(flag: flag)
            }
            StatusBar(model: model)
            LidarBars(depth: model.depth)
            controls
        }
        .frame(maxWidth: .infinity)
    }

    /// The judge-facing controls: bring the camera up, and talk. Destination is set by voice (the
    /// locked decision), so the bench buttons (load route, run sim, walk) live in Diagnostics, not
    /// here. A Stop appears only while a voice-started walk is running.
    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                if model.depth.isRunning {
                    hudButton("Stop camera", tint: .gray) { model.depth.stop() }
                } else {
                    hudButton("Start camera", tint: .accentColor) { model.depth.start() }
                        .disabled(!model.depth.isSupported)
                }
                talkButton
            }
            // Manual triggers for the Claude tier, for a demo without the mic. Both need a live camera
            // frame and an Anthropic key; hidden otherwise. Off the safety path like the voice path.
            if model.depth.isRunning && model.claudeConfigured {
                HStack(spacing: 14) {
                    hudButton("Read sign", tint: .accentColor) {
                        Task { await model.runDemoCommand(.readSign) }
                    }
                    hudButton("Around me", tint: .accentColor) {
                        Task { await model.runDemoCommand(.describeSurroundings) }
                    }
                }
            }
            if model.isDriving {
                hudButton("Stop", tint: .gray) { model.stopDriving() }
            }
            voiceTranscript
            demoLine
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    /// The voice entry for the demo: tap to talk, the button reflects the live voice state, and the
    /// same begin/think/ready tones the wearer relies on fire on the state change.
    private var talkButton: some View {
        let look = Self.talkLook(for: model.voice.state)
        return Button {
            Task { await model.voice.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: look.symbol)
                    .symbolEffect(.pulse, isActive: model.voice.state == .listening)
                Text(look.title)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(look.color)
        .disabled(!model.voice.isConfigured)
        .opacity(model.voice.isConfigured ? 1 : 0.5)
        .onChange(of: model.voice.state) { _, newState in
            switch newState {
            case .connecting: Feedback.voiceActivating()
            case .listening: Feedback.voiceReady()
            case .thinking: Feedback.voiceProcessing()
            default: break
            }
        }
        .accessibilityLabel(look.title)
        .accessibilityHint("Sets the destination by voice")
    }

    /// The line a manual Claude button produced, shown so the room can read the answer without audio.
    @ViewBuilder private var demoLine: some View {
        if !model.lastDemoLine.isEmpty {
            Text(model.lastDemoLine)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
        }
    }

    /// The last thing the wearer said and the agent's reply, so the room can follow a voice command.
    @ViewBuilder private var voiceTranscript: some View {
        if !model.voice.lastTranscript.isEmpty || !model.voice.lastReply.isEmpty {
            VStack(spacing: 2) {
                if !model.voice.lastTranscript.isEmpty {
                    Text("\u{201C}\(model.voice.lastTranscript)\u{201D}")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                if !model.voice.lastReply.isEmpty {
                    Text(model.voice.lastReply)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
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

    private static func talkLook(for state: VoiceState) -> (title: String, symbol: String, color: Color) {
        switch state {
        case .idle: return ("Talk", "mic.fill", .accentColor)
        case .connecting: return ("Connecting", "mic.fill", .gray)
        case .listening: return ("Listening", "waveform", .blue)
        case .thinking: return ("Thinking", "ellipsis", .indigo)
        case .speaking: return ("Speaking", "speaker.wave.2.fill", .green)
        case .unavailable: return ("Voice off", "mic.slash.fill", .gray)
        case .failed: return ("Retry", "exclamationmark.triangle.fill", .orange)
        }
    }
}

// MARK: - LiDAR bars

/// Three condensed, color-coded bars (left, center, right) giving the sighted room a glanceable read
/// of what the LiDAR sees in each band: green is clear, orange is closing, red is close. Mirrors the
/// three-band sampling the obstacle cue arbitrates on, so the bar that turns red is the side the belt
/// taps. Sits just above the controls so it reads next to the live cue.
private struct LidarBars: View {
    let depth: DepthService

    var body: some View {
        HStack(spacing: 8) {
            bar("L", depth.bands.left)
            bar("C", depth.bands.center)
            bar("R", depth.bands.right)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .opacity(depth.isRunning ? 1 : 0.55)
        .animation(.easeOut(duration: 0.2), value: depth.bands)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func bar(_ name: String, _ meters: Double) -> some View {
        let tint = color(for: meters)
        return VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.gradient)
                .frame(height: 10)
                .shadow(color: tint.opacity(depth.isRunning && meters > 0 ? 0.6 : 0), radius: 4)
            Text("\(name)  \(valueText(meters))")
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func color(for meters: Double) -> Color {
        guard depth.isRunning, meters > 0 else { return .white.opacity(0.18) }
        if meters <= CitrusSquadConfig.dangerNearMeters { return .red }
        if meters <= depth.thresholdMeters { return .orange }
        return .green
    }

    private func valueText(_ meters: Double) -> String {
        guard depth.isRunning else { return "off" }
        return meters > 0 ? String(format: "%.1fm", meters) : "\u{2014}"
    }

    private var accessibilityText: String {
        guard depth.isRunning else { return "LiDAR off" }
        func describe(_ meters: Double) -> String {
            guard meters > 0 else { return "no reading" }
            return String(format: "%.1f meters", meters)
        }
        return "LiDAR bands. Left \(describe(depth.bands.left)), "
            + "center \(describe(depth.bands.center)), right \(describe(depth.bands.right))."
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
        let symbol = isCalibrating ? "figure.walk" : visual.symbol
        let color = isCalibrating ? Color.yellow : visual.color
        let title = isCalibrating ? "Calibrating" : visual.text
        let subtitle = isCalibrating ? calibratingSubtitle : distanceToNextText
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(color)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if hasRoute, !isCalibrating {
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
        .contentShape(Rectangle())
        .onTapGesture { if isCalibrating { _ = model.calibrate() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(isCalibrating ? .isButton : [])
        .accessibilityHint(isCalibrating ? "Double tap to calibrate facing forward now" : "")
    }

    /// During a live walk the belt withholds turns until the mount offset locks; the banner says so.
    private var isCalibrating: Bool {
        model.mode == .live && !model.isHeadingCalibrated
    }

    /// Walking outdoors locks it best (it catches the magnetic bias), but a tap captures the current
    /// facing as forward so the demo is never stuck calibrating indoors or on the bench.
    private var calibratingSubtitle: String {
        "walk a few steps, or tap to set forward (\(Int(model.calibrationProgress * 100))%)"
    }

    /// The route turn to show. Falls back to a calm "Walk on" so the banner never blanks. Gated on a
    /// loaded route: with no destination the bench still computes `route.currentCue` toward its slider
    /// bearing for the diagnostics card, but the demo banner must not echo that as a real turn.
    private var bannerCue: ResolvedCue {
        guard hasRoute, let cue = model.route.currentCue else { return .idle }
        return ResolvedCue(event: cue.event, mask: cue.mask, intensity: 0, source: .turn)
    }

    private var hasRoute: Bool { model.route.path.count >= 2 }

    private var distanceToNextText: String {
        guard hasRoute else { return "no route loaded" }
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
        // Cue on the left, belt indicator centered between flexible spacers, sensor stats pinned to
        // their natural width on the right so "clear" and the distance never wrap. The cue text gives
        // way first when space is tight; the stats stay readable.
        return HStack(spacing: 12) {
            cueChip(visual)
            Spacer(minLength: 8)
            BeltMini(mask: model.resolved.mask, accent: visual.color)
            Spacer(minLength: 8)
            stats
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
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
                    .minimumScaleFactor(0.75)
                Text(model.resolved.source.rawValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
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
            .lineLimit(1)
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
