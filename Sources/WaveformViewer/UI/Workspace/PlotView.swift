import SwiftUI

/// SwiftUI wrapper around `PlotNSView`. For Phase 6 it just forwards the current document
/// and visible-signal list. Interactivity (pan/zoom, cursors, gestures) arrives in later
/// phases.
struct PlotView: NSViewRepresentable {
    let document: WaveformDocument
    let visibleSignalIDs: [SignalID]

    func makeNSView(context: Context) -> PlotNSView {
        let view = PlotNSView(frame: .zero)
        view.setContent(document: document, visibleSignalIDs: visibleSignalIDs)
        return view
    }

    func updateNSView(_ nsView: PlotNSView, context: Context) {
        nsView.setContent(document: document, visibleSignalIDs: visibleSignalIDs)
    }
}
