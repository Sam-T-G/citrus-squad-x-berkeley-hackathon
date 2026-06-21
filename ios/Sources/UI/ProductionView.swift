import SwiftUI

/// The production operator screen for the demo. One glanceable display of what the belt is telling
/// the wearer right now, plus the few controls a run needs: connect the belt, calibrate, run the
/// route. The full per-sensor diagnostics live in their own tab (`ControlPanelView`). Both share
/// one injected `AppModel`.
struct ProductionView: View {
    let model: AppModel
    @State private var flash = false

    var body: some View {
        VStack(spacing: 24) {
            header
            cueDisplay
            BeltView(mask: model.resolved.mask, accent: Self.visual(for: model.resolved).color)
            VoiceControlView(voice: model.voice)
            Spacer()
            controls
        }
        .padding()
        .background {
            // Hardware volume buttons trigger a voice turn, so the wearer can talk by feel.
            VolumeButtonTriggerView { Task { await model.voice.toggle() } }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            Color.green
                .opacity(flash ? 0.4 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .onChange(of: model.resolved.event) { _, newEvent in
            Feedback.cueChanged(to: newEvent, source: model.resolved.source)
        }
    }

    /// Brief green flash to confirm calibration without needing the screen.
    private func flashScreen() {
        withAnimation(.easeOut(duration: 0.12)) { flash = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.easeIn(duration: 0.35)) { flash = false }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Citrus Squad").font(.largeTitle.bold())
                Text(model.route.isCalibrated ? "calibrated" : "not calibrated")
                    .font(.caption)
                    .foregroundStyle(model.route.isCalibrated ? Color.green : Color.secondary)
            }
            Spacer()
            linkBadge
        }
    }

    private var linkBadge: some View {
        let connected = model.transmitting && model.link.connectionState == "ready"
        let label = connected ? "belt connected" : (model.transmitting ? "linking…" : "belt off")
        return HStack(spacing: 6) {
            Circle()
                .fill(connected ? Color.green : Color.secondary)
                .frame(width: 10, height: 10)
            Text(label).font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    // MARK: - Cue display

    private var cueDisplay: some View {
        let visual = Self.visual(for: model.resolved)
        return VStack(spacing: 16) {
            Image(systemName: visual.symbol)
                .font(.system(size: 110, weight: .bold))
                .foregroundStyle(visual.color)
                .contentTransition(.symbolEffect(.replace))
            Text(visual.text)
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(visual.color)
            if model.simulator.isRunning, model.route.distanceToNext > 0 {
                Text(String(format: "in %.0f m", model.route.distanceToNext))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .background(visual.color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current cue: \(visual.text)")
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if model.transmitting {
                    bigButton("Disconnect", tint: .gray) { model.stopLink() }
                } else {
                    bigButton("Connect belt", tint: .accentColor) { model.startLink() }
                }
                bigButton("Calibrate", tint: .gray) {
                    if model.calibrate() {
                        Feedback.calibrationConfirmed()
                        flashScreen()
                    }
                }
                .disabled(model.location.trueHeading < 0)
            }
            HStack(spacing: 12) {
                bigButton("Load route", tint: .gray) { model.loadDemoRoute() }
                if model.isDriving {
                    bigButton("Stop", tint: .gray) { model.stopDriving() }
                }
            }
            if !model.isDriving {
                HStack(spacing: 12) {
                    bigButton("Run sim", tint: .accentColor) { model.startSimulation() }
                    bigButton("Walk GPS", tint: .accentColor) { model.startLiveWalk() }
                        .disabled(model.route.path.count < 2 || model.location.location == nil)
                }
            }
            Text(model.routeStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func bigButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }

    // MARK: - Cue visuals

    /// Map the resolved cue to a big direction word, an SF Symbol, and a color.
    static func visual(for cue: ResolvedCue) -> (text: String, symbol: String, color: Color) {
        switch cue.event {
        case .idle:
            return ("Walk on", "figure.walk", .secondary)
        case .forward:
            return ("Forward", "arrow.up", .blue)
        case .turnSlight:
            return cue.mask.contains(.right)
                ? ("Slight right", "arrow.turn.up.right", .blue)
                : ("Slight left", "arrow.turn.up.left", .blue)
        case .turnNow:
            return cue.mask.contains(.right)
                ? ("Turn right", "arrow.turn.up.right", .blue)
                : ("Turn left", "arrow.turn.up.left", .blue)
        case .turnAround:
            // The avoidance layer reuses turn-around as a full-stop reorient; show it as a stop.
            return cue.source == .hazard
                ? ("Stop", "hand.raised.fill", .orange)
                : ("Turn around", "arrow.uturn.down", .blue)
        case .arrived:
            return ("Arrived", "checkmark.circle.fill", .green)
        case .obstacleNear:
            // Avoidance steers toward the open side; show which way to go.
            if cue.mask.contains(.left) { return ("Obstacle, go left", "arrow.turn.up.left", .orange) }
            if cue.mask.contains(.right) { return ("Obstacle, go right", "arrow.turn.up.right", .orange) }
            return ("Obstacle", "exclamationmark.triangle.fill", .orange)
        case .visionDanger:
            // The early-warning tier reuses this event for a soft pre-LiDAR heads-up; show it as an
            // advisory, not a confirmed person.
            if cue.source == .earlyWarning {
                return ("Heads up, ahead", "exclamationmark.circle", .yellow)
            }
            // Say "person" only when the detector actually recognized a person. For any other
            // navigation-class object, name it ("Backpack ahead"); fall back to "Obstruction ahead"
            // when the class is unknown.
            if cue.label?.lowercased() == "person" {
                return ("Person ahead", "figure.stand", .orange)
            }
            if let label = cue.label, !label.isEmpty {
                let name = label.prefix(1).uppercased() + label.dropFirst()
                return ("\(name) ahead", "exclamationmark.triangle.fill", .orange)
            }
            return ("Obstruction ahead", "exclamationmark.triangle.fill", .orange)
        }
    }
}

#Preview {
    ProductionView(model: AppModel())
}
