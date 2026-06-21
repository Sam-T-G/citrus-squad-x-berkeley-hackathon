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

    private init() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        format = fmt
        if let fmt {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
        }
    }

    /// A bright two-note rise (E5 -> B5), the satisfying "agent is ready" confirmation.
    func playReady() {
        play(notes: [(659.25, 0.10), (987.77, 0.17)])
    }

    private func play(notes: [(freq: Double, dur: Double)]) {
        guard let format, let buffer = Self.buffer(notes: notes, format: format) else { return }
        if !started {
            try? engine.start()
            player.play()
            started = true
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private static func buffer(notes: [(freq: Double, dur: Double)], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let totalFrames = AVAudioFrameCount(notes.reduce(0) { $0 + $1.dur } * sampleRate)
        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = totalFrames

        var index = 0
        for note in notes {
            let count = Int(note.dur * sampleRate)
            for i in 0..<count where index < Int(totalFrames) {
                let t = Double(i) / sampleRate
                let attack = min(1.0, t / 0.006)          // quick fade-in, no click
                let decay = exp(-t * 5.5)                 // soft exponential tail
                let sample = sin(2.0 * .pi * note.freq * t) * attack * decay * 0.25
                channel[0][index] = Float(sample)
                index += 1
            }
        }
        return buffer
    }
}
