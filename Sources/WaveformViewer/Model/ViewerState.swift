import AppKit
import Foundation
import Observation

/// The top-level app-wide state for a single viewer window. Owned by the `WaveformViewerApp`
/// scene as `@State` and passed to subviews via `@Bindable`. One instance per window scene;
/// Phase 14 will revisit multi-window ownership and optional cross-window sync.
@Observable @MainActor
public final class ViewerState {
    // MARK: - Document

    public var document: WaveformDocument?
    public var loadError: String?

    // MARK: - Sidebar filter

    public var filterText: String = ""

    // MARK: - Visible traces

    /// Ordered list of signals currently plotted. The order IS the z-order: the last
    /// element is drawn on top. Phase 9.2 will expose move-to-front / move-to-back
    /// commands that rearrange this array.
    public var visibleSignalIDs: [SignalID] = []

    /// Signal the user has focused by clicking a trace in the plot area. Used by
    /// Phase 9.1+ to render the focused trace at a heavier line width. `nil` means no
    /// trace is focused; clicking in empty plot area sets this back to `nil`.
    public var focusedSignalID: SignalID?

    // MARK: - Plot viewport

    /// Visible time range on the X axis. `nil` means "full sample span". Pinch and
    /// scroll-pan gestures mutate this in place; menu commands (View → Zoom to Fit)
    /// and ⌘0 reset it to `nil`. Viewport is deliberately per-state, so Phase 14 can
    /// either keep it per-window (independent) or move it to a shared value for
    /// linked-zoom mode.
    public var viewportX: ClosedRange<Double>?

    public init() {}

    // MARK: - Document open

    /// Load a file and swap it in as the current document. On failure, clears the
    /// document and records `loadError` for display in the UI.
    public func open(url: URL) {
        do {
            let next = try WaveformDocument.load(from: url)
            document = next
            loadError = nil
            visibleSignalIDs = []
            focusedSignalID = nil
            viewportX = nil
            filterText = ""
        } catch {
            loadError = String(describing: error)
            document = nil
            visibleSignalIDs = []
            focusedSignalID = nil
            viewportX = nil
        }
    }

    /// Show an `NSOpenPanel` and, on confirmation, load the chosen file.
    public func presentOpenPanel() {
        // Force the app to the front before the modal runs. Without this, an
        // un-bundled `swift run` process can drop the panel's focus the moment the
        // user clicks into it.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a .tr0 or .out file"
        panel.prompt = "Open"

        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    // MARK: - Signal visibility

    /// Returns whether `signalID` is currently plotted.
    public func isVisible(_ signalID: SignalID) -> Bool {
        visibleSignalIDs.contains(signalID)
    }

    /// Toggle visibility for a single signal. Adding appends to the end of the array
    /// (so newly-added traces start at the top of the z-order).
    public func toggleVisibility(_ signalID: SignalID) {
        if let index = visibleSignalIDs.firstIndex(of: signalID) {
            visibleSignalIDs.remove(at: index)
            if focusedSignalID == signalID {
                focusedSignalID = nil
            }
        } else {
            visibleSignalIDs.append(signalID)
        }
    }

    /// Show every signal in the loaded document. No-op if no document is loaded.
    public func showAllSignals() {
        guard let document = document else { return }
        visibleSignalIDs = document.signals.map(\.id)
    }

    /// Hide every visible trace.
    public func hideAllSignals() {
        visibleSignalIDs.removeAll()
        focusedSignalID = nil
    }

    // MARK: - Viewport commands

    /// Reset the X-axis viewport to the full sample span.
    public func resetViewport() {
        viewportX = nil
    }
}
