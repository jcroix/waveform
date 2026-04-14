import AppKit
import SwiftUI

/// SwiftUI wrapper around `PlotNSView`. Each stacked unit panel binds one of
/// these to the app-global `WaveformAppState` for a single unit (voltage,
/// current, power, or logic), flowing the visible refs, viewports, focus,
/// cursor, grid-visibility, and per-signal color override closure down to
/// the NSView and reporting gesture/click-driven changes back to the state.
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
    /// Signature of the currently-active color overrides for the refs in
    /// `assignment`. Changes here force the plot to rebuild so edits in the
    /// sidebar's color well take effect immediately. The signature is just
    /// the serialized list of `(ref, r, g, b, a)` tuples for every ref.
    let colorSignature: [ColorSignatureEntry]
    let colorFor: (SignalRef) -> NSColor
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
            showGrid: showGrid,
            colorSignature: colorSignature,
            colorFor: colorFor
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
            showGrid: showGrid,
            colorSignature: colorSignature,
            colorFor: colorFor
        )
    }
}

/// Single entry in the plot's color-override signature. One per visible
/// ref, regardless of whether the user has actually customized it, so the
/// `RebuildKey` picks up both new overrides AND reverts to the default.
struct ColorSignatureEntry: Hashable, Sendable {
    let ref: SignalRef
    let r: Double
    let g: Double
    let b: Double
    let a: Double
}
