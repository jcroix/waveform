import SwiftUI

/// SwiftUI wrapper around `PlotNSView`. `ViewerState` is the single source of truth
/// for the visible signal set, viewports (X and Y), focus, cursor, and grid
/// visibility; this view ferries them down to the NSView and reports gesture- and
/// click-driven changes back to the state.
struct PlotView: NSViewRepresentable {
    let document: WaveformDocument
    let assignment: PlotTraceAssignment
    let viewport: ClosedRange<Double>?
    let viewportsY: [String: ClosedRange<Double>]
    let focusedSignalID: SignalID?
    let cursorTimeX: Double?
    let showGrid: Bool
    var onViewportChange: (ClosedRange<Double>?) -> Void
    var onYViewportChange: (String, ClosedRange<Double>?) -> Void
    var onResetAll: () -> Void
    var onFocusChange: (SignalID?) -> Void
    var onCursorChange: (Double?) -> Void

    func makeNSView(context: Context) -> PlotNSView {
        let view = PlotNSView(frame: .zero)
        view.onViewportChange = onViewportChange
        view.onYViewportChange = onYViewportChange
        view.onResetAll = onResetAll
        view.onFocusChange = onFocusChange
        view.onCursorChange = onCursorChange
        view.setContent(
            document: document,
            assignment: assignment,
            viewport: viewport,
            viewportsY: viewportsY,
            focusedSignalID: focusedSignalID,
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
            document: document,
            assignment: assignment,
            viewport: viewport,
            viewportsY: viewportsY,
            focusedSignalID: focusedSignalID,
            cursorTimeX: cursorTimeX,
            showGrid: showGrid
        )
    }
}
