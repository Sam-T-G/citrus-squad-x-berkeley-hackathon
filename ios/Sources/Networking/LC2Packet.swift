import Foundation

/// LC2 event codes. Byte 0 of the packet. Values are fixed by `docs/03-protocol.md` and the
/// ESP32 firmware depends on them. Do not renumber.
enum LC2Event: UInt8, Sendable {
    case idle = 0x00          // heartbeat filler, no motor
    case visionDanger = 0x10  // proximity from the camera, taps Back
    case turnSlight = 0x20    // single tap, gentle rotate cue (Left or Right)
    case turnNow = 0x21       // triple tap, sharp rotate cue (Left or Right)
    case turnAround = 0x22    // triple tap on both rotate motors, U-turn
    case arrived = 0x23       // sweep all motors, final maneuver
    case forward = 0x24       // single tap Front, on-course / proceed straight
    case obstacleNear = 0x40  // sustained tap-train on Back, LiDAR proximity

    var label: String {
        switch self {
        case .idle: return "idle"
        case .visionDanger: return "vision-danger"
        case .turnSlight: return "turn-slight"
        case .turnNow: return "turn-now"
        case .turnAround: return "turn-around"
        case .arrived: return "arrived"
        case .forward: return "forward"
        case .obstacleNear: return "obstacle-near"
        }
    }
}

/// Which motor(s) fire. Byte 1. The belt has four motors arranged around the torso:
/// bit 0 = Front (forward), bit 1 = Left (rotate left), bit 2 = Right (rotate right),
/// bit 3 = Back (proximity).
struct QuadrantMask: OptionSet, Sendable, Equatable {
    let rawValue: UInt8

    static let front = QuadrantMask(rawValue: 1 << 0)  // 0x01 forward / on course
    static let left = QuadrantMask(rawValue: 1 << 1)   // 0x02 rotate left
    static let right = QuadrantMask(rawValue: 1 << 2)  // 0x04 rotate right
    static let back = QuadrantMask(rawValue: 1 << 3)   // 0x08 proximity

    static let rotate: QuadrantMask = [.left, .right]              // 0x06 turn-around
    static let all: QuadrantMask = [.front, .left, .right, .back]  // 0x0F sweep
}

/// Four bytes on the wire: event, motor mask, intensity hint, sequence number.
/// Layout is fixed by `docs/03-protocol.md`.
struct LC2Packet: Sendable, Equatable {
    var event: LC2Event
    var mask: QuadrantMask
    var intensity: UInt8 = defaultIntensity
    var sequence: UInt8 = 0

    /// Default tap travel distance. 0..255, per the protocol doc.
    static let defaultIntensity = CitrusSquadConfig.intensityDefault

    /// The exact bytes that go on the wire.
    func encoded() -> Data {
        Data([event.rawValue, mask.rawValue, intensity, sequence])
    }

    /// Heartbeat filler. No motor, no travel.
    static func idle(sequence: UInt8) -> LC2Packet {
        LC2Packet(event: .idle, mask: [], intensity: 0, sequence: sequence)
    }
}
