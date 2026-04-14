import SwiftUI

/// One stacked plot panel inside the main window, bound to a single
/// `SignalKind` (voltage / current / power / logic). Panels only appear when
/// at least one signal of their unit is currently effective-visible; the
/// parent `MainWindow.DetailPane` filters the unit list before rendering.
///
/// Each panel has:
/// - a compact trace legend at the top (file-prefixed when more than one
///   document is loaded so variants are distinguishable)
/// - the plot itself, wrapped around `PlotView`
/// - a per-unit Y override stored in `WaveformAppState.viewportsY[unit]`
/// - a shared X viewport routed through `state.xViewport(for:)` (which
///   collapses to the app-wide linked-X state when linked mode is on and
///   otherwise returns the per-unit local)
struct UnitPlotPanel: View {
    @Bindable var state: WaveformAppState
    let unit: SignalKind

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            plotBody
        }
    }

    // MARK: - Derived

    /// Effective-visible `SignalRef`s for this panel's unit, in z-order.
    private var refs: [SignalRef] {
        state.effectiveVisibleSignals(unit: unit)
    }

    private var documentMap: [DocumentID: LoadedDocument] {
        var map: [DocumentID: LoadedDocument] = [:]
        map.reserveCapacity(state.documents.count)
        for loaded in state.documents {
            map[loaded.id] = loaded
        }
        return map
    }

    private var documentOrder: [DocumentID] {
        state.documents.map(\.id)
    }

    private var effectiveXViewport: ClosedRange<Double>? {
        state.xViewport(for: unit)
    }

    // MARK: - Sub-views

    @ViewBuilder private var header: some View {
        HStack(spacing: 14) {
            Text(unit.displayName)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .leading)
            legend
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var legend: some View {
        HStack(spacing: 14) {
            ForEach(refs, id: \.self) { ref in
                if let signal = state.resolve(ref) {
                    let isFocused = (state.focusedSignalRef == ref)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(nsColor: ColorPalette.stableColor(for: ref)))
                            .frame(width: isFocused ? 12 : 10, height: isFocused ? 12 : 10)
                        Text(legendName(for: ref, signal: signal))
                            .font(.caption)
                            .fontWeight(isFocused ? .semibold : .regular)
                    }
                }
            }
        }
    }

    @ViewBuilder private var plotBody: some View {
        PlotView(
            documents: documentMap,
            documentOrder: documentOrder,
            assignment: PlotTraceAssignment(refs: refs, unit: unit),
            overallRange: state.overallTimeRange,
            viewport: effectiveXViewport,
            yOverride: state.viewportsY[unit],
            focusedSignalRef: state.focusedSignalRef,
            cursorTimeX: state.cursorTimeX,
            showGrid: state.showGrid,
            onViewportChange: { state.setXViewport($0, for: unit) },
            onYViewportChange: { range in
                if let range = range {
                    state.viewportsY[unit] = range
                } else {
                    state.viewportsY.removeValue(forKey: unit)
                }
            },
            onResetAll: { state.resetViewport() },
            onFocusChange: { state.focusedSignalRef = $0 },
            onCursorChange: { state.cursorTimeX = $0 }
        )
        .id("unit-plot-\(unit.routingID)")
        .frame(minHeight: 140)
    }

    /// When more than one file is loaded, prefix each legend entry with its
    /// file basename so the user can tell which variant owns which trace.
    /// In the single-file case fall back to the plain signal display name.
    private func legendName(for ref: SignalRef, signal: Signal) -> String {
        if state.documents.count > 1,
           let loaded = state.documents.first(where: { $0.id == ref.document }) {
            return "\(loaded.sourceURL.lastPathComponent): \(signal.displayName)"
        }
        return signal.displayName
    }
}
