import Foundation

/// Describes the set of traces rendered in a single unit plot window. Phase 15
/// collapsed the old dual-axis (primary / secondary) shape into a single list
/// of `SignalRef`s plus a single `unit` because each `UnitPlotWindow` now
/// hosts exactly one unit (voltage / current / power / logic).
///
/// The `refs` array preserves app-wide z-order: the last element draws on top.
public struct PlotTraceAssignment: Sendable, Equatable {
    public var refs: [SignalRef]
    public var unit: SignalKind

    public init(refs: [SignalRef], unit: SignalKind) {
        self.refs = refs
        self.unit = unit
    }

    public var isEmpty: Bool { refs.isEmpty }
}
