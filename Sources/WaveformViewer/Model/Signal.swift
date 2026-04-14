import Foundation

public typealias SignalID = Int

/// Globally-unique identifier for a loaded waveform file. Each `LoadedDocument`
/// gets a fresh `DocumentID` at load time so that overlapping signal names in
/// different files stay distinct throughout the app. Stored as a `UUID` so it
/// survives copying and equality comparison without any central registry.
public struct DocumentID: Hashable, Sendable {
    public let raw: UUID

    public init() {
        self.raw = UUID()
    }

    public init(raw: UUID) {
        self.raw = raw
    }
}

/// Globally-unique signal identity. Couples a document-local `SignalID` (an
/// index into `WaveformDocument.signals`) with its owning `DocumentID`, so the
/// same local index in two different loaded files refers to two different
/// signals. This is the handle threaded through every app-level data structure
/// that needs to point at a signal across multiple files: visibility lists,
/// focus tracking, plot traces, hit testing, decimation cache keys.
public struct SignalRef: Hashable, Sendable {
    public let document: DocumentID
    public let local: SignalID

    public init(document: DocumentID, local: SignalID) {
        self.document = document
        self.local = local
    }
}

/// Identifies a specific `HierarchyNode` inside the multi-file sidebar forest.
/// File-level nodes use an empty `fullPath`; interior and leaf nodes use their
/// dotted path inside the owning document. Stored in the `gateOff` set so that
/// unchecking a parent node can be represented and queried in O(1) when the
/// plot filters visible traces.
public struct HierarchyKey: Hashable, Sendable {
    public let document: DocumentID
    public let fullPath: String

    public init(document: DocumentID, fullPath: String) {
        self.document = document
        self.fullPath = fullPath
    }
}

/// A freshly-loaded `WaveformDocument` wrapped with its app-assigned
/// `DocumentID`. `WaveformAppState` stores `[LoadedDocument]` rather than
/// `[WaveformDocument]` so the parser layer stays unaware of multi-file
/// identity — parsing still produces pure `WaveformDocument` values, and the
/// wrapper only exists in the UI/state layer.
public struct LoadedDocument: Sendable, Identifiable {
    public let id: DocumentID
    public let document: WaveformDocument

    public init(id: DocumentID = DocumentID(), document: WaveformDocument) {
        self.id = id
        self.document = document
    }

    public var signals: [Signal] { document.signals }
    public var timeValues: [Double] { document.timeValues }
    public var sourceURL: URL { document.sourceURL }
    public var title: String { document.title }

    public func signal(withLocalID id: SignalID) -> Signal? {
        document.signal(withID: id)
    }

    public var timeRange: ClosedRange<Double>? {
        guard let first = timeValues.first, let last = timeValues.last, last > first else {
            return nil
        }
        return first...last
    }
}

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
