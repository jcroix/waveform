import AppKit
import SwiftUI

@main
struct WaveformViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Single app-global state instance owned by the app and passed into the
    /// main window. Holds all loaded documents, visibility gates, cursor,
    /// viewports — see `WaveformAppState` for the full list.
    @State private var appState: WaveformAppState

    /// App-level shared-X plot state: linked-X zoom flag and the shared X
    /// viewport that every unit panel reads when linked mode is on.
    @State private var sharedState: SharedPlotState

    init() {
        let shared = SharedPlotState()
        self._sharedState = State(wrappedValue: shared)
        self._appState = State(wrappedValue: WaveformAppState(sharedState: shared))
    }

    var body: some Scene {
        Window("Waveform Viewer", id: "main") {
            MainWindow(state: appState)
                .task {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                FileCommands(state: appState)
            }
            CommandGroup(after: .sidebar) {
                ViewCommands(state: appState)
            }
        }
    }
}

// MARK: - File commands

private struct FileCommands: View {
    @Bindable var state: WaveformAppState

    var body: some View {
        Button("Open…") {
            state.presentOpenPanel()
        }
        .keyboardShortcut("o", modifiers: .command)

        Button("Restore Last Session") {
            state.restoreSession()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(!SessionStore.sessionFileExists)
    }
}

// MARK: - View commands

private struct ViewCommands: View {
    @Bindable var state: WaveformAppState

    var body: some View {
        Divider()
        Button("Zoom to Fit") {
            state.resetViewport()
        }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(state.documents.isEmpty)

        Divider()

        Button("Show All Signals") {
            state.showAllSignals()
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .disabled(state.documents.isEmpty)

        Button("Hide All Signals") {
            state.hideAllSignals()
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])
        .disabled(state.checkedSignals.isEmpty)

        Divider()

        Button("Bring Trace to Front") {
            state.moveFocusedToFront()
        }
        .keyboardShortcut("]", modifiers: [.command, .shift])
        .disabled(state.focusedSignalRef == nil)

        Button("Send Trace to Back") {
            state.moveFocusedToBack()
        }
        .keyboardShortcut("[", modifiers: [.command, .shift])
        .disabled(state.focusedSignalRef == nil)

        Divider()

        Menu("Pan") {
            Button("Left")  { state.panX(by: -0.1) }
                .keyboardShortcut(.leftArrow,  modifiers: .option)
            Button("Right") { state.panX(by:  0.1) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
            Divider()
            Button("Up")    { state.panY(by:  0.1) }
                .keyboardShortcut(.upArrow,    modifiers: .option)
            Button("Down")  { state.panY(by: -0.1) }
                .keyboardShortcut(.downArrow,  modifiers: .option)
        }
        .disabled(state.documents.isEmpty)

        Menu("Horizontal Zoom") {
            Button("Zoom In") { state.zoomX(by: 2) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { state.zoomX(by: 0.5) }
                .keyboardShortcut("-", modifiers: .command)
            Divider()
            Button("2×") { state.setZoomX(absolute: 2) }
            Button("4×") { state.setZoomX(absolute: 4) }
            Button("8×") { state.setZoomX(absolute: 8) }
            Button("16×") { state.setZoomX(absolute: 16) }
            Divider()
            Button("Full Range") { state.resetXViewport() }
        }
        .disabled(state.documents.isEmpty)

        Menu("Vertical Zoom") {
            Button("Zoom In") { state.zoomY(by: 2) }
                .keyboardShortcut("=", modifiers: [.command, .shift])
            Button("Zoom Out") { state.zoomY(by: 0.5) }
                .keyboardShortcut("-", modifiers: [.command, .shift])
            Divider()
            Button("2×") { state.setZoomY(absolute: 2) }
            Button("4×") { state.setZoomY(absolute: 4) }
            Button("8×") { state.setZoomY(absolute: 8) }
            Button("16×") { state.setZoomY(absolute: 16) }
            Divider()
            Button("Full Range") { state.resetYViewport() }
        }
        .disabled(state.documents.isEmpty)

        Divider()

        Toggle(isOn: $state.linkedXZoom) {
            Text("Link Horizontal Zoom")
        }

        Toggle(isOn: $state.showGrid) {
            Text("Show Grid")
        }

        Divider()

        Button("Go to Time…") {
            state.presentGoToTimeDialog()
        }
        .keyboardShortcut("g", modifiers: .command)
        .disabled(state.documents.isEmpty)

        Button("Clear Cursor") {
            state.clearCursor()
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(state.cursorTimeX == nil)
    }
}
