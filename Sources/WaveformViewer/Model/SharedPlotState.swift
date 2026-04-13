import Foundation
import Observation

/// App-level state shared across every `ViewerState` in the process. Currently
/// holds the coordinated X viewport plus the flag controlling whether it's
/// coordinated at all. Default is `linkedXZoom = true` so a user opening a
/// second window via ⌘N gets synchronized horizontal pan/zoom out of the box.
///
/// Y-axis state is deliberately NOT shared — each window manages its own
/// per-unit Y viewports. That matches the user's workflow where V and I often
/// live in separate windows with independently-scaled Y axes.
@Observable @MainActor
public final class SharedPlotState {
    /// The coordinated X viewport. `nil` means "full sample span". When
    /// `linkedXZoom` is true, every `ViewerState` reads and writes this
    /// property via its own `viewportX` computed property. When false, this
    /// value is ignored.
    public var viewportX: ClosedRange<Double>?

    /// Whether horizontal pan/zoom coordinates across windows. `true` means
    /// any window's pan/zoom updates a shared value that every other window
    /// observes; `false` means each window owns its own X viewport.
    public var linkedXZoom: Bool = true

    public init() {}
}
