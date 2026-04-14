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

    /// Stable per-signal color keyed off a globally-unique `SignalRef`. Each
    /// signal in each loaded file keeps the same color regardless of visibility
    /// toggles so the sidebar icon and the plot trace always agree. The
    /// document-id component of `SignalRef` is folded into the palette index so
    /// the same `v(clk)` loaded from two different files still picks two
    /// different colors — which is exactly what the user needs when overlaying
    /// variant waveforms. Collisions are still possible past the palette length
    /// (12 slots) but they won't cluster on "signal zero of every file".
    static func stableColor(for ref: SignalRef) -> NSColor {
        var hasher = Hasher()
        hasher.combine(ref.document)
        hasher.combine(ref.local)
        let digest = hasher.finalize()
        return color(forTraceIndex: digest)
    }

    /// Legacy single-document accessor kept for code paths that still operate
    /// on a document-local `SignalID` without knowing which file owns it. New
    /// code should prefer `stableColor(for:SignalRef)`.
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
