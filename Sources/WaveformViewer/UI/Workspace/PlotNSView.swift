import AppKit
import CoreText
import QuartzCore

/// Phase 6 plot panel: a minimal `NSView` that renders one or more traces as full-range
/// polyline paths backed by `CAShapeLayer`, plus a top-most axis layer with engineering-
/// notation tick labels drawn via `CoreText`. No decimation (Phase 7), no pan or zoom
/// (Phase 8), no cursor (Phase 15). Y range auto-scales to fit all visible traces with
/// 5% padding.
///
/// Layer stack (bottom → top):
///   - view root layer         (background fill)
///   - traceContainer          (frame = plot area, masksToBounds = true)
///       ├── trace CAShapeLayers (polyline paths in plot-area coordinates)
///   - axisLayer               (zPosition = 1, frame = full bounds, delegate-drawn)
///
/// Placing axes above traces via zPosition means tick marks and labels cannot be
/// overdrawn by waveform data, which was an explicit requirement.
final class PlotNSView: NSView {

    // MARK: - Inputs

    private var document: WaveformDocument?
    private var visibleSignalIDs: [SignalID] = []

    // MARK: - Viewport

    /// Visible time range supplied by the owning `ViewerState`. `nil` means "show the
    /// full sample span". Gestures report proposed viewport changes back to the owner
    /// via `onViewportChange`; the owner then flows the new value back in via
    /// `setContent`. PlotNSView does not own this state.
    private var viewportX: ClosedRange<Double>?

    /// Callback fired when a gesture-driven viewport change is produced. Bound to
    /// `state.viewportX = newValue` by the SwiftUI wrapper.
    var onViewportChange: ((ClosedRange<Double>?) -> Void)?

    /// Snapshot of viewport at the start of a pinch. The gesture accumulates a
    /// magnification delta from zero, so we need the starting viewport to compute
    /// the new span against a stable baseline.
    private var pinchStartViewport: ClosedRange<Double>?

    // MARK: - Layers

    private let traceContainer = CALayer()
    private let axisLayer = CALayer()
    private var traceLayers: [CAShapeLayer] = []

    // MARK: - Decimation cache

    private let decimationCache = DecimationCache(maxEntries: 32)

    // MARK: - Rebuild coalescing

    /// Cache key covering every input that affects the rendered traces and axes. When a
    /// rebuild is requested with the same key as the last successful rebuild, we skip the
    /// work entirely — SwiftUI can call `updateNSView` many times per state tick and
    /// `layout()` fires on every NavigationSplitView animation frame, so this dedup is
    /// load-bearing for keeping the view off the hot path.
    private struct RebuildKey: Equatable {
        let sourceURL: URL?
        let sampleCount: Int
        let ids: [SignalID]
        let boundsSize: CGSize
        let viewportLowerBits: UInt64
        let viewportUpperBits: UInt64
    }
    private var lastRebuildKey: RebuildKey?

    // MARK: - Geometry

    /// Margins reserved around the plot area for axis labels. Left is widest for multi-
    /// character value labels like `"-2.50 mA"`; bottom holds the time axis labels; right
    /// is wide enough for half of the final X-axis label (which is centered on the last
    /// tick position at the plot-area right edge).
    private let margins = NSEdgeInsets(top: 10, left: 68, bottom: 30, right: 28)
    private let tickLength: CGFloat = 4
    private let tickLabelGap: CGFloat = 4
    private let labelEdgePadding: CGFloat = 4

    // MARK: - Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        guard let root = layer else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        root.contentsScale = scale
        root.backgroundColor = NSColor.textBackgroundColor.cgColor
        root.borderWidth = 0.5
        root.borderColor = NSColor.separatorColor.cgColor

        traceContainer.masksToBounds = true
        traceContainer.contentsScale = scale
        traceContainer.actions = [
            "sublayers": NSNull(),
            "contents": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull(),
        ]
        root.addSublayer(traceContainer)

