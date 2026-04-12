import Foundation

/// How traces with different units are arranged within a single window's plot area.
public enum PlotLayout: String, Sendable, Equatable, Hashable, CaseIterable {
    /// One pane per unit (V, A, W, L) stacked vertically with a shared time axis.
    /// Each strip auto-scales its own Y range, so voltage dips and current spikes
    /// never fight for vertical pixels. Empty strips collapse to zero height so a
    /// voltage-only view gets the full window.
    case stackedStrips

    /// All traces in one pane with a left Y axis for one unit (typically voltage)
    /// and a right Y axis for a second unit (typically current). More compact than
    /// stacked strips and lets the user visually correlate V transitions with their
    /// corresponding I spikes, at the cost of a busier plot when many traces overlay.
    case dualYAxis

    public var label: String {
        switch self {
        case .stackedStrips: return "Stacked Strips"
        case .dualYAxis:     return "Dual Y Axis"
        }
    }
}
