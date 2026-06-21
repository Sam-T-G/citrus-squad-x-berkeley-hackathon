import Testing
@testable import CitrusSquad

/// Proximity mapping: any obstacle within threshold warns on the Back motor, with the nearest
/// distance carried for intensity grading.
struct DepthHazardTests {
    private let threshold = 1.8
    private let near = 0.5

    @Test func clearWhenNothingInThreshold() {
        #expect(DepthService.hazard(left: -1, center: 3.0, right: -1, threshold: threshold, near: near) == nil)
    }

    @Test func obstacleWarnsBack() {
        let hazard = DepthService.hazard(left: 1.0, center: -1, right: -1, threshold: threshold, near: near)
        #expect(hazard?.mask == .back)
        #expect(hazard?.kind == .obstacle)
    }

    @Test func reportsNearestDistanceAcrossBands() {
        let hazard = DepthService.hazard(left: 1.5, center: -1, right: 0.8, threshold: threshold, near: near)
        #expect(hazard?.mask == .back)
        #expect(hazard?.distanceMeters == 0.8)
    }

    @Test func ignoresReadingsBeyondThreshold() {
        #expect(DepthService.hazard(left: 2.5, center: 3.0, right: 5.0, threshold: threshold, near: near) == nil)
    }
}
