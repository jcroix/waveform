import AppKit
import CoreText
import QuartzCore

/// Layer-backed NSView that renders a set of traces in one of two modes:
///
/// - **Single-axis**: `assignment.secondarySignalIDs` is empty; all traces use the
///   left Y axis. This is what stacked strips use — each strip is a single-axis
///   PlotNSView rendering one signal-kind group.
/// - **Dual-axis**: `assignment.secondarySignalIDs` is non-empty; the left Y axis is
///   used for primary traces, the right Y axis for secondary traces. Each axis
///   auto-scales independently so voltage signals don't get squashed against
///   milliamp currents and vice versa.
///
/// Layer stack (bottom → top):
///   - view root layer         (background fill)
///   - traceContainer          (frame = plot area, masksToBounds = true)
///       ├── trace CAShapeLayers (polyline paths in plot-area coordinates)
///   - axisLayer               (zPosition = 1, frame = full bounds, delegate-drawn)
final class PlotNSView: NSView {

    // MARK: - Inputs

    private var document: WaveformDocument?
    private var assignment: PlotTraceAssignment = PlotTraceAssignment(
        primarySignalIDs: [],
        primaryUnit: ""
    )

    // MARK: - Viewport

    /// Visible time range supplied by the owning `ViewerState`. `nil` means "show the
    /// full sample span".
    private var viewportX: ClosedRange<Double>?

    var onViewportChange: ((ClosedRange<Double>?) -> Void)?

    private var pinchStartViewport: ClosedRange<Double>?

    // MARK: - Focus

    private var focusedSignalID: SignalID?

    var onFocusChange: ((SignalID?) -> Void)?

    private let hitTestRadius: CGFloat = 8

    // MARK: - Cursor

    /// Cursor position in simulation-time units. `nil` if no cursor is placed.
    /// Supplied by the owning `ViewerState` via `setContent`. The plot draws a
    /// dashed vertical line at the pixel column matching this time whenever it
    /// falls inside the current viewport.
    private var cursorTimeX: Double?

    /// Callback fired when a mouseDown places (or replaces) the cursor. Bound to
    /// `state.cursorTimeX = newValue`.
    var onCursorChange: ((Double?) -> Void)?

    private var lastClickLocation: CGPoint?
    private var lastCycleCandidates: [SignalID] = []
    private var lastCycleIndex: Int = -1

    private let cycleLocationTolerance: CGFloat = 3

    // MARK: - Layers

    private let traceContainer = CALayer()
    private let axisLayer = CALayer()
    private var traceLayers: [CAShapeLayer] = []

    // MARK: - Decimation cache

    private let decimationCache = DecimationCache(maxEntries: 32)

    // MARK: - Rebuild coalescing

    private struct RebuildKey: Equatable {
        let sourceURL: URL?
        let sampleCount: Int
        let primaryIDs: [SignalID]
        let secondaryIDs: [SignalID]
        let primaryUnit: String
        let secondaryUnit: String
        let boundsSize: CGSize
        let viewportLowerBits: UInt64
        let viewportUpperBits: UInt64
        let focusedSignalID: SignalID?
        let cursorBits: UInt64?
    }
    private var lastRebuildKey: RebuildKey?

    // MARK: - Margins

