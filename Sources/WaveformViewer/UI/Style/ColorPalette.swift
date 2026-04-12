import AppKit

/// The default trace color palette. Uses system colors so traces stay legible under both
/// light and dark mode without any manual tinting. Picked to be visually distinguishable
/// when overlaid in a plot panel.
enum ColorPalette {
    static let trace: [NSColor] = [
        .systemYellow,
        .systemBlue,
        .systemRed,
        .systemGreen,
        .systemOrange,
        .systemPurple,
        .systemTeal,
        .systemPink,
        .systemIndigo,
        .systemMint,
        .systemBrown,
        .systemGray,
    ]

    static func color(forTraceIndex index: Int) -> NSColor {
        trace[(index % trace.count + trace.count) % trace.count]
    }

    /// Stable per-signal color keyed off `SignalID`. Each signal in a document keeps
    /// the same color regardless of visibility toggles so the sidebar icon and the
    /// plot trace always agree. Collisions are inevitable past the palette length
    /// (currently 12); a future Phase 9.5 will let users override via a context menu.
    static func stableColor(for signalID: SignalID) -> NSColor {
        color(forTraceIndex: signalID)
    }

    /// Default color for a trace based on its signal kind — used only for single-trace
    /// rendering in Phase 6/8 contexts where there's no multi-trace palette to consult.
    /// Phase 9.0+ uses `stableColor(for:)` for both the sidebar icon tint and the plot
    /// trace color.
    static func color(for kind: SignalKind) -> NSColor {
        switch kind {
        case .voltage:      return .systemYellow
        case .current:      return .systemBlue
        case .power:        return .systemOrange
        case .logicVoltage: return .systemPurple
        case .unknown:      return .systemGray
        }
    }
}
