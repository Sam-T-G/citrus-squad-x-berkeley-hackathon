import Testing
import Foundation
@testable import CitrusSquad

/// The single most valuable test in the repo: a wire-format bug is invisible until the belt does
/// the wrong thing, so we pin the exact bytes against `docs/03-protocol.md`. Motors are
/// front (0x01), left (0x02), right (0x04), back (0x08).
struct LC2PacketTests {
    @Test func turnSlightRightGoldenVector() {
        let packet = LC2Packet(event: .turnSlight, mask: .right, intensity: 192, sequence: 5)
        #expect(Array(packet.encoded()) == [0x20, 0x04, 0xC0, 0x05])
    }

    @Test func forwardTapsFront() {
        let packet = LC2Packet(event: .forward, mask: .front, intensity: 192, sequence: 0)
        #expect(Array(packet.encoded()) == [0x24, 0x01, 0xC0, 0x00])
    }

    @Test func turnAroundUsesBothRotateMotors() {
        let packet = LC2Packet(event: .turnAround, mask: .rotate, intensity: 192, sequence: 0)
        #expect(Array(packet.encoded()) == [0x22, 0x06, 0xC0, 0x00])
    }

    @Test func obstacleNearTapsBack() {
        let packet = LC2Packet(event: .obstacleNear, mask: .back, intensity: 192, sequence: 0)
        #expect(Array(packet.encoded()) == [0x40, 0x08, 0xC0, 0x00])
    }

    @Test func idleIsAllZeroExceptSequence() {
        let packet = LC2Packet.idle(sequence: 17)
        #expect(Array(packet.encoded()) == [0x00, 0x00, 0x00, 0x11])
    }

    @Test func maskBitsMatchProtocol() {
        #expect(QuadrantMask.front.rawValue == 0x01)
        #expect(QuadrantMask.left.rawValue == 0x02)
        #expect(QuadrantMask.right.rawValue == 0x04)
        #expect(QuadrantMask.back.rawValue == 0x08)
        #expect(QuadrantMask.rotate.rawValue == 0x06)
        #expect(QuadrantMask.all.rawValue == 0x0F)
    }
}
