import SwiftUI

@main
struct WaveformViewerApp: App {
    var body: some Scene {
        WindowGroup("Waveform Viewer") {
            MainWindow()
        }
        .defaultSize(width: 1280, height: 800)
    }
}
