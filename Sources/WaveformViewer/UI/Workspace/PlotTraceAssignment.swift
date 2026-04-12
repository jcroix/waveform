import Foundation

/// Which of the plot's two Y axes a trace belongs to.
public enum PlotAxis: Sendable, Equatable {
    case primary    // left axis
    case secondary  // right axis
}

/// Describes the set of traces shown in a single plot pane along with their axis
/// assignments. `primarySignalIDs` renders using the left Y axis; `secondarySignalIDs`
/// renders using the right Y axis. When `secondarySignalIDs` is empty, the plot is
/// single-axis (used by stacked-strips mode where each strip has only one unit).
///
/// `allSignalIDs` preserves the global z-order by concatenating primary then secondary.
/// Callers that already have z-order information should pre-partition the IDs so the
/// relative order within each axis matches the caller's intent.
public struct PlotTraceAssignment: Sendable, Equatable {
    public var primarySignalIDs: [SignalID]
    public var primaryUnit: String
    public var secondarySignalIDs: [SignalID]
    public var secondaryUnit: String

    public init(
        primarySignalIDs: [SignalID],
        primaryUnit: String,
        secondarySignalIDs: [SignalID] = [],
        secondaryUnit: String = ""
    ) {
        self.primarySignalIDs = primarySignalIDs
        self.primaryUnit = primaryUnit
        self.secondarySignalIDs = secondarySignalIDs
        self.secondaryUnit = secondaryUnit
    }

    public var isDualAxis: Bool { !secondarySignalIDs.isEmpty }

    public var allSignalIDs: [SignalID] {
        primarySignalIDs + secondarySignalIDs
    }

    public func axis(for signalID: SignalID) -> PlotAxis {
        secondarySignalIDs.contains(signalID) ? .secondary : .primary
    }
}
