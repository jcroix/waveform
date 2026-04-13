import AppKit
import SwiftUI

@main
struct WaveformViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// App-level state shared by every window in the process. Currently holds the
    /// linked X viewport + its on/off flag; Y stays per-window. Created once at
    /// app launch and injected into each `MainWindowContainer` instance.
    @State private var sharedState = SharedPlotState()

    var body: some Scene {
        WindowGroup("Waveform Viewer") {
            MainWindowContainer(sharedState: sharedState)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            // Keep the default `File → New Window` (⌘N) by appending our Open…
            // command *after* .newItem instead of replacing it.
            CommandGroup(after: .newItem) {
                FileCommands()
            }
            // Append to the built-in View menu instead of creating a second one.
            CommandGroup(after: .sidebar) {
                ViewCommands()
            }
        }
    }
}

/// Per-window wrapper that owns a fresh `ViewerState` referencing the app-level
/// `SharedPlotState`. Each `WindowGroup` window instance creates its own
/// container via SwiftUI's `@State` semantics, so opening a second window via
/// File → New Window gives an independent ViewerState that still participates
/// in the shared-viewport linking when enabled.
///
/// Publishes `state` through `focusedSceneValue` so command menus can read and
/// mutate the active window's state via `@FocusedValue`.
private struct MainWindowContainer: View {
    let sharedState: SharedPlotState
    @State private var state: ViewerState

    init(sharedState: SharedPlotState) {
        self.sharedState = sharedState
        _state = State(wrappedValue: ViewerState(sharedState: sharedState))
    }

    var body: some View {
        MainWindow(state: state)
            .task {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .focusedSceneValue(\.activeViewerState, state)
            // When the user flips linked → unlinked in any window, every
            // window (including background ones) needs to capture the current
            // shared viewport as its local starting point so their view
            // doesn't suddenly jump. The window that triggered the toggle
            // already handled its own capture inside `setLinkedXZoom`; this
            // hook exists so background windows stay visually stable.
            .onChange(of: sharedState.linkedXZoom) { oldValue, newValue in
                if oldValue == true && newValue == false {
                    state.captureSharedAsLocalViewport()
                }
            }
    }
}

// MARK: - Focused-value plumbing

struct ActiveViewerStateKey: FocusedValueKey {
    typealias Value = ViewerState
}

extension FocusedValues {
    var activeViewerState: ViewerState? {
        get { self[ActiveViewerStateKey.self] }
        set { self[ActiveViewerStateKey.self] = newValue }
    }
}

// MARK: - File commands

private struct FileCommands: View {
    @FocusedValue(\.activeViewerState) private var state: ViewerState?

    var body: some View {
        Button("Open…") {
            state?.presentOpenPanel()
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(state == nil)
    }
}

// MARK: - View commands

private struct ViewCommands: View {
    @FocusedValue(\.activeViewerState) private var state: ViewerState?

    var body: some View {
        Divider()
        Button("Zoom to Fit") {
            state?.resetViewport()
        }
        .keyboardShortcut("0", modifiers: .command)
        .disabled(state?.document == nil)

        Divider()

        Button("Show All Signals") {
            state?.showAllSignals()
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .disabled(state?.document == nil)

        Button("Hide All Signals") {
            state?.hideAllSignals()
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])
        .disabled(state == nil || state?.visibleSignalIDs.isEmpty == true)

        Divider()

        Button("Bring Trace to Front") {
            state?.moveFocusedToFront()
        }
        .keyboardShortcut("]", modifiers: [.command, .shift])
        .disabled(state?.focusedSignalID == nil)

        Button("Send Trace to Back") {
            state?.moveFocusedToBack()
        }
        .keyboardShortcut("[", modifiers: [.command, .shift])
        .disabled(state?.focusedSignalID == nil)

        Divider()

        Menu("Horizontal Zoom") {
            Button("Zoom In") { state?.zoomX(by: 2) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { state?.zoomX(by: 0.5) }
                .keyboardShortcut("-", modifiers: .command)
            Divider()
            Button("2×") { state?.setZoomX(absolute: 2) }
            Button("4×") { state?.setZoomX(absolute: 4) }
            Button("8×") { state?.setZoomX(absolute: 8) }
            Button("16×") { state?.setZoomX(absolute: 16) }
            Divider()
            Button("Full Range") { state?.resetXViewport() }
        }
        .disabled(state?.document == nil)

        Menu("Vertical Zoom") {
            Button("Zoom In") { state?.zoomY(by: 2) }
                .keyboardShortcut("=", modifiers: [.command, .shift])
            Button("Zoom Out") { state?.zoomY(by: 0.5) }
                .keyboardShortcut("-", modifiers: [.command, .shift])
            Divider()
            Button("2×") { state?.setZoomY(absolute: 2) }
            Button("4×") { state?.setZoomY(absolute: 4) }
            Button("8×") { state?.setZoomY(absolute: 8) }
            Button("16×") { state?.setZoomY(absolute: 16) }
            Divider()
            Button("Full Range") { state?.resetYViewport() }
        }
        .disabled(state?.document == nil)

        Divider()

        Toggle(isOn: Binding(
            get: { state?.linkedXZoom ?? true },
            set: { state?.linkedXZoom = $0 }
        )) {
            Text("Link Horizontal Zoom")
        }
        .disabled(state == nil)

        Toggle(isOn: Binding(
            get: { state?.showGrid ?? true },
            set: { state?.showGrid = $0 }
        )) {
            Text("Show Grid")
        }
        .disabled(state == nil)

        Divider()

        Button("Go to Time…") {
            state?.presentGoToTimeDialog()
        }
        .keyboardShortcut("g", modifiers: .command)
        .disabled(state?.document == nil)

        Button("Clear Cursor") {
            state?.clearCursor()
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(state?.cursorTimeX == nil)

        Divider()

        Picker("Plot Layout", selection: plotLayoutBinding) {
            ForEach(PlotLayout.allCases, id: \.self) { option in
                Text(option.label).tag(option)
            }
        }
        .disabled(state == nil)
    }

    private var plotLayoutBinding: Binding<PlotLayout> {
        Binding(
            get: { state?.plotLayout ?? .stackedStrips },
            set: { state?.plotLayout = $0 }
        )
    }
}
