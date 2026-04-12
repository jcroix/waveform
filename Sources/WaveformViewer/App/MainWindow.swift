import SwiftUI

struct MainWindow: View {
    @Bindable var state: ViewerState

    var body: some View {
        NavigationSplitView {
            SignalSidebar(state: state)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            DetailPlaceholder(state: state)
        }
        .navigationTitle(state.document?.title ?? "Waveform Viewer")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.presentOpenPanel()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open a .tr0 or .out file (⌘O)")
            }
        }
    }
}

private struct DetailPlaceholder: View {
    let state: ViewerState

    var body: some View {
        Group {
            if let document = state.document {
                loadedView(document: document)
            } else if let error = state.loadError {
                ContentUnavailableView(
                    "Failed to open",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ContentUnavailableView(
                    "No waveform loaded",
                    systemImage: "waveform",
                    description: Text("Use ⌘O (or File → Open…) to load a .tr0 or .out file.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func loadedView(document: WaveformDocument) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text(document.title)
                .font(.title3)
            HStack(spacing: 18) {
                Label("\(document.signals.count) signals", systemImage: "list.bullet")
                Label("\(document.sampleCount) samples", systemImage: "chart.xyaxis.line")
                Label(document.analysisKind.rawValue.uppercased(), systemImage: "function")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let id = state.selectedSignalID,
               let signal = document.signal(withID: id) {
                Text("Selected: \(signal.displayName) (\(signal.unit))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            Text("Plot panel coming in the next phase")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
        }
        .padding()
    }
}
