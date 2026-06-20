import Testing
@testable import WAND

/// The pure band-to-mask mapping from `docs/12` section 3. The closest in-threshold band wins, and
/// a side band escalates to its Far servo inside the near distance.
struct DepthHazardTests {
    private let threshold = 1.8
    private let near = 0.5

    @Test func clearWhenNothingInThreshold() {
        #expect(DepthService.hazard(left: -1, center: 3.0, right: -1, threshold: threshold, near: near) == nil)
    }

    @Test func obstacleOnLeftFiresLeft() {
        let hazard = DepthService.hazard(left: 1.0, center: -1, right: -1, threshold: threshold, near: near)
        #expect(hazard?.mask == .left)
    }

    @Test func obstacleOnRightFiresRight() {
        let hazard = DepthService.hazard(left: -1, center: -1, right: 1.0, threshold: threshold, near: near)
        #expect(hazard?.mask == .right)
    }

    @Test func obstacleDeadAheadFiresCenterMass() {
        let hazard = DepthService.hazard(left: -1, center: 1.0, right: -1, threshold: threshold, near: near)
        #expect(hazard?.mask == .centerMass)
    }

    @Test func veryCloseLeftEscalatesToFarLeft() {
        let hazard = DepthService.hazard(left: 0.3, center: -1, right: -1, threshold: threshold, near: near)
        #expect(hazard?.mask == .farLeft)
    }

    @Test func closestBandWins() {
        // Right is nearer than left, so the cue fires right.
        let hazard = DepthService.hazard(left: 1.5, center: -1, right: 0.8, threshold: threshold, near: near)
        #expect(hazard?.mask == .right)
        #expect(hazard?.distanceMeters == 0.8)
    }
}
