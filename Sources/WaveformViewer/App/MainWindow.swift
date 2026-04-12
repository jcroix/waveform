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
    @Bindable var state: ViewerState

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
        if state.visibleSignalIDs.isEmpty {
            noTracesSelected(document: document)
        } else {
            VStack(spacing: 0) {
                traceLegend(document: document)
                Divider()
                PlotView(
                    document: document,
                    visibleSignalIDs: state.visibleSignalIDs,
                    viewport: state.viewportX,
                    focusedSignalID: state.focusedSignalID,
                    onViewportChange: { state.viewportX = $0 },
                    onFocusChange: { state.focusedSignalID = $0 }
                )
                // Rebuild the plot from scratch when the source file changes so
                // the viewport and decimation cache fully reset.
                .id(document.sourceURL)
            }
        }
    }

    @ViewBuilder
    private func traceLegend(document: WaveformDocument) -> some View {
        HStack(spacing: 14) {
            ForEach(state.visibleSignalIDs, id: \.self) { signalID in
                if let signal = document.signal(withID: signalID) {
                    let isFocused = state.focusedSignalID == signalID
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(nsColor: ColorPalette.stableColor(for: signalID)))
                            .frame(width: isFocused ? 12 : 10, height: isFocused ? 12 : 10)
                        Text(signal.displayName)
                            .font(.caption)
                            .fontWeight(isFocused ? .semibold : .regular)
                        Text("(\(signal.unit))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text("\(document.sampleCount) samples")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func noTracesSelected(document: WaveformDocument) -> some View {
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
            Text("Check signals in the sidebar to plot them, or use View → Show All Signals.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
