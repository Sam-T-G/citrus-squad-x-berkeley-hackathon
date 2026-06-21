import Foundation
import CoreGraphics

/// Pure depth-fusion math, ported line for line from Cole's `cv/pipeline.py`. No frame I/O lives
/// here, so every rule is unit tested against the same cases as the Python `tests/test_pipeline.py`.
/// All distances are meters; zero and non-finite depths are treated as "no LiDAR return".
///
/// The detector turns an ARKit frame into the inputs these functions expect, then hands the result
/// to `VisionHazardSource`. Keeping the math separate is what lets us prove the on-device numbers
/// match the proven Python before we ever run on hardware.
enum PersonFusion {
    /// Pixel window in the depth buffer to sample for a detection box. Half-open: `x1..<x2`.
    struct Window: Equatable, Sendable {
        var x1: Int
        var y1: Int
        var x2: Int
        var y2: Int

        var isEmpty: Bool { x2 <= x1 || y2 <= y1 }
    }

    /// Scale an RGB-pixel detection box into the depth buffer and shrink it to its inner `cropRatio`.
    /// Mirrors `cv/pipeline.py`: scale by depth/rgb, then pad each side by `(1 - cropRatio) / 2` so
    /// the sampled region sits inside the object and dodges the LiDAR edge bleed at its boundary.
    /// Integer truncation matches Python `int(...)` so the window lands on the same pixels.
    static func depthWindow(boxPx: CGRect, rgbSize: CGSize, depthSize: CGSize,
                            cropRatio: Double) -> Window {
        guard rgbSize.width > 0, rgbSize.height > 0 else { return Window(x1: 0, y1: 0, x2: 0, y2: 0) }
        let sx = depthSize.width / rgbSize.width
        let sy = depthSize.height / rgbSize.height
        let dx1 = Int(boxPx.minX * sx)
        let dy1 = Int(boxPx.minY * sy)
        let dx2 = Int(boxPx.maxX * sx)
        let dy2 = Int(boxPx.maxY * sy)
        let padX = Int(Double(dx2 - dx1) * (1 - cropRatio) / 2)
        let padY = Int(Double(dy2 - dy1) * (1 - cropRatio) / 2)
        let x1 = max(0, dx1 + padX)
        let y1 = max(0, dy1 + padY)
        let x2 = min(Int(depthSize.width), dx2 - padX)
        let y2 = min(Int(depthSize.height), dy2 - padY)
        return Window(x1: x1, y1: y1, x2: x2, y2: y2)
    }

    /// Collect the valid depths inside `window` from a row-major depth array, then reduce. A depth is
    /// valid when it is finite and strictly greater than zero (zero is the iPhone LiDAR no-return
    /// sentinel). Both results are nil when nothing in the window is valid.
    static func sample(depth: [Float], width: Int, height: Int,
                       window: Window) -> (median: Double?, min: Double?) {
        guard !window.isEmpty, width > 0, height > 0 else { return (nil, nil) }
        var valid: [Float] = []
        for y in window.y1..<window.y2 where y >= 0 && y < height {
            let rowBase = y * width
            for x in window.x1..<window.x2 where x >= 0 && x < width {
                let value = depth[rowBase + x]
                if value.isFinite && value > 0 { valid.append(value) }
            }
        }
        return medianMin(valid)
    }

    /// Reduce already-collected valid depths to (median, closest). Shared by the array path above and
    /// the detector's direct CVPixelBuffer sampling so both produce identical numbers.
    static func medianMin(_ valid: [Float]) -> (median: Double?, min: Double?) {
        guard let closest = valid.min() else { return (nil, nil) }
        return (Double(median(valid)), Double(closest))
    }

    /// Median matching NumPy: the middle value for an odd count, the mean of the two middle values
    /// for an even count.
    static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let n = sorted.count
        guard n > 0 else { return 0 }
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Horizontal position of the box center, 0 at the far left edge and 1 at the far right, matching
    /// `horizontal_norm` in `cv/detection.py`.
    static func horizontalNorm(boxPx: CGRect, rgbWidth: Double) -> Double {
        guard rgbWidth > 0 else { return 0.5 }
        return Double((boxPx.minX + boxPx.maxX) / 2) / rgbWidth
    }

    /// Map the horizontal position to a belt quadrant in thirds, matching the left/center/right band
    /// convention in `DepthService`. The tap fires on the side the person is on, per `docs/12` §1.
    static func quadrant(horizontalNorm h: Double) -> QuadrantMask {
        if h < 1.0 / 3.0 { return .left }
        if h < 2.0 / 3.0 { return .front }
        return .right
    }
}
