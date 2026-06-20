import Foundation

/// LC2 event codes. Byte 0 of the packet. Values are fixed by `docs/03-protocol.md` and the
/// ESP32 firmware depends on them. Do not renumber.
enum LC2Event: UInt8, Sendable {
    case idle = 0x00          // heartbeat filler, no servo
    case visionDanger = 0x10  // Coral-side only; the phone never emits this
    case turnSlight = 0x20    // single tap, gentle directional cue
    case turnNow = 0x21       // triple tap, sharp or imminent turn
    case turnAround = 0x22    // triple tap on both Far servos, U-turn
    case arrived = 0x23       // sweep left to right, final maneuver
    case obstacleNear = 0x40  // sustained tap-train, phone LiDAR proximity (provisional, Tier-1)

    var label: String {
        switch self {
        case .idle: return "idle"
        case .visionDanger: return "vision-danger"
        case .turnSlight: return "turn-slight"
        case .turnNow: return "turn-now"
        case .turnAround: return "turn-around"
        case .arrived: return "arrived"
        case .obstacleNear: return "obstacle-near"
        }
    }
}

/// Which servo(s) fire. Byte 1. Bit 0 = Far Left, bit 1 = Left, bit 2 = Right, bit 3 = Far Right.
struct QuadrantMask: OptionSet, Sendable, Equatable {
    let rawValue: UInt8

    static let farLeft = QuadrantMask(rawValue: 1 << 0)   // 0x01
    static let left = QuadrantMask(rawValue: 1 << 1)      // 0x02
    static let right = QuadrantMask(rawValue: 1 << 2)     // 0x04
    static let farRight = QuadrantMask(rawValue: 1 << 3)  // 0x08

    static let centerMass: QuadrantMask = [.left, .right]          // 0x06
    static let bothFar: QuadrantMask = [.farLeft, .farRight]       // 0x09
    static let all: QuadrantMask = [.farLeft, .left, .right, .farRight] // 0x0F
}

/// Four bytes on the wire: event, quadrant mask, intensity hint, sequence number.
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

    /// Heartbeat filler. No servo, no travel.
    static func idle(sequence: UInt8) -> LC2Packet {
        LC2Packet(event: .idle, mask: [], intensity: 0, sequence: sequence)
    }
}
