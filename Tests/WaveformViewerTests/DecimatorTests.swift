import Foundation
import Testing
@testable import WaveformViewer

// MARK: - Fixtures

private func uniformlySampled(count: Int, generator: (Int) -> Float) -> (times: [Double], values: [Float]) {
    var times: [Double] = []
    var values: [Float] = []
    times.reserveCapacity(count)
    values.reserveCapacity(count)
    for i in 0..<count {
        times.append(Double(i))
        values.append(generator(i))
    }
    return (times, values)
}

// MARK: - Decimator correctness

@Test func singlePointTraceProducesOnePopulatedBucket() {
    // A single sample at t = 0.5 inside a 0...1 viewport should populate exactly
    // one bucket — the one its normalized column index maps to.
    let decimated = Decimator.decimate(
        timeValues: [0.5],
        values: [3.14],
        viewport: 0...1,
        pixelWidth: 10
    )
    let populated = decimated.buckets.filter({ $0.isPopulated })
    #expect(populated.count == 1)
    #expect(populated[0].minValue == 3.14)
    #expect(populated[0].maxValue == 3.14)
}

@Test func denseConstantSignalPopulatesAllBuckets() {
    // 10 000 points of value 1.0 over 0...1. Every bucket should be populated with
    // min = max = 1.0.
    let (t, v) = uniformlySampled(count: 10_000) { _ in 1.0 }
    let times = t.map { $0 / 9999.0 }  // rescale to 0...1
    let decimated = Decimator.decimate(
        timeValues: times,
        values: v,
        viewport: 0...1,
        pixelWidth: 100
    )
    let allPopulated = decimated.buckets.filter({ !$0.isPopulated }).isEmpty
    #expect(allPopulated)
    for bucket in decimated.buckets {
        #expect(bucket.minValue == 1.0)
        #expect(bucket.maxValue == 1.0)
    }
}

@Test func sineWaveEnvelopeIsPreserved() {
    // 1 048 576 points of sin(2π * 20 * t) for t in [0, 1]. Decimate to 1 024 pixels
    // and check that the min/max envelope stays within ±1 and covers most of that
    // range.
    let sampleCount = 1 << 20
    var times: [Double] = []
    var values: [Float] = []
    times.reserveCapacity(sampleCount)
    values.reserveCapacity(sampleCount)
    for i in 0..<sampleCount {
        let t = Double(i) / Double(sampleCount - 1)
        times.append(t)
        values.append(Float(sin(2.0 * .pi * 20.0 * t)))
    }

    let decimated = Decimator.decimate(
        timeValues: times,
        values: values,
        viewport: 0...1,
        pixelWidth: 1024
    )

    let allPopulated = decimated.buckets.filter({ !$0.isPopulated }).isEmpty
    #expect(allPopulated)

    // Envelope should be bounded by [-1, 1] (with float-epsilon tolerance).
    for bucket in decimated.buckets {
        #expect(bucket.minValue >= -1.0001)
        #expect(bucket.maxValue <= 1.0001)
    }

    // Find the largest |min| and largest |max|. Both should be close to 1 since the
    // sine reaches its full amplitude many times over the viewport.
    let maxPositive = decimated.buckets.map(\.maxValue).max() ?? 0
    let minNegative = decimated.buckets.map(\.minValue).min() ?? 0
    #expect(maxPositive > 0.999)
    #expect(minNegative < -0.999)
}

@Test func viewportRestrictionClipsOutsideSamples() {
    // 1000 points of value i (as Float) at times 0..999. Decimate with viewport 200..300.
    let (times, values) = uniformlySampled(count: 1000) { i in Float(i) }
    let decimated = Decimator.decimate(
        timeValues: times,
        values: values,
        viewport: 200...300,
        pixelWidth: 100
    )

    // Min values in the populated buckets should fall in [200, 300].
    let populated = decimated.buckets.filter(\.isPopulated)
    #expect(!populated.isEmpty)
    for bucket in populated {
        #expect(bucket.minValue >= 200)
        #expect(bucket.maxValue <= 300)
    }
}

