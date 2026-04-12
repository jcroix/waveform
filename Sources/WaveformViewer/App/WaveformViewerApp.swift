import AppKit
import SwiftUI

@main
struct WaveformViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Waveform Viewer") {
            MainWindowContainer()
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            // Keep the default `File → New Window` (⌘N) by appending our Open…
            // command *after* .newItem instead of replacing it. Each new window
            // gets its own ViewerState via `MainWindowContainer`.
            CommandGroup(after: .newItem) {
                FileCommands()
            }
            // Append to the built-in View menu instead of creating a second one.
            // The .sidebar command group (sidebar show/hide) lives in the default
            // View menu, so `after: .sidebar` slots our items in right after it.
            CommandGroup(after: .sidebar) {
                ViewCommands()
            }
        }
    }
}

/// Per-window wrapper that owns a fresh `ViewerState`. Each `WindowGroup` window
/// instance creates its own container via SwiftUI's @State semantics, so opening
/// a second window via File → New Window gives an independent ViewerState.
///
/// The container also publishes `state` through `focusedSceneValue` so that
/// command menus can read and mutate the active window's state via
/// `@FocusedValue`.
private struct MainWindowContainer: View {
    @State private var state = ViewerState()

    var body: some View {
        MainWindow(state: state)
            .task {
                // Belt-and-suspenders: re-assert foreground activation on appear
                // in case the AppDelegate path hasn't fired yet.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .focusedSceneValue(\.activeViewerState, state)
    }
}

// MARK: - Focused-value plumbing

/// Focused-value key carrying the active window's `ViewerState`. Command menus
/// read this via `@FocusedValue(\.activeViewerState)` so their actions target
/// whichever window is frontmost when the user invokes the command.
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

        // Plot-layout picker renders as a submenu of checked radio items in the
        // macOS menu bar. Selecting a different option mutates the focused
        // window's state so each window can independently choose its layout.
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
