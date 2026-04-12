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
        // NOTE: intentionally no `.toolbar { … }`. Bisection against macOS 26.x
        // SwiftUI showed that attaching any toolbar to this window — even a
        // single plain-text ToolbarItem — pegs WindowServer at 30–50% CPU at
        // idle, presumably due to continuous window-chrome compositing. The
        // File → Open command (⌘O) is wired via
        // `WaveformViewerApp.commands` instead, and the in-content button in
        // the empty-state view provides a visible affordance for first-time
        // users. Do not reintroduce `.toolbar` on this window without
        // re-testing WindowServer CPU first.
    }
}

private struct DetailPlaceholder: View {
    let state: ViewerState

    var body: some View {
        Group {
            if let document = state.document {
                loadedView(document: document)
            } else if let error = state.loadError {
                ContentUnavailableView {
                    Label("Failed to open", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Choose Another File…") {
                        state.presentOpenPanel()
                    }
                    .keyboardShortcut("o", modifiers: .command)
                }
            } else {
                ContentUnavailableView {
                    Label("No waveform loaded", systemImage: "waveform")
                } description: {
                    Text("Open a .tr0 or .out file to begin.")
                } actions: {
                    Button("Open…") {
                        state.presentOpenPanel()
                    }
                    .keyboardShortcut("o", modifiers: .command)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func loadedView(document: WaveformDocument) -> some View {
        if let selectedID = state.selectedSignalID,
           let signal = document.signal(withID: selectedID) {
            VStack(spacing: 0) {
                tracesHeader(document: document, signal: signal)
                Divider()
                PlotView(document: document, visibleSignalIDs: [selectedID])
                    // Tying view identity to the source URL forces SwiftUI to rebuild
                    // the PlotView (and its PlotNSView) whenever the underlying file
                    // changes, which resets the zoom/pan viewport. Signal-only changes
                    // within the same document preserve identity, so the viewport
                    // state survives those as intended.
                    .id(document.sourceURL)
            }
        } else {
            unselectedSignalState(document: document)
        }
    }

    @ViewBuilder
    private func tracesHeader(document: WaveformDocument, signal: Signal) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.tint)
                .frame(width: 10, height: 10)
            Text(signal.displayName)
                .font(.headline)
            Text("(\(signal.unit))")
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(document.sampleCount) samples")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func unselectedSignalState(document: WaveformDocument) -> some View {
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
            Text("Click a signal in the sidebar to plot it")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