@Test func sparseSignalPureDecimationProducesSparseBuckets() {
    // 10 points spread across a viewport that maps to 1000 pixels — with
    // fillInterpolatedGaps OFF, at most 10 buckets should be populated.
    let (times, values) = uniformlySampled(count: 10) { i in Float(i) }
    let decimated = Decimator.decimate(
        timeValues: times,
        values: values,
        viewport: 0...9,
        pixelWidth: 1000,
        fillInterpolatedGaps: false
    )
    let populated = decimated.buckets.filter(\.isPopulated).count
    #expect(populated <= 10)
    #expect(populated >= 1)
}

@Test func sparseSignalFillsGapsBetweenPopulatedBuckets() {
    // Same 10 sparse points but with the default fill behavior — everything
    // BETWEEN the first and last populated columns should be filled in with
    // interpolated values, so hit-testing finds a bucket at every drawn pixel.
    let (times, values) = uniformlySampled(count: 10) { i in Float(i) }
    let decimated = Decimator.decimate(
        timeValues: times,
        values: values,
        viewport: 0...9,
        pixelWidth: 1000
    )

    // Identify the first and last originally-populated columns. Everything
    // between them should now be populated.
    let populatedIndices = decimated.buckets.enumerated()
        .filter({ $0.element.isPopulated })
        .map(\.offset)
    #expect(populatedIndices.count > 100)

    let firstCol = populatedIndices.first!
    let lastCol = populatedIndices.last!
    for col in firstCol...lastCol {
        #expect(decimated.buckets[col].isPopulated,
                "column \(col) should be populated after fill")
    }
}

@Test func fillInterpolatesLinearlyBetweenSparseSamples() {
    // Two samples one at value 0 and one at value 10, ten pixel columns apart.
    // Fill should produce nine interpolated bucket values on a linear ramp.
    let decimated = Decimator.decimate(
        timeValues: [0.0, 10.0],
        values: [Float(0.0), Float(10.0)],
        viewport: 0...10,
        pixelWidth: 11
    )

    // Sanity: cols 0 and 10 are the original samples; cols 1..9 are filled.
    // Each filled bucket should match the linear interpolation v = fraction * 10.
    for col in 1...9 {
        let expected = Float(col) * 10.0 / 10.0
        let bucket = decimated.buckets[col]
        #expect(bucket.isPopulated)
        #expect(abs(bucket.minValue - expected) < 1e-4)
        #expect(bucket.minValue == bucket.maxValue)
    }
}

@Test func leftEdgeInterpolatesSampleJustOutsideViewport() {
    // Samples on a straight-line ramp v(t) = t, placed on a regular grid.
    // Viewport starts BETWEEN two samples so the leftmost rendered segment
    // depends on the clipping behavior.
    //
    // Before the fix this bucket came out empty because the pre-viewport
    // sample was dropped by the binary search. After the fix, column 0
    // should carry the linearly-interpolated value at t == viewport.lower.
    let times: [Double] = [0, 1, 2, 3, 4, 5]
    let values: [Float] = [0, 1, 2, 3, 4, 5]
    let decimated = Decimator.decimate(
        timeValues: times,
        values: values,
        viewport: 1.5...4.5,
        pixelWidth: 10,
        fillInterpolatedGaps: false
    )

    #expect(decimated.buckets[0].isPopulated)
    #expect(abs(decimated.buckets[0].minValue - 1.5) < 1e-4)
    #expect(abs(decimated.buckets[0].maxValue - 1.5) < 1e-4)
    // Symmetric case on the right edge.
    let lastCol = decimated.pixelWidth - 1
    #expect(decimated.buckets[lastCol].isPopulated)
    #expect(abs(decimated.buckets[lastCol].minValue - 4.5) < 1e-4)
    #expect(abs(decimated.buckets[lastCol].maxValue - 4.5) < 1e-4)
}

@Test func viewportBetweenSamplesStillDrawsLine() {
    // Viewport strictly between two samples — no in-viewport samples at
    // all. The fix should still clip the polyline to both edges so we
    // draw a straight line across the full plot.
    let times: [Double] = [0, 10]
    let values: [Float] = [0, 10]
    let decimated = Decimator.decimate(
        timeValues: times,
        values: values,
        viewport: 3...7,
        pixelWidth: 5,
        fillInterpolatedGaps: false
    )

    #expect(decimated.buckets[0].isPopulated)
    #expect(abs(decimated.buckets[0].minValue - 3.0) < 1e-4)
    let lastCol = decimated.pixelWidth - 1
    #expect(decimated.buckets[lastCol].isPopulated)
    #expect(abs(decimated.buckets[lastCol].minValue - 7.0) < 1e-4)
}