    /// Left margin carries primary Y-axis labels; bottom carries the time axis.
    /// When the plot is in dual-axis mode, the right margin is widened to hold the
    /// secondary Y-axis labels.
    private let singleAxisMargins = NSEdgeInsets(top: 10, left: 68, bottom: 30, right: 28)
    private let dualAxisMargins = NSEdgeInsets(top: 10, left: 68, bottom: 30, right: 68)
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
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)

        guard event.clickCount == 1 else { return }

        let clickLocal = convert(event.locationInWindow, from: nil)

        // Place the cursor at the click's time coordinate whenever the click lands
        // inside the plot area (regardless of whether any trace was actually hit).
        // Cursor + selection are independent: a click can hit empty space and still
        // place a cursor for reading values.
        let plotArea = computePlotArea()
        if plotArea.contains(clickLocal),
           let viewport = effectiveViewport(),
           plotArea.width > 0 {
            let fraction = Double(clickLocal.x - plotArea.minX) / Double(plotArea.width)
            let clamped = min(max(0, fraction), 1)
            let cursorTime = viewport.lowerBound + clamped * (viewport.upperBound - viewport.lowerBound)
            onCursorChange?(cursorTime)
        }

        let candidates = hitTestCandidates(at: clickLocal)

        if candidates.isEmpty {
            lastClickLocation = nil
            lastCycleCandidates = []
            lastCycleIndex = -1
            onFocusChange?(nil)
            return
        }

        let sameLocation = lastClickLocation.map { previous in
            abs(previous.x - clickLocal.x) <= cycleLocationTolerance &&
            abs(previous.y - clickLocal.y) <= cycleLocationTolerance
        } ?? false
        let sameCandidates = (candidates == lastCycleCandidates)

        let selectedIndex: Int
        if sameLocation && sameCandidates && candidates.count > 1 {
            selectedIndex = (lastCycleIndex + 1) % candidates.count
        } else {
            selectedIndex = 0
        }

        lastClickLocation = clickLocal
        lastCycleCandidates = candidates
        lastCycleIndex = selectedIndex
        onFocusChange?(candidates[selectedIndex])
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "0" {
            resetViewport()
            return
        }
        let key = Int(event.keyCode)
        // kVK_LeftArrow = 123, kVK_RightArrow = 124
        if key == 123 || key == 124 {
            let direction: ArrowStepDirection = (key == 123) ? .backward : .forward
            handleArrowStep(direction: direction, modifiers: event.modifierFlags)
            return
        }
        super.keyDown(with: event)
    }

    private enum ArrowStepDirection { case backward, forward }

    /// Advance the cursor to the previous/next sample in the document's time grid
    /// and, if the new cursor falls outside the current viewport, slide the viewport
    /// so the cursor remains visible. Step size depends on modifier keys:
    /// plain = 1 sample; shift = 10 samples; cmd = jump to the very first/last
    /// sample. Clamped to the simulation's full time span.
    private func handleArrowStep(direction: ArrowStepDirection, modifiers: NSEvent.ModifierFlags) {
        guard let document = document, !document.timeValues.isEmpty else { return }

        // Where to start: existing cursor, or the viewport midpoint if there's no
        // cursor yet. That way the first arrow press places a cursor rather than
        // being a no-op.
        let startTime: Double
        if let existing = cursorTimeX {
            startTime = existing
        } else if let viewport = effectiveViewport() {
            startTime = (viewport.lowerBound + viewport.upperBound) / 2
        } else {
            return
        }

        // Find the index of the sample nearest to startTime. Binary search for the
        // first time >= startTime, then pick whichever of that index or the one
        // before it is closer.
        let times = document.timeValues
        var lo = 0
        var hi = times.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if times[mid] < startTime {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var anchorIndex = lo
        if anchorIndex >= times.count { anchorIndex = times.count - 1 }
        if anchorIndex > 0 {
            let a = times[anchorIndex - 1]
            let b = times[anchorIndex]
            if abs(startTime - a) <= abs(startTime - b) {
                anchorIndex -= 1
            }
        }

        let step: Int
        if modifiers.contains(.command) {
            step = times.count  // effectively jump to the far end
        } else if modifiers.contains(.shift) {
            step = 10
        } else {
            step = 1
        }

        // If the cursor was already sitting on an exact sample, arrow one sample
        // away from it. If it was between samples, snap to the nearest first.
        let cursorWasOnSample = (abs(times[anchorIndex] - startTime) < 1e-18)
        let moveSteps = cursorWasOnSample ? step : (step - 1)

        var targetIndex = anchorIndex
        switch direction {
        case .backward:
            targetIndex -= moveSteps
        case .forward:
            targetIndex += moveSteps
        }
        if !cursorWasOnSample {
            // When not previously on a sample, always at least snap to the
            // nearest one in the chosen direction.
            switch direction {
            case .backward:
                if times[anchorIndex] >= startTime {
                    targetIndex -= 1
                }
            case .forward:
                if times[anchorIndex] <= startTime {
                    targetIndex += 1
                }
            }
        }
        targetIndex = max(0, min(times.count - 1, targetIndex))
        let newTime = times[targetIndex]

        onCursorChange?(newTime)
        ensureCursorVisible(newTime)
    }

    /// If `cursorTime` is outside the current viewport, slide the viewport so the
    /// cursor sits 20% of the span inside the edge it approached from. That larger
    /// margin means arrow-key navigation scrolls further per overshoot, so the
    /// user sees more new context on each edge hit instead of pixel-chasing the
    /// cursor along the border. Clamped to the full sample span via `applyViewport`.
    private func ensureCursorVisible(_ cursorTime: Double) {
        guard let viewport = effectiveViewport() else { return }
        if cursorTime >= viewport.lowerBound && cursorTime <= viewport.upperBound {
            return
        }
        let span = viewport.upperBound - viewport.lowerBound
        guard span > 0 else { return }
        let edgeMargin = span * 0.2

        let newLower: Double
        let newUpper: Double
        if cursorTime < viewport.lowerBound {
            newLower = cursorTime - edgeMargin
            newUpper = newLower + span
        } else {
            newUpper = cursorTime + edgeMargin
            newLower = newUpper - span
        }
        applyViewport(newLower...newUpper)
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
        assignment: PlotTraceAssignment,
        viewport: ClosedRange<Double>?,
        focusedSignalID: SignalID?,
        cursorTimeX: Double?
    ) {
        let sourceChanged = self.document?.sourceURL != document?.sourceURL
        self.document = document
        self.assignment = assignment
        self.viewportX = viewport
        self.focusedSignalID = focusedSignalID
        self.cursorTimeX = cursorTimeX
        if sourceChanged {
            decimationCache.removeAll()
        }
        rebuildIfNeeded()
    }

    private func margins() -> NSEdgeInsets {
        assignment.isDualAxis ? dualAxisMargins : singleAxisMargins
    }

    private func computePlotArea() -> CGRect {
        let m = margins()
        return CGRect(
            x: m.left,
            y: m.bottom,
            width: max(1, bounds.width - m.left - m.right),
            height: max(1, bounds.height - m.top - m.bottom)
        )
    }

    // MARK: - Coalesced rebuild entry point

    private func rebuildIfNeeded() {
        let effective = effectiveViewport()
        let key = RebuildKey(
            sourceURL: document?.sourceURL,
            sampleCount: document?.sampleCount ?? 0,
            primaryIDs: assignment.primarySignalIDs,
            secondaryIDs: assignment.secondarySignalIDs,
            primaryUnit: assignment.primaryUnit,
            secondaryUnit: assignment.secondaryUnit,
            boundsSize: bounds.size,
            viewportLowerBits: effective?.lowerBound.bitPattern ?? 0,
            viewportUpperBits: effective?.upperBound.bitPattern ?? 0,
            focusedSignalID: focusedSignalID,
            cursorBits: cursorTimeX?.bitPattern
        )
        if key == lastRebuildKey {
            return
        }
        lastRebuildKey = key
        axisLayer.setNeedsDisplay()
        rebuildTraces()
    }

    // MARK: - Viewport helpers

    private func effectiveViewport() -> ClosedRange<Double>? {
        if let viewportX = viewportX {
            return viewportX
        }
        return fullSpan()
    }

    private func fullSpan() -> ClosedRange<Double>? {
        guard let document = document,
              let tStart = document.timeValues.first,
              let tEnd = document.timeValues.last,
              tEnd > tStart else {
            return nil
        }
        return tStart...tEnd
    }

    private func resetViewport() {
        onViewportChange?(nil)
    }

    private func applyViewport(_ proposed: ClosedRange<Double>) {
        guard let full = fullSpan(), proposed.lowerBound < proposed.upperBound else {
            return
        }
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
            let factor = 1.0 + gesture.magnification
            guard factor > 0.01 else { return }

            let startSpan = start.upperBound - start.lowerBound
            let newSpan = max(minimumSpan(full: full), startSpan / factor)

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
        let timeDelta = -Double(deltaX) / Double(plotArea.width) * span
        let proposed = (current.lowerBound + timeDelta)...(current.upperBound + timeDelta)
        applyViewport(proposed)
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        resetViewport()
    }

    private func minimumSpan(full: ClosedRange<Double>) -> Double {
        let plotWidth = Double(computePlotArea().width)
        guard plotWidth > 1 else { return full.upperBound - full.lowerBound }
        return (full.upperBound - full.lowerBound) / plotWidth
    }

    // MARK: - Geometry

    private struct PlotGeometry {
        let plotArea: CGRect
        let tMin: Double
        let tMax: Double
        let primaryYMin: Double
        let primaryYMax: Double
        let primaryUnit: String
        let secondaryYMin: Double?
        let secondaryYMax: Double?
        let secondaryUnit: String
    }

    /// Computes a padded Y range covering `signals`' values. Returns `nil` if no
    /// finite values are found.
    private func computeYRange(for signals: [Signal]) -> (min: Double, max: Double)? {
        guard !signals.isEmpty else { return nil }

        var yMin = Float.greatestFiniteMagnitude
        var yMax = -Float.greatestFiniteMagnitude
        for signal in signals {
            for value in signal.values {
                if value < yMin { yMin = value }
                if value > yMax { yMax = value }
            }
        }
        guard yMin.isFinite, yMax.isFinite, yMin <= yMax else { return nil }

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
        return (yMinD, yMaxD)
    }

    private func computeGeometry() -> PlotGeometry? {
        guard let document = document else { return nil }

        let primarySignals = assignment.primarySignalIDs.compactMap { document.signal(withID: $0) }
        let secondarySignals = assignment.secondarySignalIDs.compactMap { document.signal(withID: $0) }

        guard !primarySignals.isEmpty || !secondarySignals.isEmpty else { return nil }

        // Primary range falls back to secondary if primary is empty (shouldn't happen
        // in normal flows but keeps the view robust).
        let primaryRange = computeYRange(for: primarySignals)
            ?? computeYRange(for: secondarySignals)
        guard let primaryRange = primaryRange else { return nil }

        let secondaryRange: (min: Double, max: Double)?
        if !secondarySignals.isEmpty && !primarySignals.isEmpty {
            secondaryRange = computeYRange(for: secondarySignals)
        } else {
            secondaryRange = nil
        }

        guard let viewport = effectiveViewport() else { return nil }

        return PlotGeometry(
            plotArea: computePlotArea(),
            tMin: viewport.lowerBound,
            tMax: viewport.upperBound,
            primaryYMin: primaryRange.min,
            primaryYMax: primaryRange.max,
            primaryUnit: assignment.primaryUnit,
            secondaryYMin: secondaryRange?.min,
            secondaryYMax: secondaryRange?.max,
            secondaryUnit: assignment.secondaryUnit
        )
    }

    /// Returns the Y range (padded) the given signal should render against, based on
    /// its axis assignment.
    private func yRange(for signalID: SignalID, geometry: PlotGeometry) -> (min: Double, max: Double) {
        switch assignment.axis(for: signalID) {
        case .primary:
            return (geometry.primaryYMin, geometry.primaryYMax)
        case .secondary:
            if let min = geometry.secondaryYMin, let max = geometry.secondaryYMax {
                return (min, max)
            }
            // Fallback: if secondary range is absent (single-axis mode), use primary.
            return (geometry.primaryYMin, geometry.primaryYMax)
        }
    }

    // MARK: - Trace rendering

    private func rebuildTraces() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let geometry = computeGeometry(),
              let document = document else {
            for trace in traceLayers {
                trace.removeFromSuperlayer()
            }
            traceLayers.removeAll()
            return
        }

        let orderedIDs = assignment.allSignalIDs
        let signals = orderedIDs.compactMap { document.signal(withID: $0) }
        guard !signals.isEmpty else {
            for trace in traceLayers {
                trace.removeFromSuperlayer()
            }
            traceLayers.removeAll()
            return
        }

        traceContainer.frame = geometry.plotArea

        // Resize the trace-layer pool so we have exactly one layer per visible signal.
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

        let width = Double(geometry.plotArea.width)
        let height = Double(geometry.plotArea.height)
        let timeValues = document.timeValues
        let rasterScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        let pixelWidth = max(1, Int(width.rounded(.up)))
        let viewport: ClosedRange<Double> = geometry.tMin...geometry.tMax

        for (traceIndex, signal) in signals.enumerated() {
            let shape = traceLayers[traceIndex]
            guard signal.values.count > 1 else {
                shape.path = nil
                continue
            }

            let range = yRange(for: signal.id, geometry: geometry)
            let ySpan = range.max - range.min
            guard ySpan > 0 else {
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
                yMin: range.min,
                ySpan: ySpan,
                plotHeight: height
            )

            let isFocused = (signal.id == focusedSignalID)
            shape.frame = traceContainer.bounds
            shape.path = path
            shape.strokeColor = ColorPalette.stableColor(for: signal.id).cgColor
            shape.lineWidth = isFocused ? 3.5 : 1.2
            shape.rasterizationScale = rasterScale
        }
    }

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

    // MARK: - Hit testing

    private func hitTestCandidates(at point: CGPoint) -> [SignalID] {
        let plotArea = computePlotArea()
        guard plotArea.contains(point) else { return [] }

        guard let document = document,
              let geometry = computeGeometry() else {
            return []
        }

        let orderedIDs = assignment.allSignalIDs
        let signals = orderedIDs.compactMap { document.signal(withID: $0) }
        guard !signals.isEmpty else { return [] }

        let plotWidth = Double(plotArea.width)
        let plotHeight = Double(plotArea.height)
        guard plotWidth > 1, plotHeight > 1 else { return [] }

        let pixelWidth = max(1, Int(plotArea.width.rounded(.up)))
        let viewport = geometry.tMin...geometry.tMax

        let clickXOffset = Double(point.x - plotArea.minX)
        let clickY = Double(point.y - plotArea.minY)
        let centerColumn = Int(clickXOffset)
        let radius = Double(hitTestRadius)
        let scanRadius = Int(ceil(radius))
        let lowColumn = max(0, centerColumn - scanRadius)
        let highColumn = min(pixelWidth - 1, centerColumn + scanRadius)

        struct Match {
            let signalID: SignalID
            let traceIndex: Int
            var distance: Double
        }
        var matches: [SignalID: Match] = [:]

        for (traceIndex, signal) in signals.enumerated() {
            let range = yRange(for: signal.id, geometry: geometry)
            let ySpan = range.max - range.min
            guard ySpan > 0 else { continue }

            let decimated = decimationCache.decimatedTrace(
                for: signal,
                timeValues: document.timeValues,
                viewport: viewport,
                pixelWidth: pixelWidth
            )
            guard decimated.buckets.count == pixelWidth else { continue }

            for column in lowColumn...highColumn {
                let bucket = decimated.buckets[column]
                guard bucket.isPopulated else { continue }

                let bucketX = Double(column)
                let yLow = (Double(bucket.minValue) - range.min) / ySpan * plotHeight
                let yHigh = (Double(bucket.maxValue) - range.min) / ySpan * plotHeight

                let clampedY = max(yLow, min(yHigh, clickY))
                let dx = clickXOffset - bucketX
                let dy = clickY - clampedY
                let distance = (dx * dx + dy * dy).squareRoot()

                guard distance <= radius else { continue }

                if let existing = matches[signal.id] {
                    if distance < existing.distance {
                        matches[signal.id] = Match(
                            signalID: signal.id,
                            traceIndex: traceIndex,
                            distance: distance
                        )
                    }
                } else {
                    matches[signal.id] = Match(
                        signalID: signal.id,
                        traceIndex: traceIndex,
                        distance: distance
                    )
                }
            }
        }

        return matches.values
            .sorted { lhs, rhs in
                if lhs.distance != rhs.distance {
                    return lhs.distance < rhs.distance
                }
                return lhs.traceIndex > rhs.traceIndex
            }
            .map(\.signalID)
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

        // Left + bottom axis border lines; add right border if dual-axis.
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: plotArea.minX, y: plotArea.minY))
        ctx.addLine(to: CGPoint(x: plotArea.minX, y: plotArea.maxY))
        ctx.move(to: CGPoint(x: plotArea.minX, y: plotArea.minY))
        ctx.addLine(to: CGPoint(x: plotArea.maxX, y: plotArea.minY))
        if assignment.isDualAxis {
            ctx.move(to: CGPoint(x: plotArea.maxX, y: plotArea.minY))
            ctx.addLine(to: CGPoint(x: plotArea.maxX, y: plotArea.maxY))
        }
        ctx.strokePath()
        ctx.restoreGState()

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

        // Primary (left) Y-axis ticks and labels.
        drawYAxis(
            side: .left,
            yMin: geometry.primaryYMin,
            yMax: geometry.primaryYMax,
            unit: geometry.primaryUnit,
            plotArea: plotArea,
            attributes: labelAttributes,
            in: ctx
        )

        // Secondary (right) Y-axis ticks and labels, only in dual-axis mode.
        if let secMin = geometry.secondaryYMin,
           let secMax = geometry.secondaryYMax {
            drawYAxis(
                side: .right,
                yMin: secMin,
                yMax: secMax,
                unit: geometry.secondaryUnit,
                plotArea: plotArea,
                attributes: labelAttributes,
                in: ctx
            )
        }

        // Cursor: dashed vertical line plus a time label anchored at the top of the
        // plot area. Drawn last so it sits on top of tick marks and labels, and only
        // when the cursor's time value falls inside the current viewport.
        if let cursorTime = cursorTimeX,
           cursorTime >= geometry.tMin,
           cursorTime <= geometry.tMax {
            let tSpan = geometry.tMax - geometry.tMin
            guard tSpan > 0 else { return }
            let fraction = (cursorTime - geometry.tMin) / tSpan
            let x = plotArea.minX + CGFloat(fraction) * plotArea.width

            ctx.saveGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.move(to: CGPoint(x: x, y: plotArea.minY))
            ctx.addLine(to: CGPoint(x: x, y: plotArea.maxY))
            ctx.strokePath()
            ctx.restoreGState()

            // Small filled "badge" just inside the top of the plot area with the
            // cursor's time. Kept inside the plot area so the 10pt top margin
            // doesn't need to grow to accommodate the label. 9 significant
            // digits so the badge exposes the full Float32 precision of the
            // underlying TR0 sample times — matches the bottom status bar, and
            // is what users look at first.
            let timeText = EngFormat.format(cursorTime, unit: "s", significantDigits: 9)
            let timeLabelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let attributed = NSAttributedString(string: timeText, attributes: timeLabelAttributes)
            let line = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let textHeight = ascent + descent
            let padH: CGFloat = 4
            let padV: CGFloat = 1
            let badgeWidth = textWidth + padH * 2
            let badgeHeight = textHeight + padV * 2
            var badgeX = x - badgeWidth / 2
            badgeX = max(plotArea.minX + 1, min(plotArea.maxX - badgeWidth - 1, badgeX))
            let badgeY = plotArea.maxY - badgeHeight - 2

            ctx.saveGState()
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight)
            let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(badgePath)
            ctx.fillPath()
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: badgeX + padH, y: badgeY + padV + descent)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    private enum YAxisSide { case left, right }

    private func drawYAxis(
        side: YAxisSide,
        yMin: Double,
        yMax: Double,
        unit: String,
        plotArea: CGRect,
        attributes: [NSAttributedString.Key: Any],
        in ctx: CGContext
    ) {
        let ticks = AxisTicks.niceTicks(min: yMin, max: yMax, target: 6)
        let ySpan = yMax - yMin
        guard ySpan > 0 else { return }

        for tick in ticks {
            let fraction = (tick - yMin) / ySpan
            let y = plotArea.minY + CGFloat(fraction) * plotArea.height

            let tickStart: CGPoint
            let tickEnd: CGPoint
            switch side {
            case .left:
                tickStart = CGPoint(x: plotArea.minX - tickLength, y: y)
                tickEnd = CGPoint(x: plotArea.minX, y: y)
            case .right:
                tickStart = CGPoint(x: plotArea.maxX, y: y)
                tickEnd = CGPoint(x: plotArea.maxX + tickLength, y: y)
            }

            ctx.saveGState()
            ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            ctx.setLineWidth(1.0)
            ctx.move(to: tickStart)
            ctx.addLine(to: tickEnd)
            ctx.strokePath()
            ctx.restoreGState()

            let label = EngFormat.format(tick, unit: unit)
            switch side {
            case .left:
                drawLabel(
                    label,
                    rightAlignedAt: CGPoint(
                        x: plotArea.minX - tickLength - tickLabelGap,
                        y: y
                    ),
                    attributes: attributes,
                    in: ctx
                )
            case .right:
                drawLabel(
                    label,
                    leftAlignedAt: CGPoint(
                        x: plotArea.maxX + tickLength + tickLabelGap,
                        y: y
                    ),
                    attributes: attributes,
                    in: ctx
                )
            }
        }
    }

    // MARK: Core Text helpers

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

        let baselineY = point.y - ascent
        var baselineX = point.x - width / 2

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

        let baselineY = point.y - height / 2 + descent
        let baselineX = point.x - width

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: baselineX, y: baselineY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func drawLabel(
        _ text: String,
        leftAlignedAt point: CGPoint,
        attributes: [NSAttributedString.Key: Any],
        in ctx: CGContext
    ) {
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let height = ascent + descent

        let baselineY = point.y - height / 2 + descent
        let baselineX = point.x

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: baselineX, y: baselineY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
