import AppKit
import SwiftUI

@main
struct WaveformViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = ViewerState()

    var body: some Scene {
        WindowGroup("Waveform Viewer") {
            MainWindow(state: state)
                .task {
                    // Belt-and-suspenders: if the process somehow slips back into the
                    // accessory state after the delegate fires, re-activate on first appear.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    state.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            // Append to the built-in View menu instead of creating a second one. The
            // .sidebar command group (sidebar show/hide) lives in the default View menu,
            // so `after: .sidebar` slots our items in right after it.
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Zoom to Fit") {
                    state.resetViewport()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(state.document == nil)

                Divider()

                Button("Show All Signals") {
                    state.showAllSignals()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(state.document == nil)

                Button("Hide All Signals") {
                    state.hideAllSignals()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(state.document == nil || state.visibleSignalIDs.isEmpty)
            }
        }
    }
}
