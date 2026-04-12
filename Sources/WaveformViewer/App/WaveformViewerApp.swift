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
        }
    }
}