@Test func degenerateViewportReturnsEmptyBuckets() {
    let (t, v) = uniformlySampled(count: 5) { i in Float(i) }
    // lowerBound == upperBound → tSpan == 0 → all buckets empty.
    let decimated = Decimator.decimate(
        timeValues: t,
        values: v,
        viewport: 2...2,
        pixelWidth: 100
    )
    #expect(decimated.isEmpty)
}

// MARK: - Cache behavior

@Test func cacheHitOnIdenticalRequest() {
    let (t, v) = uniformlySampled(count: 1000) { i in Float(i) }
    let signal = Signal(
        id: 0,
        displayName: "v(a)",
        path: ["a"],
        bareName: "a",
        kind: .voltage,
        unit: "V",
        values: v
    )
    let ref = SignalRef(document: DocumentID(), local: 0)
    let cache = DecimationCache(maxEntries: 4)
    let viewport: ClosedRange<Double> = 0...999
    let first = cache.decimatedTrace(
        for: signal,
        ref: ref,
        timeValues: t,
        viewport: viewport,
        pixelWidth: 100
    )
    #expect(cache.entryCount == 1)

    let second = cache.decimatedTrace(
        for: signal,
        ref: ref,
        timeValues: t,
        viewport: viewport,
        pixelWidth: 100
    )
    // Same inputs → same buckets, same cache population.
    #expect(first == second)
    #expect(cache.entryCount == 1)
}

@Test func cacheEvictsOldestWhenFull() {
    let (t, v) = uniformlySampled(count: 100) { i in Float(i) }
    let signal = Signal(
        id: 0,
        displayName: "v(a)",
        path: ["a"],
        bareName: "a",
        kind: .voltage,
        unit: "V",
        values: v
    )
    let ref = SignalRef(document: DocumentID(), local: 0)
    let cache = DecimationCache(maxEntries: 2)

    // Three distinct pixelWidths → cache exceeds capacity and evicts the oldest.
    _ = cache.decimatedTrace(for: signal, ref: ref, timeValues: t, viewport: 0...99, pixelWidth: 10)
    _ = cache.decimatedTrace(for: signal, ref: ref, timeValues: t, viewport: 0...99, pixelWidth: 20)
    _ = cache.decimatedTrace(for: signal, ref: ref, timeValues: t, viewport: 0...99, pixelWidth: 30)
    #expect(cache.entryCount == 2)
}

@Test func cacheLRUKeepsRecentlyUsedEntriesWarm() {
    let (t, v) = uniformlySampled(count: 100) { i in Float(i) }
    let signal = Signal(
        id: 0,
        displayName: "v(a)",
        path: ["a"],
        bareName: "a",
        kind: .voltage,
        unit: "V",
        values: v
    )
    let ref = SignalRef(document: DocumentID(), local: 0)
    let cache = DecimationCache(maxEntries: 2)

    _ = cache.decimatedTrace(for: signal, ref: ref, timeValues: t, viewport: 0...99, pixelWidth: 10)
    _ = cache.decimatedTrace(for: signal, ref: ref, timeValues: t, viewport: 0...99, pixelWidth: 20)

    // Touch width=10 again so it becomes most-recently-used. Then inserting a third
    // width should evict width=20 (the oldest), not width=10.
    _ = cache.decimatedTrace(for: signal, ref: ref, timeValues: t, viewport: 0...99, pixelWidth: 10)
    _ = cache.decimatedTrace(for: signal, ref: ref, timeValues: t, viewport: 0...99, pixelWidth: 30)
    #expect(cache.entryCount == 2)

    // A fourth request for width=10 should be a cache hit (entryCount unchanged).
    _ = cache.decimatedTrace(for: signal, ref: ref, timeValues: t, viewport: 0...99, pixelWidth: 10)
    #expect(cache.entryCount == 2)
}
