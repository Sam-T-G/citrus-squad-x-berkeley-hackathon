import Testing
@testable import CitrusSquad

/// The early-warning layer's decision logic, proven on synthetic frame sequences with no camera.
/// The contract: centered AND looming fires, either cue alone stays silent, and a head turn does not
/// manufacture a flag. These mirror the pure-math discipline of `PersonFusionTests`.
struct BearingTrackerTests {

    private let hz = InterferenceParameters.detectionHz

    /// A height sequence that grows by `ratePerFrame` of its current value each step, i.e. a box
    /// looming toward the wearer. `frames` long, starting at `start`.
    private func loomingHeights(start: Double, ratePerFrame: Double, frames: Int) -> [Double] {
        var h = [start]
        for _ in 1..<frames { h.append((h.last ?? start) * (1 + ratePerFrame)) }
        return h
    }

    // MARK: - The center-band test

    @Test func centerBandIsTheMiddleThird() {
        #expect(BearingTracker.isCentered(0.5))
        #expect(BearingTracker.isCentered(0.34))
        #expect(BearingTracker.isCentered(0.66))
        #expect(!BearingTracker.isCentered(0.2))
        #expect(!BearingTracker.isCentered(0.8))
    }

    // MARK: - The looming test

    @Test func loomRateIsPositiveForAGrowingBox() {
        let heights = loomingHeights(start: 0.1, ratePerFrame: 0.05, frames: 6)
        let loom = BearingTracker.loomRatePerSecond(heightHistory: heights, hz: hz)
        #expect(loom != nil)
        #expect((loom ?? 0) > 0)
    }

    @Test func loomRateIsZeroForAStaticBox() {
        let heights = [Double](repeating: 0.2, count: 6)
        let loom = BearingTracker.loomRatePerSecond(heightHistory: heights, hz: hz) ?? -1
        #expect(loom == 0)
    }

    // MARK: - The combined flag

    @Test func centeredAndLoomingFires() {
        let heights = loomingHeights(start: 0.2, ratePerFrame: 0.08, frames: 6)
        let flag = BearingTracker.evaluate(label: "pole",
                                           centeredStreak: InterferenceParameters.heldFrames,
                                           heightHistory: heights, framesTracked: 6, hz: hz)
        #expect(flag != nil)
        #expect(flag?.side == .front)
        #expect((flag?.timeToContactSeconds ?? .infinity) <= InterferenceParameters.ttcWarnSeconds)
    }

    @Test func centeredButStaticDoesNotFire() {
        let heights = [Double](repeating: 0.2, count: 6)
        let flag = BearingTracker.evaluate(label: "pole",
                                           centeredStreak: InterferenceParameters.heldFrames * 3,
                                           heightHistory: heights, framesTracked: 6, hz: hz)
        #expect(flag == nil)
    }

    @Test func loomingButNotYetCenteredDoesNotFire() {
        let heights = loomingHeights(start: 0.2, ratePerFrame: 0.08, frames: 6)
        let flag = BearingTracker.evaluate(label: "pole",
                                           centeredStreak: InterferenceParameters.heldFrames - 1,
                                           heightHistory: heights, framesTracked: 6, hz: hz)
        #expect(flag == nil)
    }

    // MARK: - The yaw gate (self-rotation must not manufacture a streak)

    @Test func headTurnDoesNotBuildACenteredStreak() {
        let tracker = BearingTracker()
        let centered = BoxObservation(label: "pole", confidence: 0.9, horizontalNorm: 0.5, boxHeight: 0.3)
        // Many centered frames, but every one is during a turn faster than the yaw gate.
        var flags: [InterferenceFlag] = []
        for frame in 0..<10 {
            flags = tracker.update(observations: [centered],
                                   yawRateRadPerSecond: InterferenceParameters.yawGateRadPerSecond + 0.2,
                                   frameIndex: frame)
        }
        #expect(flags.isEmpty)
    }

    @Test func walkingStraightAtACenteredLoomingObjectFires() {
        let tracker = BearingTracker()
        var flags: [InterferenceFlag] = []
        // Fast, steady looming: high confidence needs both a long centered streak and a short
        // time-to-contact, so the box has to be growing briskly, not just drifting in.
        let heights = loomingHeights(start: 0.2, ratePerFrame: 0.15, frames: 10)
        for frame in 0..<heights.count {
            let obs = BoxObservation(label: "pole", confidence: 0.9, horizontalNorm: 0.5,
                                     boxHeight: heights[frame])
            flags = tracker.update(observations: [obs], yawRateRadPerSecond: 0.0, frameIndex: frame)
        }
        #expect(!flags.isEmpty)
        #expect(flags.first?.confidence == .high)
    }
}
