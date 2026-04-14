import Foundation

/// One pixel-column's worth of decimated samples.
public struct DecimationBucket: Sendable, Equatable {
    public let minValue: Float
    public let maxValue: Float
    public let isPopulated: Bool

    public static let empty = DecimationBucket(
        minValue: .greatestFiniteMagnitude,
        maxValue: -.greatestFiniteMagnitude,
        isPopulated: false
    )
}

/// Result of a min/max decimation pass. One bucket per pixel column in the target
/// rendering width. Downstream code walks the bucket array and emits a vertical
/// segment from `(col, minValue)` → `(col, maxValue)` for every populated bucket,
/// which collapses to a single point where a bucket contains exactly one sample.
public struct DecimatedTrace: Sendable, Equatable {
    public let pixelWidth: Int
    public let buckets: [DecimationBucket]

    public init(pixelWidth: Int, buckets: [DecimationBucket]) {
        self.pixelWidth = pixelWidth
        self.buckets = buckets
    }

    public var isEmpty: Bool { buckets.allSatisfy { !$0.isPopulated } }
}

public enum Decimator {
    /// Bucket `values` into `pixelWidth` pixel columns across `viewport`, keeping only
    /// the per-column min and max. Assumes `timeValues` is non-empty, monotonically
    /// non-decreasing, and aligned 1:1 with `values`.
    ///
    /// Samples outside the viewport aren't bucketed directly, but the polyline IS
    /// clipped against the viewport edges so the leftmost and rightmost visible
    /// segments render correctly. Specifically, if the sample immediately before
    /// the viewport exists, we linearly interpolate the line between it and the
    /// first in-viewport sample at `t == viewport.lowerBound` and bucket that
    /// interpolated value at column 0. Same treatment for the right edge. Without
    /// this, zoomed-in views would be missing their leftmost / rightmost line
    /// segments because the out-of-viewport endpoints got dropped.
    ///
    /// When `fillInterpolatedGaps` is true (the default — what the plot panel uses),
    /// empty buckets that sit between two populated ones are filled in with linearly-
    /// interpolated values. This does not change the rendered polyline's appearance
    /// (the drawn line is the same straight segment either way) but it's essential for
    /// **hit testing**: without filled buckets, a click in the middle of a PWL
    /// transition between sparse samples (e.g., a zoomed-in view of a clock edge)
    /// finds no populated columns within the hit radius and fails to select the
    /// trace. Callers that want pure decimation semantics (unit tests) pass `false`.
    ///
    /// Complexity: O(samples in the viewport + pixel width).
    public static func decimate(
        timeValues: [Double],
        values: [Float],
        viewport: ClosedRange<Double>,
        pixelWidth: Int,
        fillInterpolatedGaps: Bool = true
    ) -> DecimatedTrace {
        precondition(pixelWidth > 0, "pixelWidth must be positive")
        precondition(
            timeValues.count == values.count,
            "timeValues and values must be the same length"
        )

        var buckets = Array(repeating: DecimationBucket.empty, count: pixelWidth)

        let tMin = viewport.lowerBound
        let tMax = viewport.upperBound
        let tSpan = tMax - tMin
        guard tSpan > 0, !timeValues.isEmpty else {
            return DecimatedTrace(pixelWidth: pixelWidth, buckets: buckets)
        }

        // Binary-search the slice of timeValues that lies within the viewport. This
        // keeps decimation cost proportional to the visible sample count rather than
        // the full trace length.
        let startIndex = lowerBound(timeValues, target: tMin)
        let endIndex = upperBoundInclusive(timeValues, target: tMax)

        let widthDouble = Double(pixelWidth)
        let lastColumnIndex = pixelWidth - 1

        // Left-edge clip: if a sample exists just before the viewport and at least
        // one sample exists inside or after it, linearly interpolate the polyline
        // value at `tMin` and plant it in column 0. This ensures the first visible
        // segment draws from the true polyline value at the left edge rather than
        // starting at whichever in-viewport sample happens to exist first.
        if startIndex > 0 && startIndex < timeValues.count {
            let tPrev = timeValues[startIndex - 1]
            let vPrev = values[startIndex - 1]
            let tNext = timeValues[startIndex]
            let vNext = values[startIndex]
            let interp: Float
            if tNext == tPrev {
                interp = vPrev
            } else {
                let frac = (tMin - tPrev) / (tNext - tPrev)
                interp = vPrev + Float(frac) * (vNext - vPrev)
            }
            buckets[0] = DecimationBucket(
                minValue: interp,
                maxValue: interp,
                isPopulated: true
            )
        }

        // In-viewport samples.
        for i in startIndex..<endIndex {
            let t = timeValues[i]
            let v = values[i]

            let normalized = (t - tMin) / tSpan   // 0.0 ... 1.0
            var col = Int(normalized * widthDouble)
            if col < 0 { col = 0 }
            if col > lastColumnIndex { col = lastColumnIndex }

            let bucket = buckets[col]
            if bucket.isPopulated {
                let newMin = v < bucket.minValue ? v : bucket.minValue
                let newMax = v > bucket.maxValue ? v : bucket.maxValue
                buckets[col] = DecimationBucket(
                    minValue: newMin,
                    maxValue: newMax,
                    isPopulated: true
                )
            } else {
                buckets[col] = DecimationBucket(
                    minValue: v,
                    maxValue: v,
                    isPopulated: true
                )
            }
        }

        // Right-edge clip: mirror of the left clip. If a sample exists just after
        // the viewport and at least one exists at or before it, interpolate at
        // `tMax` and plant the value in the last column.
        if endIndex < timeValues.count && endIndex > 0 {
            let tPrev = timeValues[endIndex - 1]
            let vPrev = values[endIndex - 1]
            let tNext = timeValues[endIndex]
            let vNext = values[endIndex]
            let interp: Float
            if tNext == tPrev {
                interp = vPrev
            } else {
                let frac = (tMax - tPrev) / (tNext - tPrev)
                interp = vPrev + Float(frac) * (vNext - vPrev)
            }
            let col = lastColumnIndex
            let existing = buckets[col]
            if existing.isPopulated {
                let newMin = min(existing.minValue, interp)
                let newMax = max(existing.maxValue, interp)
                buckets[col] = DecimationBucket(
                    minValue: newMin,
                    maxValue: newMax,
                    isPopulated: true
                )
            } else {
                buckets[col] = DecimationBucket(
                    minValue: interp,
                    maxValue: interp,
                    isPopulated: true
                )
            }
        }

        if fillInterpolatedGaps {
            fillGaps(in: &buckets)
        }

        return DecimatedTrace(pixelWidth: pixelWidth, buckets: buckets)
    }

