import Foundation
import CoreMotion
import Observation

/// Accelerometer and gyroscope at a 50 Hz target. Optional for Tier-2 (the route cue only
/// needs 1 Hz heading), kept for the bonus features in `docs/04-phone-side.md`: step counting
/// between GPS fixes and fall detection.
///
/// CoreMotion delivers updates on the queue we pass. We pass `.main`, so the handler runs on
/// the main thread and `assumeIsolated` is the correct bridge into our `@MainActor` state.
@MainActor
@Observable
final class MotionService {
    private let motion = CMMotionManager()
    private var startTime: Date?

    private(set) var accelX: Double = 0
    private(set) var accelY: Double = 0
    private(set) var accelZ: Double = 0
    private(set) var gyroX: Double = 0
    private(set) var gyroY: Double = 0
    private(set) var gyroZ: Double = 0
    private(set) var accelSamples: Int = 0
    private(set) var gyroSamples: Int = 0
    private(set) var isRunning = false

    let accelAvailable: Bool
    let gyroAvailable: Bool

    init() {
        accelAvailable = motion.isAccelerometerAvailable
        gyroAvailable = motion.isGyroAvailable
    }

    /// Wearer turn rate about the vertical axis, in radians per second. The early-warning layer uses
    /// it to discount "constant bearing" readings that are really the wearer panning the camera.
    ///
    /// CALIBRATION: this assumes the phone is mounted upright in portrait, so body yaw is rotation
    /// about the device's long axis (`gyroY`). If the belt mount tilts the phone, the yaw axis is a
    /// blend of `gyroY` and `gyroZ`; confirm on device by turning in place and watching this value
    /// spike. Sign does not matter, the gate reads the magnitude.
    var yawRateRadPerSecond: Double { gyroY }

    /// Achieved accelerometer rate over the run, in Hz. Confirms we hit the 50 Hz target.
    var accelRateHz: Double {
        guard let start = startTime, accelSamples > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        return elapsed > 0 ? Double(accelSamples) / elapsed : 0
    }

    func start() {
        guard accelAvailable, gyroAvailable else { return }
        startTime = Date()
        accelSamples = 0
        gyroSamples = 0
        motion.accelerometerUpdateInterval = CitrusSquadConfig.motionUpdateInterval
        motion.gyroUpdateInterval = CitrusSquadConfig.motionUpdateInterval

        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            MainActor.assumeIsolated {
                self.accelX = data.acceleration.x
                self.accelY = data.acceleration.y
                self.accelZ = data.acceleration.z
                self.accelSamples += 1
            }
        }

        motion.startGyroUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            MainActor.assumeIsolated {
                self.gyroX = data.rotationRate.x
                self.gyroY = data.rotationRate.y
                self.gyroZ = data.rotationRate.z
                self.gyroSamples += 1
            }
        }

        isRunning = true
    }

    func stop() {
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        isRunning = false
    }
}
