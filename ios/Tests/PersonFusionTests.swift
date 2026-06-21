import Testing
import CoreGraphics
@testable import CitrusSquad

/// Depth-fusion math, ported from Cole's `tests/test_pipeline.py`. When these pass, the on-device
/// numbers provably match the proven Python pipeline.
struct PersonFusionTests {

    // Scale 0.4 (rgb 300 -> depth 120). bbox (100,100)-(300,300) scales to (40,40)-(120,120); the
    // inner 50% crop is (60,60)-(100,100).
    private let rgb = CGSize(width: 300, height: 300)
    private let dep = CGSize(width: 120, height: 120)
    private let box = CGRect(x: 100, y: 100, width: 200, height: 200)

    private func filledDepth(window value: Float, filler: Float) -> [Float] {
        var depth = [Float](repeating: filler, count: 120 * 120)
        for y in 60..<100 { for x in 60..<100 { depth[y * 120 + x] = value } }
        return depth
    }

    @Test func windowIsInnerCrop() {
        let win = PersonFusion.depthWindow(boxPx: box, rgbSize: rgb, depthSize: dep, cropRatio: 0.5)
        #expect(win == PersonFusion.Window(x1: 60, y1: 60, x2: 100, y2: 100))
    }

    @Test func medianComesFromTheCorrectRegion() {
        // Filler 5.0 outside the window must not leak into the median.
        var depth = filledDepth(window: 2.0, filler: 5.0)
        depth[80 * 120 + 80] = 1.0
        let win = PersonFusion.depthWindow(boxPx: box, rgbSize: rgb, depthSize: dep, cropRatio: 0.5)
        let (median, _) = PersonFusion.sample(depth: depth, width: 120, height: 120, window: win)
        #expect(median == 2.0)
    }

    @Test func depthMinIsTheClosestPoint() {
        var depth = filledDepth(window: 2.0, filler: 5.0)
        depth[80 * 120 + 80] = 1.0
        let win = PersonFusion.depthWindow(boxPx: box, rgbSize: rgb, depthSize: dep, cropRatio: 0.5)
        let (_, minDepth) = PersonFusion.sample(depth: depth, width: 120, height: 120, window: win)
        #expect(minDepth == 1.0)
    }

    @Test func allNaNRegionReturnsNil() {
        let depth = [Float](repeating: .nan, count: 120 * 120)
        let win = PersonFusion.depthWindow(boxPx: box, rgbSize: rgb, depthSize: dep, cropRatio: 0.5)
        let (median, minDepth) = PersonFusion.sample(depth: depth, width: 120, height: 120, window: win)
        #expect(median == nil)
        #expect(minDepth == nil)
    }

    @Test func zeroDepthIsTreatedAsMissing() {
        var depth = [Float](repeating: 0.0, count: 120 * 120)
        let win = PersonFusion.depthWindow(boxPx: box, rgbSize: rgb, depthSize: dep, cropRatio: 0.5)
        let (m0, n0) = PersonFusion.sample(depth: depth, width: 120, height: 120, window: win)
        #expect(m0 == nil && n0 == nil)
        depth[70 * 120 + 70] = 3.0
        let (m1, n1) = PersonFusion.sample(depth: depth, width: 120, height: 120, window: win)
        #expect(m1 == 3.0 && n1 == 3.0)
    }

    @Test func centerBoxGivesHalf() {
        #expect(PersonFusion.horizontalNorm(boxPx: CGRect(x: 100, y: 0, width: 100, height: 10), rgbWidth: 300) == 0.5)
    }

    @Test func leftBoxBelowHalf() {
        #expect(PersonFusion.horizontalNorm(boxPx: CGRect(x: 0, y: 0, width: 60, height: 10), rgbWidth: 300) < 0.5)
    }

    @Test func rightBoxAboveHalf() {
        #expect(PersonFusion.horizontalNorm(boxPx: CGRect(x: 240, y: 0, width: 60, height: 10), rgbWidth: 300) > 0.5)
    }

    @Test func quadrantSplitsInThirds() {
        #expect(PersonFusion.quadrant(horizontalNorm: 0.1) == .left)
        #expect(PersonFusion.quadrant(horizontalNorm: 0.5) == .front)
        #expect(PersonFusion.quadrant(horizontalNorm: 0.9) == .right)
    }

    @Test func medianMatchesNumPy() {
        #expect(PersonFusion.median([1, 2, 3, 4]) == 2.5)
        #expect(PersonFusion.median([5, 1, 3]) == 3.0)
    }
}