        axisLayer.contentsScale = scale
        axisLayer.delegate = self
        axisLayer.zPosition = 1
        axisLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull(),
        ]
        root.addSublayer(axisLayer)

        installGestureRecognizers()
    }

    private func installGestureRecognizers() {
        let magnify = NSMagnificationGestureRecognizer(
            target: self,
            action: #selector(handleMagnify(_:))
        )
        addGestureRecognizer(magnify)

        let doubleClick = NSClickGestureRecognizer(
            target: self,
            action: #selector(handleDoubleClick(_:))
        )
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
    }

    // MARK: - Responder chain

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Claim first responder on click so ⌘0 and other key events route here.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "0" {
            resetViewport()
            return
        }
        super.keyDown(with: event)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for PlotNSView")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        traceContainer.contentsScale = scale
        axisLayer.contentsScale = scale
        axisLayer.setNeedsDisplay()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            self.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        // Appearance changes invalidate CGColors baked into every trace layer and the
        // axis bitmap, so force a full rebuild regardless of the dedup cache.
        lastRebuildKey = nil
        rebuildIfNeeded()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let plotArea = computePlotArea()
        if traceContainer.frame != plotArea {
            traceContainer.frame = plotArea
        }
        if axisLayer.frame != bounds {
            axisLayer.frame = bounds
        }
        CATransaction.commit()
        rebuildIfNeeded()
    }

    // MARK: - Public API

    func setContent(
        document: WaveformDocument?,
        visibleSignalIDs: [SignalID],
        viewport: ClosedRange<Double>?
    ) {
        let sourceChanged = self.document?.sourceURL != document?.sourceURL
        self.document = document
        self.visibleSignalIDs = visibleSignalIDs
        self.viewportX = viewport
        if sourceChanged {
            // New document → stale SignalIDs from the old one are meaningless and any
            // cached decimated traces with those IDs must go.
            decimationCache.removeAll()
        }
        rebuildIfNeeded()
    }

    // MARK: - Coalesced rebuild entry point

    private func rebuildIfNeeded() {
        let effective = effectiveViewport()
        let key = RebuildKey(
            sourceURL: document?.sourceURL,
            sampleCount: document?.sampleCount ?? 0,
            ids: visibleSignalIDs,
            boundsSize: bounds.size,
            viewportLowerBits: effective?.lowerBound.bitPattern ?? 0,
            viewportUpperBits: effective?.upperBound.bitPattern ?? 0
        )
        if key == lastRebuildKey {
            return
        }
        lastRebuildKey = key
        axisLayer.setNeedsDisplay()
        rebuildTraces()
    }

    // MARK: - Viewport helpers

    /// Returns the currently-displayed time range. Falls back to the full span of the
    /// loaded document's time values when the user hasn't zoomed or panned.
    private func effectiveViewport() -> ClosedRange<Double>? {
        if let viewportX = viewportX {
            return viewportX
        }
        return fullSpan()
    }

    /// Returns the full sample time span of the loaded document, or `nil` if no
    /// document is loaded or the span is degenerate.
    private func fullSpan() -> ClosedRange<Double>? {
        guard let document = document,
              let tStart = document.timeValues.first,
              let tEnd = document.timeValues.last,
              tEnd > tStart else {
            return nil
        }
        return tStart...tEnd
    }

    /// Reset to full range by notifying the owner. The owner flows the `nil` back in
    /// through `setContent` on the next SwiftUI render.
    private func resetViewport() {
        onViewportChange?(nil)
    }

    /// Propose a new visible range to the owner, clamped to the full span. The new
    /// value arrives back via `setContent` after SwiftUI re-evaluates.
    private func applyViewport(_ proposed: ClosedRange<Double>) {
        guard let full = fullSpan(), proposed.lowerBound < proposed.upperBound else {
            return
        }

        // Shift-then-clip so the shape of the range is preserved as long as it fits
        // inside the full span.
        var lower = proposed.lowerBound
        var upper = proposed.upperBound

        if lower < full.lowerBound {
            let shift = full.lowerBound - lower
            lower += shift
            upper += shift
        }
        if upper > full.upperBound {
            let shift = upper - full.upperBound
            lower -= shift
            upper -= shift
        }
        lower = max(lower, full.lowerBound)
        upper = min(upper, full.upperBound)
        guard lower < upper else { return }

        let clamped = lower...upper
        if clamped == viewportX {
            return
        }
        // If the clamped range covers the full span, report `nil` so the owner can
        // remain in "full range" mode rather than pinning the viewport to an exact
        // copy of the span (nil is the canonical full-range representation).
        if abs(clamped.lowerBound - full.lowerBound) < 1e-18 &&
           abs(clamped.upperBound - full.upperBound) < 1e-18 {
            onViewportChange?(nil)
        } else {
            onViewportChange?(clamped)
        }
    }

    // MARK: - Gestures

    @objc private func handleMagnify(_ gesture: NSMagnificationGestureRecognizer) {
        guard let full = fullSpan() else { return }

        switch gesture.state {
        case .began:
            pinchStartViewport = effectiveViewport() ?? full
        case .changed:
            guard let start = pinchStartViewport else { return }
            // gesture.magnification accumulates from zero; positive is zoom-in.
            let factor = 1.0 + gesture.magnification
            guard factor > 0.01 else { return }

            let startSpan = start.upperBound - start.lowerBound
            let newSpan = max(minimumSpan(full: full), startSpan / factor)

            // Keep the time value under the gesture's cursor fixed on screen.
            let plotArea = computePlotArea()
            let cursor = gesture.location(in: self)
            let plotX = max(plotArea.minX, min(plotArea.maxX, cursor.x))
            let relative = plotArea.width > 0
                ? Double(plotX - plotArea.minX) / Double(plotArea.width)
                : 0.5
            let anchorTime = start.lowerBound + relative * startSpan

            let proposed = (anchorTime - relative * newSpan)...(anchorTime + (1 - relative) * newSpan)
            applyViewport(proposed)
        case .ended, .cancelled, .failed:
            pinchStartViewport = nil
        default:
            break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Only consume horizontal scroll for pan. Vertical scroll is reserved for a
        // future Y-axis mode and falls through to the superclass for now.
        let deltaX = event.scrollingDeltaX
        guard deltaX != 0 else {
            super.scrollWheel(with: event)
            return
        }

        guard let current = effectiveViewport() else {
            super.scrollWheel(with: event)
            return
        }

        let plotArea = computePlotArea()
        guard plotArea.width > 0 else {
            super.scrollWheel(with: event)
            return
        }

        let span = current.upperBound - current.lowerBound
        // Natural scroll: dragging right (positive deltaX) pans the window to the right
        // within the content, which means the visible range slides to smaller times.
        let timeDelta = -Double(deltaX) / Double(plotArea.width) * span
        let proposed = (current.lowerBound + timeDelta)...(current.upperBound + timeDelta)
        applyViewport(proposed)
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        resetViewport()
    }

    /// Floor on how narrow the viewport can get. We cap at the width of a single
    /// rendered pixel so decimation can still produce a meaningful envelope.
    private func minimumSpan(full: ClosedRange<Double>) -> Double {
        let plotWidth = Double(computePlotArea().width)
        guard plotWidth > 1 else { return full.upperBound - full.lowerBound }
        return (full.upperBound - full.lowerBound) / plotWidth
    }

    // MARK: - Geometry helpers

    private struct PlotGeometry {
        let plotArea: CGRect
        let tMin: Double
        let tMax: Double
        let yMin: Double
        let yMax: Double
        let unit: String
    }

    private func computePlotArea() -> CGRect {
        CGRect(
            x: margins.left,
            y: margins.bottom,
            width: max(1, bounds.width - margins.left - margins.right),
            height: max(1, bounds.height - margins.top - margins.bottom)
        )
    }

    private func computeGeometry() -> PlotGeometry? {
        guard let document = document, !visibleSignalIDs.isEmpty else { return nil }
        let signals = visibleSignalIDs.compactMap { document.signal(withID: $0) }
        guard !signals.isEmpty else { return nil }

        var yMin = Float.greatestFiniteMagnitude
        var yMax = -Float.greatestFiniteMagnitude
        for signal in signals {
            for value in signal.values {
                if value < yMin { yMin = value }
                if value > yMax { yMax = value }
            }
        }
        guard yMin.isFinite, yMax.isFinite else { return nil }

        var yMinD = Double(yMin)
        var yMaxD = Double(yMax)
        if yMinD == yMaxD {
            let fallback = yMinD == 0 ? 1.0 : abs(yMinD) * 0.1
            yMinD -= fallback
            yMaxD += fallback
        } else {
            let span = yMaxD - yMinD
            let pad = span * 0.05
            yMinD -= pad
            yMaxD += pad
        }

        // Use the zoomed/panned viewport if present, otherwise fall back to the full
        // sample span. Y range is still computed from the complete signal so the axis
        // stays stable while panning — users can read absolute values off the Y axis
        // without the ticks jumping every time they scroll.
        guard let viewport = effectiveViewport() else { return nil }

        // Share the unit across visible signals if they agree; otherwise leave blank so
        // the Y axis shows raw numeric ticks.
        let units = Set(signals.map(\.unit))
        let unit = units.count == 1 ? (units.first ?? "") : ""

        return PlotGeometry(
            plotArea: computePlotArea(),
            tMin: viewport.lowerBound,
            tMax: viewport.upperBound,
            yMin: yMinD,
            yMax: yMaxD,
            unit: unit
        )
    }

    // MARK: - Trace rendering

    private func rebuildTraces() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let geometry = computeGeometry(),
              let document = document else {
            // No content: release any existing trace layers.
            for trace in traceLayers {
                trace.removeFromSuperlayer()
            }
            traceLayers.removeAll()
            return
        }

        let signals = visibleSignalIDs.compactMap { document.signal(withID: $0) }
        guard !signals.isEmpty else {
            for trace in traceLayers {
                trace.removeFromSuperlayer()
            }
            traceLayers.removeAll()
            return
        }

        traceContainer.frame = geometry.plotArea

        // Resize the trace-layer pool so we have exactly one layer per visible signal.
        // Reusing layers is critical: every CAShapeLayer rebuild invalidates the layer's
        // rasterization cache and forces WindowServer to re-rasterize the full 26 K-point
        // path. Keeping the same layer and only updating its `path` + `strokeColor`
        // preserves the rasterization across bound changes and selection churn.
        while traceLayers.count < signals.count {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineWidth = 1.2
            shape.lineJoin = .round
            shape.lineCap = .round
            shape.actions = [
                "path": NSNull(),
                "strokeColor": NSNull(),
                "frame": NSNull(),
                "bounds": NSNull(),
                "position": NSNull(),
                "contents": NSNull(),
            ]
            shape.shouldRasterize = true
            traceContainer.addSublayer(shape)
            traceLayers.append(shape)
        }
        while traceLayers.count > signals.count {
            traceLayers.removeLast().removeFromSuperlayer()
        }

        let ySpan = geometry.yMax - geometry.yMin
        let width = Double(geometry.plotArea.width)
        let height = Double(geometry.plotArea.height)
        let timeValues = document.timeValues
        let rasterScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        // One pixel column per integer point in the plot area width. Decimation buckets
        // map 1:1 to these columns, so trace rebuild cost becomes O(pixelWidth) rather
        // than O(sample count) regardless of whether the underlying trace has 26 K or
        // 10 M points.
        let pixelWidth = max(1, Int(width.rounded(.up)))
        let viewport: ClosedRange<Double> = geometry.tMin...geometry.tMax

        // Each signal gets a stable palette color keyed off its SignalID, so the
        // plot trace color always matches the sidebar icon tint for that signal
        // regardless of how many other traces happen to be visible at the same time.
        for (traceIndex, signal) in signals.enumerated() {
            let shape = traceLayers[traceIndex]
            guard signal.values.count > 1 else {
                shape.path = nil
                continue
            }

            let decimated = decimationCache.decimatedTrace(
                for: signal,
                timeValues: timeValues,
                viewport: viewport,
                pixelWidth: pixelWidth
            )

            let path = buildDecimatedPath(
                decimated: decimated,
                yMin: geometry.yMin,
                ySpan: ySpan,
                plotHeight: height
            )

            shape.frame = traceContainer.bounds
            shape.path = path
            shape.strokeColor = ColorPalette.stableColor(for: signal.id).cgColor
            shape.rasterizationScale = rasterScale
        }
    }

    /// Walks a decimated trace column by column and builds a zigzag polyline that
    /// visits each populated bucket at `(col, minValue)` followed by `(col, maxValue)`.
    /// For dense data the zigzag creates a visible envelope (vertical extents per
    /// column); for sparse data the min and max collapse and the polyline reduces to
    /// a classic one-line-per-sample trace.
    private func buildDecimatedPath(
        decimated: DecimatedTrace,
        yMin: Double,
        ySpan: Double,
        plotHeight: Double
    ) -> CGPath {
        let path = CGMutablePath()
        guard ySpan > 0 else { return path }

        var didMove = false
        for column in 0..<decimated.pixelWidth {
            let bucket = decimated.buckets[column]
            guard bucket.isPopulated else { continue }

            let x = Double(column)
            let yLow = (Double(bucket.minValue) - yMin) / ySpan * plotHeight
            let yHigh = (Double(bucket.maxValue) - yMin) / ySpan * plotHeight

            if !didMove {
                path.move(to: CGPoint(x: x, y: yLow))
                didMove = true
            } else {
                path.addLine(to: CGPoint(x: x, y: yLow))
            }
            if yLow != yHigh {
                path.addLine(to: CGPoint(x: x, y: yHigh))
            }
        }
        return path
    }
}

