import SwiftUI

/// SwiftUI wrapper around `PlotNSView`. `ViewerState` is the single source of truth
/// for the visible signal set and the viewport; this view ferries them down to the
/// NSView and reports gesture-driven viewport changes back to the state.
struct PlotView: NSViewRepresentable {
    let document: WaveformDocument
    let visibleSignalIDs: [SignalID]
    let viewport: ClosedRange<Double>?
    var onViewportChange: (ClosedRange<Double>?) -> Void

    func makeNSView(context: Context) -> PlotNSView {
        let view = PlotNSView(frame: .zero)
        view.onViewportChange = onViewportChange
        view.setContent(
            document: document,
            visibleSignalIDs: visibleSignalIDs,
            viewport: viewport
        )
        return view
    }

    func updateNSView(_ nsView: PlotNSView, context: Context) {
        nsView.onViewportChange = onViewportChange
        nsView.setContent(
            document: document,
            visibleSignalIDs: visibleSignalIDs,
            viewport: viewport
        )
    }
}
