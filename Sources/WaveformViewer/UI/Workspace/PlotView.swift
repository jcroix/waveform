import SwiftUI

/// SwiftUI wrapper around `PlotNSView`. `ViewerState` is the single source of truth
/// for the visible signal set, the viewport, the focused signal, and the cursor;
/// this view ferries them down to the NSView and reports gesture- and click-driven
/// changes back to the state.
struct PlotView: NSViewRepresentable {
    let document: WaveformDocument
    let assignment: PlotTraceAssignment
    let viewport: ClosedRange<Double>?
    let focusedSignalID: SignalID?
    let cursorTimeX: Double?
    var onViewportChange: (ClosedRange<Double>?) -> Void
    var onFocusChange: (SignalID?) -> Void
    var onCursorChange: (Double?) -> Void

    func makeNSView(context: Context) -> PlotNSView {
        let view = PlotNSView(frame: .zero)
        view.onViewportChange = onViewportChange
        view.onFocusChange = onFocusChange
        view.onCursorChange = onCursorChange
        view.setContent(
            document: document,
            assignment: assignment,
            viewport: viewport,
            focusedSignalID: focusedSignalID,
            cursorTimeX: cursorTimeX
        )
        return view
    }

    func updateNSView(_ nsView: PlotNSView, context: Context) {
        nsView.onViewportChange = onViewportChange
        nsView.onFocusChange = onFocusChange
        nsView.onCursorChange = onCursorChange
        nsView.setContent(
            document: document,
            assignment: assignment,
            viewport: viewport,
            focusedSignalID: focusedSignalID,
            cursorTimeX: cursorTimeX
        )
    }
}