    /// Walks the bucket array and fills empty columns that sit between two populated
    /// ones with a linearly-interpolated single value, keyed off each populated
    /// neighbor's midpoint. The resulting rendered polyline is visually identical to
    /// the pre-fill version (same straight line), but the filled buckets give hit
    /// testing real data to find at every pixel along the segment.
    private static func fillGaps(in buckets: inout [DecimationBucket]) {
        let width = buckets.count
        guard width > 1 else { return }

        var lastPopulated: Int = -1
        for col in 0..<width where buckets[col].isPopulated {
            lastPopulated = col
            break
        }
        guard lastPopulated >= 0 else { return }

        var nextSearchStart = lastPopulated + 1
        while nextSearchStart < width {
            var nextPopulated = -1
            for col in nextSearchStart..<width where buckets[col].isPopulated {
                nextPopulated = col
                break
            }
            guard nextPopulated >= 0 else { break }

            let gapStart = lastPopulated + 1
            let gapEnd = nextPopulated
            if gapEnd > gapStart {
                let bucketA = buckets[lastPopulated]
                let bucketB = buckets[nextPopulated]
                let valueA = (bucketA.minValue + bucketA.maxValue) / 2
                let valueB = (bucketB.minValue + bucketB.maxValue) / 2
                let span = Float(nextPopulated - lastPopulated)
                for col in gapStart..<gapEnd {
                    let fraction = Float(col - lastPopulated) / span
                    let v = valueA + fraction * (valueB - valueA)
                    buckets[col] = DecimationBucket(
                        minValue: v,
                        maxValue: v,
                        isPopulated: true
                    )
                }
            }

            lastPopulated = nextPopulated
            nextSearchStart = nextPopulated + 1
        }
    }

    // MARK: - Binary search helpers

    /// Smallest index `i` such that `array[i] >= target`. If no such element exists,
    /// returns `array.count`.
    private static func lowerBound(_ array: [Double], target: Double) -> Int {
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if array[mid] < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// Smallest index `i` such that `array[i] > target`. Used as an exclusive upper
    /// bound for inclusive-range slicing (`startIndex..<endIndex`).
    private static func upperBoundInclusive(_ array: [Double], target: Double) -> Int {
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if array[mid] <= target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
