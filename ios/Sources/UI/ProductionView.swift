import SwiftUI

/// The wearer's screen. A blind wearer drives everything by voice (hold the hardware side button and
/// speak), so this stays calm and button-free: the big cue the belt is firing right now, the belt
/// diagram, and the agent conversation. The manual run controls (connect, calibrate, load a route,
/// simulate) live in the Diagnostics tab for a sighted operator. One injected `AppModel`.
struct ProductionView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                cueDisplay
                BeltView(mask: model.resolved.mask, accent: Self.visual(for: model.resolved).color)
                voicePanel
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background {
            // The hardware side button (press and hold) starts a voice turn, so a wearer who cannot
            // see the screen talks to the app by feel. No on-screen talk button is needed.
            VolumeButtonTriggerView { Task { await model.voice.toggle() } }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .onChange(of: model.resolved.event) { _, newEvent in
            Feedback.cueChanged(to: newEvent, source: model.resolved.source)
        }
        .onChange(of: model.voice.state) { _, newState in
            // Audible state tones so the wearer knows the agent is listening, thinking, or speaking.
            switch newState {
            case .connecting: Feedback.voiceActivating()
            case .listening: Feedback.voiceReady()
            case .thinking: Feedback.voiceProcessing()
            default: break
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Wander").font(.largeTitle.bold())
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

    // MARK: - Voice conversation

    /// The agent conversation, shown elegantly: a live state line (the agent is listening, thinking,
    /// or speaking), the last thing the wearer said, and the last thing the agent replied. There is no
    /// talk button; the wearer holds the hardware side button to speak. See `VolumeButtonTriggerView`.
    private var voicePanel: some View {
        let status = Self.voiceStatus(for: model.voice.state)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: status.symbol)
                    .font(.title3.bold())
                    .foregroundStyle(status.color)
                    .symbolEffect(.pulse, isActive: model.voice.state == .listening)
                    .contentTransition(.symbolEffect(.replace))
                Text(status.title)
                    .font(.headline)
                    .foregroundStyle(status.color)
                Spacer()
            }

            if model.voice.lastTranscript.isEmpty && model.voice.lastReply.isEmpty {
                Text(model.voice.isConfigured
                     ? "Hold the side button and speak."
                     : "Add voice keys to enable the assistant.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                if !model.voice.lastTranscript.isEmpty {
                    Text("\u{201C}\(model.voice.lastTranscript)\u{201D}")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if !model.voice.lastReply.isEmpty {
                    Text(model.voice.lastReply)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20))
        .animation(.easeOut(duration: 0.2), value: model.voice.lastReply)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceAccessibilityLabel)
    }

    private var voiceAccessibilityLabel: String {
        var parts = [Self.voiceStatus(for: model.voice.state).title]
        if !model.voice.lastTranscript.isEmpty { parts.append("You said, \(model.voice.lastTranscript)") }
        if !model.voice.lastReply.isEmpty { parts.append(model.voice.lastReply) }
        return parts.joined(separator: ". ")
    }

    /// Voice state to a calm status line for the hold-to-talk model (no tap affordance).
    private static func voiceStatus(for state: VoiceState) -> (title: String, symbol: String, color: Color) {
        switch state {
        case .idle: return ("Ready", "mic.fill", .accentColor)
        case .connecting: return ("Connecting\u{2026}", "mic.fill", .gray)
        case .listening: return ("Listening\u{2026}", "waveform", .blue)
        case .thinking: return ("Thinking\u{2026}", "ellipsis", .indigo)
        case .speaking: return ("Speaking\u{2026}", "speaker.wave.2.fill", .green)
        case .unavailable: return ("Voice unavailable", "mic.slash.fill", .gray)
        case .failed: return ("Voice error", "exclamationmark.triangle.fill", .orange)
        }
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
