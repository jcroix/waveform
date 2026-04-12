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
