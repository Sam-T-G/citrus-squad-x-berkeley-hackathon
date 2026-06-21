import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// Turns the hardware volume buttons into a press-and-hold trigger for the voice agent. iOS gives no
/// down/up event for the volume buttons and no hook at all for the side or Action button, so the one
/// physical signal available is that *holding* a volume button auto-repeats. A single tap produces
/// one volume change and is ignored; a hold produces a burst, which fires `onPress` once. The wearer
/// can summon the agent by feel without finding the on-screen control.
///
/// The press is absorbed: the system volume is parked back at mid-level after each change so it never
/// drifts to a rail (which would stop the auto-repeat), and an off-screen volume view hides the HUD.
///
/// VERIFY ON DEVICE: the auto-repeat timing is OS-specific. If a hold does not register, widen
/// `releaseMilliseconds`; if a single tap triggers, raise `pressesToFire`.
@MainActor
final class VolumeButtonTrigger {
    var onPress: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private let volumeView = MPVolumeView(frame: CGRect(x: -4000, y: -4000, width: 1, height: 1))
    private var observation: NSKeyValueObservation?

    private let baseline: Float = 0.5
    private let pressesToFire = 2
    private let releaseMilliseconds = 700

    private var realPresses = 0
    private var firedThisHold = false
    private var releaseTask: Task<Void, Never>?

    func start(hostedIn view: UIView) {
        view.addSubview(volumeView)            // an in-hierarchy MPVolumeView suppresses the volume HUD
        try? session.setActive(true)           // outputVolume KVO needs an active session
        park(baseline)
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let volume = session.outputVolume
            Task { @MainActor in self?.handle(volume: volume) }
        }
    }

    func stop() {
        observation?.invalidate(); observation = nil
        releaseTask?.cancel(); releaseTask = nil
        volumeView.removeFromSuperview()
    }

    private func handle(volume: Float) {
        // Our own reset writes the baseline; count only real button presses, not that echo.
        if abs(volume - baseline) < 0.01 { return }
        park(baseline)            // absorb the change so volume never drifts to a rail

        realPresses += 1
        // No press for a while means the button was released: clear the hold.
        let ms = releaseMilliseconds
        releaseTask?.cancel()
        releaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard let self else { return }
            self.realPresses = 0
            self.firedThisHold = false
        }
        // A hold is a burst of presses; fire once when it crosses the threshold.
        if realPresses >= pressesToFire && !firedThisHold {
            firedThisHold = true
            onPress?()
        }
    }

    private func park(_ value: Float) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = value
    }
}

/// Hidden SwiftUI host that keeps a `VolumeButtonTrigger` alive while the screen is shown. Drop it in
/// as a tiny background so it does not affect layout.
struct VolumeButtonTriggerView: UIViewRepresentable {
    let onPress: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        context.coordinator.trigger.onPress = onPress
        context.coordinator.trigger.start(hostedIn: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.trigger.onPress = onPress
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.trigger.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        let trigger = VolumeButtonTrigger()
    }
}
