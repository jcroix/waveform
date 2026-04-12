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

    /// Default color for a single trace based on its signal kind. Matches the sidebar
    /// icon tint so a signal keeps the same color when moving between the browser and
    /// the plot. Multi-trace layouts (Phase 9+) will prefer the palette-index path since
    /// collisions are common when several signals of the same kind are overlaid.
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
