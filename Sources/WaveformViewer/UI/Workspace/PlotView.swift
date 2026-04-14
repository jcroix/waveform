import SwiftUI

/// SwiftUI wrapper around `PlotNSView`. Each `UnitPlotWindow` binds one of
/// these to the app-global `WaveformAppState` for a single unit (voltage,
/// current, power, or logic), flowing the visible refs, viewports, focus,
/// cursor, and grid-visibility down to the NSView and reporting gesture- and
/// click-driven changes back to the state.
struct PlotView: NSViewRepresentable {
    let documents: [DocumentID: LoadedDocument]
    let documentOrder: [DocumentID]
    let assignment: PlotTraceAssignment
    let overallRange: ClosedRange<Double>?
    let viewport: ClosedRange<Double>?
    let yOverride: ClosedRange<Double>?
    let focusedSignalRef: SignalRef?
    let cursorTimeX: Double?
    let showGrid: Bool
    var onViewportChange: (ClosedRange<Double>?) -> Void
    var onYViewportChange: (ClosedRange<Double>?) -> Void
    var onResetAll: () -> Void
    var onFocusChange: (SignalRef?) -> Void
    var onCursorChange: (Double?) -> Void

    func makeNSView(context: Context) -> PlotNSView {
        let view = PlotNSView(frame: .zero)
        view.onViewportChange = onViewportChange
        view.onYViewportChange = onYViewportChange
        view.onResetAll = onResetAll
        view.onFocusChange = onFocusChange
        view.onCursorChange = onCursorChange
        view.setContent(
            documents: documents,
            documentOrder: documentOrder,
            assignment: assignment,
            overallRange: overallRange,
            viewport: viewport,
            yOverride: yOverride,
            focusedSignalRef: focusedSignalRef,
            cursorTimeX: cursorTimeX,
            showGrid: showGrid
        )
        return view
    }

    func updateNSView(_ nsView: PlotNSView, context: Context) {
        nsView.onViewportChange = onViewportChange
        nsView.onYViewportChange = onYViewportChange
        nsView.onResetAll = onResetAll
        nsView.onFocusChange = onFocusChange
        nsView.onCursorChange = onCursorChange
        nsView.setContent(
            documents: documents,
            documentOrder: documentOrder,
            assignment: assignment,
            overallRange: overallRange,
            viewport: viewport,
            yOverride: yOverride,
            focusedSignalRef: focusedSignalRef,
            cursorTimeX: cursorTimeX,
            showGrid: showGrid
        )
    }
}
