import AVFoundation

/// Plays a short synthesized chime through the media route. Unlike `AudioServicesPlaySystemSound`,
/// which is a UI sound the ringer switch silences and an active record session can mute, this routes
/// like the TTS, so it is heard at speaker volume even when the phone is on silent. Used for the
/// voice-ready confirmation, which the wearer must hear without looking at the screen.
@MainActor
final class ChimePlayer {
    static let shared = ChimePlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat?
    private var started = false

    /// One synthesized tone: frequency, when it enters, how long it rings, and how loud.
    private struct Voice {
        let freq: Double
        let start: Double
        let dur: Double
        let amp: Double
    }

    private init() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        format = fmt
        if let fmt {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
        }
    }

    /// A soft rising C5 -> G5 that rings together over a warm low C: gentle, full, and resolved.
    func playReady() {
        play(voices: [
            Voice(freq: 261.63, start: 0.00, dur: 0.95, amp: 0.10),   // C4, warmth underneath
            Voice(freq: 523.25, start: 0.00, dur: 0.80, amp: 0.16),   // C5
            Voice(freq: 783.99, start: 0.16, dur: 0.80, amp: 0.16),   // G5, a calm perfect fifth up
        ], total: 1.0)
    }

    private func play(voices: [Voice], total: Double) {
        guard let format, let buffer = Self.buffer(voices: voices, total: total, format: format) else { return }
        if !started {
            try? engine.start()
            player.play()
            started = true
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private static func buffer(voices: [Voice], total: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(total * sampleRate)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames

        // A few harmonics per tone give a fuller, bell-like timbre instead of a thin pure sine.
        let harmonics: [(mult: Double, gain: Double)] = [(1, 1.0), (2, 0.32), (3, 0.12)]

        for frame in 0..<Int(frames) {
            let t = Double(frame) / sampleRate
            var sample = 0.0
            for voice in voices {
                let local = t - voice.start
                if local < 0 || local > voice.dur { continue }
                let attack = min(1.0, local / 0.02)        // soft fade-in, no click
                let release = exp(-local * 2.4)            // gentle, slow ring-out
                let env = attack * release * voice.amp
                for harmonic in harmonics {
                    sample += sin(2.0 * .pi * voice.freq * harmonic.mult * local) * harmonic.gain * env
                }
            }
            channel[0][frame] = Float(sample * 0.5)        // headroom so the stacked tones do not clip
        }
        return buffer
    }
}
