import SwiftUI
import UIKit

/// Tap-to-talk control for the voice layer. Tap to start a turn (the device plays a listening tone),
/// speak, then tap again to send (a processing tone). Tapping while it connects, thinks, or speaks
/// cancels. It is big and findable by touch, and the tones tell a wearer who cannot see the screen
/// what state it is in. Continuous belt guidance is unaffected; this only drives voice.
struct VoiceControlView: View {
    let voice: VoiceModel

    var body: some View {
        VStack(spacing: 8) {
            button
            transcriptLine
            failureLine
        }
        .onChange(of: voice.state) { _, newState in
            switch newState {
            case .connecting: Feedback.voiceActivating()
            case .listening: Feedback.voiceReady()
            case .thinking: Feedback.voiceProcessing()
            default: break
            }
        }
    }

    // MARK: - Button

    private var button: some View {
        let look = Self.look(for: voice.state)
        return Button {
            Task { await voice.toggle() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: look.symbol)
                    .font(.system(size: 34, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: voice.state == .listening)
                Text(look.title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .foregroundStyle(.white)
            .background(look.color)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .disabled(!voice.isConfigured)
        .opacity(voice.isConfigured ? 1 : 0.5)
        .accessibilityLabel(look.title)
        .accessibilityHint(look.hint)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var transcriptLine: some View {
        if !voice.lastTranscript.isEmpty || !voice.lastReply.isEmpty {
            VStack(spacing: 2) {
                if !voice.lastTranscript.isEmpty {
                    Text("\u{201C}\(voice.lastTranscript)\u{201D}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !voice.lastReply.isEmpty {
                    Text(voice.lastReply)
                        .font(.caption.weight(.medium))
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var failureLine: some View {
        if case .failed(let reason) = voice.state {
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Voice error: \(reason)")
        }
    }

    // MARK: - State to look

    private static func look(for state: VoiceState) -> (title: String, symbol: String, color: Color, hint: String) {
        switch state {
        case .idle:
            return ("Tap to talk", "mic.fill", .accentColor, "Tap to start a voice command")
        case .connecting:
            return ("Connecting\u{2026}", "mic.fill", .gray, "Tap to cancel")
        case .listening:
            return ("Listening\u{2026}", "waveform", .blue, "Speak your command, then wait for the answer")
        case .thinking:
            return ("Thinking\u{2026}", "ellipsis", .indigo, "Tap to cancel")
        case .speaking:
            return ("Speaking\u{2026}", "speaker.wave.2.fill", .green, "Tap to cancel")
        case .unavailable:
            return ("Voice unavailable", "mic.slash.fill", .gray, "Voice keys are not set")
        case .failed:
            return ("Tap to retry", "exclamationmark.triangle.fill", .orange, "Tap to try again")
        }
    }
}

#Preview {
    VoiceControlView(voice: VoiceModel())
        .padding()
}
