import Testing
import Foundation
@testable import WAND

/// The single most valuable test in the repo per `SWIFT.md`: a wire-format bug is invisible until
/// the belt does the wrong thing, so we pin the exact bytes against `docs/03-protocol.md`.
struct LC2PacketTests {
    @Test func turnSlightRightGoldenVector() {
        let packet = LC2Packet(event: .turnSlight, mask: .right, intensity: 192, sequence: 5)
        #expect(Array(packet.encoded()) == [0x20, 0x04, 0xC0, 0x05])
    }

    @Test func turnAroundUsesBothFarServos() {
        let packet = LC2Packet(event: .turnAround, mask: .bothFar, intensity: 192, sequence: 0)
        #expect(Array(packet.encoded()) == [0x22, 0x09, 0xC0, 0x00])
    }

    @Test func idleIsAllZeroExceptSequence() {
        let packet = LC2Packet.idle(sequence: 17)
        #expect(Array(packet.encoded()) == [0x00, 0x00, 0x00, 0x11])
    }

    @Test func obstacleNearIsCenterMass() {
        let packet = LC2Packet(event: .obstacleNear, mask: .centerMass, intensity: 192, sequence: 0)
        #expect(Array(packet.encoded()) == [0x40, 0x06, 0xC0, 0x00])
    }

    @Test func maskBitsMatchProtocol() {
        #expect(QuadrantMask.farLeft.rawValue == 0x01)
        #expect(QuadrantMask.left.rawValue == 0x02)
        #expect(QuadrantMask.right.rawValue == 0x04)
        #expect(QuadrantMask.farRight.rawValue == 0x08)
        #expect(QuadrantMask.centerMass.rawValue == 0x06)
        #expect(QuadrantMask.bothFar.rawValue == 0x09)
        #expect(QuadrantMask.all.rawValue == 0x0F)
    }
}
