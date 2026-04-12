import SwiftUI

struct MainWindow: View {
    var body: some View {
        NavigationSplitView {
            Text("Signal browser")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            ContentUnavailableView(
                "No waveform loaded",
                systemImage: "waveform",
                description: Text("Open a .tr0 or .out file to begin.")
            )
        }
        .navigationTitle("Waveform Viewer")
    }
}