// MARK: - CALayerDelegate (axis drawing)

extension PlotNSView: CALayerDelegate {
    func draw(_ layer: CALayer, in ctx: CGContext) {
        guard layer === axisLayer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawAxes(in: ctx)
        }
    }

    private func drawAxes(in ctx: CGContext) {
        let plotArea = computePlotArea()
        guard plotArea.width > 1, plotArea.height > 1 else { return }

        // Axis border lines (left + bottom).
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: plotArea.minX, y: plotArea.minY))
        ctx.addLine(to: CGPoint(x: plotArea.minX, y: plotArea.maxY))
        ctx.move(to: CGPoint(x: plotArea.minX, y: plotArea.minY))
        ctx.addLine(to: CGPoint(x: plotArea.maxX, y: plotArea.minY))
        ctx.strokePath()
        ctx.restoreGState()

        // Ticks + labels require live data.
        guard let geometry = computeGeometry() else { return }

        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // X-axis (time) ticks and labels.
        let xTicks = AxisTicks.niceTicks(min: geometry.tMin, max: geometry.tMax, target: 6)
        for tick in xTicks {
            let fraction = (tick - geometry.tMin) / (geometry.tMax - geometry.tMin)
            let x = plotArea.minX + CGFloat(fraction) * plotArea.width

            ctx.saveGState()
            ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            ctx.setLineWidth(1.0)
            ctx.move(to: CGPoint(x: x, y: plotArea.minY - tickLength))
            ctx.addLine(to: CGPoint(x: x, y: plotArea.minY))
            ctx.strokePath()
            ctx.restoreGState()

            let label = EngFormat.format(tick, unit: "s")
            drawLabel(
                label,
                centeredAboveBaselineAt: CGPoint(
                    x: x,
                    y: plotArea.minY - tickLength - tickLabelGap
                ),
                attributes: labelAttributes,
                in: ctx
            )
        }

        // Y-axis (value) ticks and labels.
        let yTicks = AxisTicks.niceTicks(min: geometry.yMin, max: geometry.yMax, target: 6)
        for tick in yTicks {
            let fraction = (tick - geometry.yMin) / (geometry.yMax - geometry.yMin)
            let y = plotArea.minY + CGFloat(fraction) * plotArea.height

            ctx.saveGState()
            ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            ctx.setLineWidth(1.0)
            ctx.move(to: CGPoint(x: plotArea.minX - tickLength, y: y))
            ctx.addLine(to: CGPoint(x: plotArea.minX, y: y))
            ctx.strokePath()
            ctx.restoreGState()

            let label = EngFormat.format(tick, unit: geometry.unit)
            drawLabel(
                label,
                rightAlignedAt: CGPoint(
                    x: plotArea.minX - tickLength - tickLabelGap,
                    y: y
                ),
                attributes: labelAttributes,
                in: ctx
            )
        }
    }

    // MARK: Core Text helpers

    /// Draws `text` with its top edge at `point.y` and its horizontal center at `point.x`,
    /// clamped so that the text never extends past the view's horizontal bounds.
    private func drawLabel(
        _ text: String,
        centeredAboveBaselineAt point: CGPoint,
        attributes: [NSAttributedString.Key: Any],
        in ctx: CGContext
    ) {
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        // In a y-up context `textPosition` is the glyph baseline. We want the top of the
        // glyph box to sit `tickLabelGap` below the tick, so the baseline goes one
        // `ascent` below that point.
        let baselineY = point.y - ascent
        var baselineX = point.x - width / 2

        // Clamp horizontally so edge labels (first tick at plot-area left, last tick at
        // plot-area right) never spill past the view's bounds.
        let minX = labelEdgePadding
        let maxX = bounds.width - labelEdgePadding - width
        if baselineX < minX { baselineX = minX }
        if baselineX > maxX { baselineX = maxX }

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: baselineX, y: baselineY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Draws `text` with its right edge at `point.x` and its vertical center at `point.y`.
    private func drawLabel(
        _ text: String,
        rightAlignedAt point: CGPoint,
        attributes: [NSAttributedString.Key: Any],
        in ctx: CGContext
    ) {
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent

        // Center the glyph box vertically on `point.y`; baseline sits `descent` above the
        // box bottom, which is `height/2` below the midpoint.
        let baselineY = point.y - height / 2 + descent
        let baselineX = point.x - width

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: baselineX, y: baselineY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
