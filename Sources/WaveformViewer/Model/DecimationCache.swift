import Foundation

/// Small LRU cache keyed by `(signal, viewport, pixelWidth)`. Lets multiple plot
/// rebuilds with the same inputs share a single decimation pass and lets pan/zoom
/// (Phase 8) keep recently-visited viewports warm without unbounded growth.
///
/// The cache is deliberately not thread-safe; callers are expected to use it from a
/// single queue (today: the main thread inside `PlotNSView.rebuildTraces`). When
/// Phase 7 grows to include a background serial queue, the cache itself will move
/// onto that queue rather than adding locks here.
final class DecimationCache {
    private struct Key: Hashable {
        let signalID: SignalID
        let sampleCount: Int
        let viewportMinBits: UInt64
        let viewportMaxBits: UInt64
        let pixelWidth: Int

        init(
            signalID: SignalID,
            sampleCount: Int,
            viewport: ClosedRange<Double>,
            pixelWidth: Int
        ) {
            self.signalID = signalID
            self.sampleCount = sampleCount
            self.viewportMinBits = viewport.lowerBound.bitPattern
            self.viewportMaxBits = viewport.upperBound.bitPattern
            self.pixelWidth = pixelWidth
        }
    }

    private var storage: [Key: DecimatedTrace] = [:]
    private var order: [Key] = []   // oldest at index 0
    private let maxEntries: Int

    init(maxEntries: Int = 32) {
        precondition(maxEntries > 0)
        self.maxEntries = maxEntries
    }

    func decimatedTrace(
        for signal: Signal,
        timeValues: [Double],
        viewport: ClosedRange<Double>,
        pixelWidth: Int
    ) -> DecimatedTrace {
        let key = Key(
            signalID: signal.id,
            sampleCount: signal.values.count,
            viewport: viewport,
            pixelWidth: pixelWidth
        )

        if let cached = storage[key] {
            markHit(key)
            return cached
        }

        let trace = Decimator.decimate(
            timeValues: timeValues,
            values: signal.values,
            viewport: viewport,
            pixelWidth: pixelWidth
        )
        storage[key] = trace
        order.append(key)
        evictIfNeeded()
        return trace
    }

    func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    // MARK: - LRU bookkeeping

    private func markHit(_ key: Key) {
        // Move `key` to the end of `order` to mark it most-recently-used.
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > maxEntries {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    // Test-facing introspection.
    var entryCount: Int { storage.count }
}
