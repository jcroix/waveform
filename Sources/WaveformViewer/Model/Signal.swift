import Foundation

public typealias SignalID = Int

public struct Signal: Sendable, Identifiable {
    public let id: SignalID
    public let displayName: String    // exactly as stored in source: "v(x1.x2.net)", "i(vdd)", …
    public let path: [String]         // ["x1","x2","net"] — dot-split (or configurable separator)
    public let bareName: String       // last path component: "net"
    public let kind: SignalKind
    public let unit: String
    public let values: [Float]

    public init(
        id: SignalID,
        displayName: String,
        path: [String],
        bareName: String,
        kind: SignalKind,
        unit: String,
        values: [Float]
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.bareName = bareName
        self.kind = kind
        self.unit = unit
        self.values = values
    }

    /// Linearly-interpolated value at the given time, using a parallel `timeValues`
    /// array as the X axis (typically `WaveformDocument.timeValues`). Clamps to the
    /// first or last sample when `t` falls outside the signal's time range. Uses a
    /// binary search so cursor readouts stay O(log N) per trace regardless of how
    /// deeply the user has zoomed in.
    public func value(atTime t: Double, timeValues: [Double]) -> Float? {
        guard !timeValues.isEmpty, values.count == timeValues.count else {
            return nil
        }
        if t <= timeValues[0] { return values[0] }
        if t >= timeValues[timeValues.count - 1] { return values[values.count - 1] }

        var lo = 0
        var hi = timeValues.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if timeValues[mid] < t {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        let upper = lo
        let lower = upper - 1
        let t0 = timeValues[lower]
        let t1 = timeValues[upper]
        let v0 = values[lower]
        let v1 = values[upper]
        if t1 == t0 { return v0 }
        let frac = Float((t - t0) / (t1 - t0))
        return v0 + frac * (v1 - v0)
    }
}

/// Parses a SPICE-style display name (e.g. `"v(x1.x2.net)"`, `"i(vdd)"`, `"v(net3)"`) into
/// its inner hierarchical path components and bare (leaf) name. The optional outer wrapper
/// like `v(...)` or `i(...)` is stripped so that only the hierarchical signal path remains.
///
/// Unwrapped names (without parentheses) are treated as a single path component.
/// Empty components from successive separators are dropped.
public func parseSignalName(
    displayName: String,
    separator: String
) -> (path: [String], bareName: String) {
    var inner = displayName
    if let open = inner.firstIndex(of: "("),
       let close = inner.lastIndex(of: ")"),
       inner.index(after: open) <= close {
        inner = String(inner[inner.index(after: open)..<close])
    }

    let raw: [String]
    if separator.isEmpty {
        raw = [inner]
    } else {
        raw = inner.components(separatedBy: separator)
    }
    let cleaned = raw.filter { !$0.isEmpty }
    let path = cleaned.isEmpty ? [inner] : cleaned
    return (path, path.last ?? inner)
}
