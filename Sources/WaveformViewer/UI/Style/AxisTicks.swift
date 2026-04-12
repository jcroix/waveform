import Foundation

/// Generates "nice" tick positions for a numeric axis via the 1-2-5 rounding rule.
/// Given a range and an approximate target count, picks a step size of 1×, 2×, or 5×
/// a power of ten so labels stay human-readable.
enum AxisTicks {
    static func niceTicks(min: Double, max: Double, target: Int = 6) -> [Double] {
        guard target > 0 else { return [] }
        if max == min { return [min] }
        guard max > min else { return [] }

        let range = max - min
        let roughStep = range / Double(target)
        let magnitude = pow(10.0, floor(log10(roughStep)))
        let normalized = roughStep / magnitude

        let niceNormalized: Double
        if normalized < 1.5 {
            niceNormalized = 1
        } else if normalized < 3 {
            niceNormalized = 2
        } else if normalized < 7 {
            niceNormalized = 5
        } else {
            niceNormalized = 10
        }
        let step = niceNormalized * magnitude

        let firstTick = ceil(min / step - 1e-9) * step
        var ticks: [Double] = []
        var tick = firstTick
        let epsilon = step * 1e-9
        while tick <= max + epsilon {
            ticks.append(tick)
            tick += step
        }
        return ticks
    }
}
