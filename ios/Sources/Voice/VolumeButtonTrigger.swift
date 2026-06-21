import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// Turns the hardware volume buttons into a single trigger for the voice agent. A press of volume up
/// or down fires `onPress`, which the app wires to toggle a voice turn, so the wearer can start
/// talking by feel without finding the on-screen button. iOS does not let an app hook the side or
/// Action button, so the volume buttons are the only physical option.
///
/// The press is absorbed: the system volume is parked back at mid-level after each press so both
/// directions keep registering, and an off-screen volume view suppresses the on-screen volume HUD.
///
/// VERIFY ON DEVICE: the MPVolumeView slider reset and HUD suppression are long-standing but
/// undocumented behaviors. Confirm on the demo phone, and if a press stops registering at the volume
/// rails, the reset is not taking.
@MainActor
final class VolumeButtonTrigger {
    var onPress: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private let volumeView = MPVolumeView(frame: CGRect(x: -4000, y: -4000, width: 1, height: 1))
    private var observation: NSKeyValueObservation?
    private let baseline: Float = 0.5
    private var ignoringOwnReset = false

    func start(hostedIn view: UIView) {
        view.addSubview(volumeView)            // an in-hierarchy MPVolumeView suppresses the volume HUD
        try? session.setActive(true)           // outputVolume KVO needs an active session
        park(baseline)
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.handlePress() }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        volumeView.removeFromSuperview()
    }

    private func handlePress() {
        guard !ignoringOwnReset else { return }   // skip the KVO our own reset fires
        onPress?()
        ignoringOwnReset = true
        park(baseline)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            ignoringOwnReset = false
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
