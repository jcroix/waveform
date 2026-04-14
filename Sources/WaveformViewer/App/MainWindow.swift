import SwiftUI

/// The single main application window. Left pane: file-hierarchy sidebar
/// (multi-file forest with collapsible file nodes and gate checkboxes).
/// Right pane: stacked unit plot panels, one per signal kind with at least
/// one effective-visible signal, in a fixed voltage → current → power → logic
/// order so panels don't shuffle as users tick boxes.
///
/// Each unit panel shares the X axis through the app's linked-X plot state,
/// so zooming/panning in the voltage panel keeps the current panel in lockstep
/// by default. Each panel owns its own Y viewport per unit.
struct MainWindow: View {
    @Bindable var state: WaveformAppState

    var body: some View {
        NavigationSplitView {
            SignalSidebar(state: state)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            DetailPane(state: state)
        }
        .navigationTitle(state.hubTitle)
        // NOTE: intentionally no `.toolbar { … }`. Bisection against macOS 26.x
        // SwiftUI showed that attaching any toolbar to this window — even a
        // single plain-text ToolbarItem — pegs WindowServer at 30–50% CPU at
        // idle, presumably due to continuous window-chrome compositing. File
        // → Open… (⌘O) lives in WaveformViewerApp.commands instead, and the
        // empty-state view below carries an in-content Open button. Don't
        // reintroduce `.toolbar` without re-testing WindowServer CPU first.
    }
}

private struct DetailPane: View {
    @Bindable var state: WaveformAppState

    var body: some View {
        Group {
            if state.documents.isEmpty {
                emptyState
            } else if visibleUnits.isEmpty {
                noTracesSelected
            } else {
                stackedPanels
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The units that currently have at least one effective-visible signal,
    /// returned in canonical order (voltage → current → power → logic). The
    /// canonical order means panels don't jump around when users flip
    /// checkboxes on and off.
    private var visibleUnits: [SignalKind] {
        SignalKind.routable.filter { !state.effectiveVisibleSignals(unit: $0).isEmpty }
    }

    @ViewBuilder private var emptyState: some View {
        if let error = state.loadError {
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
                Text("Open one or more .tr0 or .out files to begin. Files load additively; pick several at once to compare variants.")
            } actions: {
                Button("Open…") {
                    state.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    @ViewBuilder private var noTracesSelected: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            if state.loadError != nil {
                Label(state.loadError ?? "", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(state.hubTitle)
                .font(.title3)
            Text(summaryLine)
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

    private var summaryLine: String {
        let totalSignals = state.documents.reduce(0) { $0 + $1.document.signals.count }
        let fileCount = state.documents.count
        let fileWord = fileCount == 1 ? "file" : "files"
        return "\(fileCount) \(fileWord) · \(totalSignals) signals"
    }

    @ViewBuilder private var stackedPanels: some View {
        // Hardcoded canonical order — voltage → current → power → logic —
        // with explicit per-unit conditionals so SwiftUI cannot possibly
        // reorder panels through ForEach identity tricks. Panels that have
        // no effective-visible signals simply aren't emitted.
        VStack(spacing: 0) {
            unitSection(.voltage, isFirst: isFirstVisible(.voltage))
            unitSection(.current, isFirst: isFirstVisible(.current))
            unitSection(.power,   isFirst: isFirstVisible(.power))
            unitSection(.logicVoltage, isFirst: isFirstVisible(.logicVoltage))
            Divider()
            PlotStatusBar(
                cursorTime: state.cursorTimeX,
                viewport: state.xViewport(for: visibleUnits.first ?? .voltage),
                fullSpan: state.overallTimeRange
            )
        }
    }

    /// True when `unit` is the first visible unit in canonical order. Used
    /// to suppress the leading divider for the topmost panel.
    private func isFirstVisible(_ unit: SignalKind) -> Bool {
        visibleUnits.first == unit
    }

    @ViewBuilder
    private func unitSection(_ unit: SignalKind, isFirst: Bool) -> some View {
        if !state.effectiveVisibleSignals(unit: unit).isEmpty {
            if !isFirst {
                Divider()
            }
            UnitPlotPanel(state: state, unit: unit)
        }
    }
}
