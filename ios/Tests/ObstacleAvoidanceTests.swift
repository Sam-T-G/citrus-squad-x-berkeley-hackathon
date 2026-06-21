import Testing
@testable import CitrusSquad

/// The LiDAR obstacle-avoidance layer. Pure decision plus the debounce filter, so both are tested
/// off-device. Threshold 1.8 m and near 0.5 m match the demo config.
struct ObstacleAvoidanceDecisionTests {
    private let threshold = 1.8
    private let near = 0.5

    @Test func clearWhenNothingInRange() {
        // -1 means no reading; large values are beyond threshold.
        #expect(ObstacleAvoidance.decide(left: -1, center: 5, right: -1, threshold: threshold, near: near) == .clear)
    }

    @Test func sideObstacleWithClearPathIsLeftToNavigation() {
        // Something close on the left, but the path ahead (center) is open and not at danger range.
        let directive = ObstacleAvoidance.decide(left: 1.0, center: 5, right: 5, threshold: threshold, near: near)
        #expect(directive == .clear)
    }

    @Test func centerBlockedSteersToTheOpenSide() {
        // Wall ahead, right is roomier than left -> go right.
        let directive = ObstacleAvoidance.decide(left: 1.2, center: 1.0, right: 5, threshold: threshold, near: near)
        #expect(directive == .steer(.right, 1.0))
    }

    @Test func centerBlockedPicksRoomierSideWhenBothOpen() {
        // Both sides open, left has more clearance -> go left.
        let directive = ObstacleAvoidance.decide(left: 6, center: 1.0, right: 3, threshold: threshold, near: near)
        #expect(directive == .steer(.left, 1.0))
    }

    @Test func bothSidesHaveReturnsButOneIsPassableSteers() {
        // Both sides report something within the generous 1.8 m threshold, but the right side has
        // room to pass (1.2 m > min side clearance), so steer right instead of stopping.
        let directive = ObstacleAvoidance.decide(left: 1.0, center: 1.0, right: 1.2, threshold: threshold, near: near)
        #expect(directive == .steer(.right, 1.0))
    }

    @Test func boxedInWithNoRoomEitherSideStops() {
        // Path ahead blocked and both sides closer than the min side clearance: no way through, stop.
        let directive = ObstacleAvoidance.decide(left: 0.7, center: 0.8, right: 0.6, threshold: threshold, near: near)
        #expect(directive == .stop(0.6))
    }

    @Test func dangerCloseOnOneSideStillTriggers() {
        // Center open but something inside danger range on the left -> steer right (away from it).
        let directive = ObstacleAvoidance.decide(left: 0.4, center: 5, right: 5, threshold: threshold, near: near)
        #expect(directive == .steer(.right, 0.4))
    }
}

struct AvoidanceFilterTests {
    @Test func steerActivatesOnlyAfterSettling() {
        var filter = AvoidanceFilter(settleTicks: 2, holdTicks: 2)
        let raw = AvoidanceDirective.steer(.right, 1.0)
        #expect(filter.update(raw) == .clear)   // first tick: still settling
        #expect(filter.update(raw) == raw)       // second tick: activates
    }

    @Test func stickyToTheChosenSide() {
        var filter = AvoidanceFilter(settleTicks: 1, holdTicks: 2)
        #expect(filter.update(.steer(.right, 1.0)) == .steer(.right, 1.0))
        // Raw flips to the other side; the filter holds the original to avoid whipping the wearer.
        #expect(filter.update(.steer(.left, 1.0)) == .steer(.right, 1.0))
    }

    @Test func clearReleasesOnlyAfterHold() {
        var filter = AvoidanceFilter(settleTicks: 1, holdTicks: 2)
        #expect(filter.update(.steer(.right, 1.0)) == .steer(.right, 1.0))
        #expect(filter.update(.clear) == .steer(.right, 1.0))   // first clear: still held
        #expect(filter.update(.clear) == .clear)                // second clear: releases
    }

    @Test func stopFiresImmediately() {
        var filter = AvoidanceFilter(settleTicks: 3, holdTicks: 3)
        #expect(filter.update(.stop(0.4)) == .stop(0.4))   // danger does not wait to settle
    }
}
