import AppKit
import Foundation
import Observation

/// The top-level app-wide state for a single viewer window. Owned by the `WaveformViewerApp`
/// scene as `@State` and passed to subviews via `@Bindable`. For v1 this is a single document
/// per window; Phase 14 will revisit multi-window ownership.
@Observable @MainActor
public final class ViewerState {
    public var document: WaveformDocument?
    public var filterText: String = ""
    public var selectedSignalID: SignalID?
    public var loadError: String?

    public init() {}

    /// Load a file and swap it in as the current document. On failure, clears the document
    /// and records `loadError` for display in the UI.
    public func open(url: URL) {
        do {
            let next = try WaveformDocument.load(from: url)
            document = next
            loadError = nil
            selectedSignalID = nil
            filterText = ""
        } catch {
            loadError = String(describing: error)
            document = nil
        }
    }

    /// Show an NSOpenPanel and, on confirmation, load the chosen file.
    public func presentOpenPanel() {
        // Force the app to the front before the modal runs. Without this, an un-bundled
        // `swift run` process can drop the panel's focus the moment the user clicks into it.
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
}
