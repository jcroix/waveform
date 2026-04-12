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
    /// non-decreasing, and aligned 1:1 with `values`. Samples outside the viewport are
    /// skipped.
    ///
    /// Complexity: O(number of samples in the viewport) — binary-searches the boundaries
    /// so zoomed-in views don't pay for samples outside the visible window.
    public static func decimate(
        timeValues: [Double],
        values: [Float],
        viewport: ClosedRange<Double>,
        pixelWidth: Int
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
        // the full trace length, which matters when Phase 8 pan/zoom lands.
        let startIndex = lowerBound(timeValues, target: tMin)
        let endIndex = upperBoundInclusive(timeValues, target: tMax)
        guard startIndex < endIndex else {
            return DecimatedTrace(pixelWidth: pixelWidth, buckets: buckets)
        }

        let widthDouble = Double(pixelWidth)
        let lastColumnIndex = pixelWidth - 1

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

        return DecimatedTrace(pixelWidth: pixelWidth, buckets: buckets)
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
