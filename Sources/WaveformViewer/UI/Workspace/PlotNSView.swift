import AppKit
import CoreText
import QuartzCore

/// Layer-backed NSView that renders a set of traces for a single unit window
/// (voltage, current, power, or logic). Phase 15 collapsed the old dual-axis
/// shape into single-unit: each `UnitPlotWindow` hosts exactly one PlotNSView
/// drawing one unit's traces, potentially sourced from multiple loaded
/// documents.
///
/// Layer stack (bottom → top):
///   - view root layer         (background fill)
///   - traceContainer          (frame = plot area, masksToBounds = true)
///       ├── gridLayer         (delegate-drawn, zPosition = -1)
///       └── trace CAShapeLayers (polyline paths in plot-area coordinates)
///   - axisLayer               (zPosition = 1, frame = full bounds, delegate-drawn)
///   - boxZoomLayer            (zPosition = 10)
///
/// Trace layers are reused across rebuilds via a pool so CA's rasterization
/// cache stays warm; this and `shouldRasterize = true` are load-bearing for the
/// WindowServer CPU invariant documented in CLAUDE.md.
final class PlotNSView: NSView {

    // MARK: - Inputs

    /// Every loaded document, keyed by `DocumentID`. Used to resolve each
    /// `SignalRef` in the assignment to a concrete `(Signal, timeValues)` pair
    /// on each rebuild. Two signals in the same assignment can come from two
    /// different documents; each draws against its owner's time grid.
    private var documents: [DocumentID: LoadedDocument] = [:]
    private var documentOrder: [DocumentID] = []

    private var assignment: PlotTraceAssignment = PlotTraceAssignment(refs: [], unit: .unknown(""))

    // MARK: - Viewport

    /// Visible time range supplied by the owning `WaveformAppState`. `nil`
    /// means "show the full overall span" (the union of every loaded doc's
    /// time range).
    private var viewportX: ClosedRange<Double>?

    /// Overall X span supplied from outside (union of loaded docs' time
    /// ranges). Used for auto-scale, clamping, and fallback when
    /// `viewportX` is nil.
    private var overallRange: ClosedRange<Double>?

    /// Y range override for this plot's unit, `nil` means auto-scale.
    private var yOverride: ClosedRange<Double>?

    var onViewportChange: ((ClosedRange<Double>?) -> Void)?

    /// Called when a Y-axis pinch or scroll proposes a new range. Passes
    /// `nil` to clear the override back to auto-scale.
    var onYViewportChange: ((ClosedRange<Double>?) -> Void)?

    /// Called when the user triggers "reset everything" (double-click or ⌘0).
    var onResetAll: (() -> Void)?

    private var pinchStartViewport: ClosedRange<Double>?
    private var pinchStartY: ClosedRange<Double>?
    private var pinchIsYAxis: Bool = false

    // MARK: - Focus

    private var focusedSignalRef: SignalRef?

    var onFocusChange: ((SignalRef?) -> Void)?

    private let hitTestRadius: CGFloat = 8

    // MARK: - Cursor

    private var cursorTimeX: Double?

    var onCursorChange: ((Double?) -> Void)?

    private var lastClickLocation: CGPoint?
    private var lastCycleCandidates: [SignalRef] = []
    private var lastCycleIndex: Int = -1

    private let cycleLocationTolerance: CGFloat = 3

    // MARK: - Layers

    private let traceContainer = CALayer()
    private let gridLayer = CALayer()
    private let axisLayer = CALayer()
    private let boxZoomLayer = CAShapeLayer()
    private var traceLayers: [CAShapeLayer] = []

    // MARK: - Box zoom

    private var boxZoomStart: CGPoint?
    private var boxZoomCurrent: CGPoint?
    private let minimumBoxZoomSize: CGFloat = 5

    private var showGrid: Bool = true

    /// Resolves a `SignalRef` to its effective color (custom override or
    /// palette default). Injected via `setContent` so `PlotNSView` stays
    /// model-agnostic — the owning SwiftUI view wires it to
    /// `WaveformAppState.color(for:)`.
    private var colorFor: (SignalRef) -> NSColor = { ref in
        ColorPalette.stableColor(for: ref)
    }

    // MARK: - Decimation cache

    private let decimationCache = DecimationCache(maxEntries: 32)

    // MARK: - Rebuild coalescing

    private struct RebuildKey: Equatable {
        let documentSignature: [UUID]
        let sampleCounts: [Int]
        let refs: [SignalRef]
        let unit: String
        let boundsSize: CGSize
        let viewportLowerBits: UInt64
        let viewportUpperBits: UInt64
        let focusedSignalRef: SignalRef?
        let cursorBits: UInt64?
        let showGrid: Bool
        let yLowerBits: UInt64
        let yUpperBits: UInt64
        let colorSignature: [ColorSignatureEntry]
    }
    private var lastRebuildKey: RebuildKey?
    private var colorSignature: [ColorSignatureEntry] = []

    // MARK: - Margins

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

        gridLayer.contentsScale = scale
        gridLayer.delegate = self
        gridLayer.zPosition = -1
        gridLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull(),
        ]
        traceContainer.addSublayer(gridLayer)

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

        boxZoomLayer.strokeColor = NSColor.controlAccentColor.cgColor
        boxZoomLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        boxZoomLayer.lineWidth = 1.0
        boxZoomLayer.lineDashPattern = [4, 3]
        boxZoomLayer.zPosition = 10
        boxZoomLayer.isHidden = true
        boxZoomLayer.actions = [
            "path": NSNull(),
            "hidden": NSNull(),
            "frame": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
        ]
        root.addSublayer(boxZoomLayer)

        installGestureRecognizers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for PlotNSView")
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
        let plotArea = computePlotArea()

        if event.modifierFlags.contains(.option), plotArea.contains(clickLocal) {
            boxZoomStart = clickLocal
            boxZoomCurrent = clickLocal
            return
        }

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

    override func mouseDragged(with event: NSEvent) {
        if boxZoomStart != nil {
            let local = convert(event.locationInWindow, from: nil)
            let plotArea = computePlotArea()
            let clamped = CGPoint(
                x: max(plotArea.minX, min(plotArea.maxX, local.x)),
                y: max(plotArea.minY, min(plotArea.maxY, local.y))
            )
            boxZoomCurrent = clamped
            updateBoxZoomLayer()
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let start = boxZoomStart, let end = boxZoomCurrent {
            boxZoomStart = nil
            boxZoomCurrent = nil
            hideBoxZoomLayer()

            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            if rect.width >= minimumBoxZoomSize && rect.height >= minimumBoxZoomSize {
                applyBoxZoom(rect: rect)
            } else {
                handleSingleClick(at: start)
            }
            return
        }
        super.mouseUp(with: event)
    }

    private func applyBoxZoom(rect: CGRect) {
        guard let geometry = computeGeometry() else { return }
        let plotArea = geometry.plotArea
        guard plotArea.width > 0, plotArea.height > 0 else { return }

        let tSpan = geometry.tMax - geometry.tMin
        let leftFraction = Double((rect.minX - plotArea.minX) / plotArea.width)
        let rightFraction = Double((rect.maxX - plotArea.minX) / plotArea.width)
        let clampedLeft = min(max(0, leftFraction), 1)
        let clampedRight = min(max(0, rightFraction), 1)
        let newTStart = geometry.tMin + clampedLeft * tSpan
        let newTEnd = geometry.tMin + clampedRight * tSpan
        if newTEnd > newTStart {
            applyViewport(newTStart...newTEnd)
        }

        let bottomFraction = Double((rect.minY - plotArea.minY) / plotArea.height)
        let topFraction = Double((rect.maxY - plotArea.minY) / plotArea.height)
        let clampedBottom = min(max(0, bottomFraction), 1)
        let clampedTop = min(max(0, topFraction), 1)

        let ySpan = geometry.yMax - geometry.yMin
        let yNewMin = geometry.yMin + clampedBottom * ySpan
        let yNewMax = geometry.yMin + clampedTop * ySpan
        if yNewMax > yNewMin {
            applyYViewport(yNewMin...yNewMax)
        }
    }

    private func updateBoxZoomLayer() {
        guard let start = boxZoomStart, let end = boxZoomCurrent else {
            hideBoxZoomLayer()
            return
        }
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boxZoomLayer.path = CGPath(rect: rect, transform: nil)
        boxZoomLayer.isHidden = false
        CATransaction.commit()
    }

    private func hideBoxZoomLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boxZoomLayer.path = nil
        boxZoomLayer.isHidden = true
        CATransaction.commit()
    }

    private func handleSingleClick(at clickLocal: CGPoint) {
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
        } else {
            lastClickLocation = clickLocal
            lastCycleCandidates = candidates
            lastCycleIndex = 0
            onFocusChange?(candidates[0])
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, boxZoomStart != nil {  // 53 = kVK_Escape
            boxZoomStart = nil
            boxZoomCurrent = nil
            hideBoxZoomLayer()
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "0" {
            onResetAll?()
            return
        }
        let key = Int(event.keyCode)
        if key == 123 || key == 124 {
            let direction: ArrowStepDirection = (key == 123) ? .backward : .forward
            handleArrowStep(direction: direction, modifiers: event.modifierFlags)
            return
        }
        super.keyDown(with: event)
    }

    private enum ArrowStepDirection { case backward, forward }

    /// Advance the cursor to the previous/next sample in the "primary"
    /// document's time grid. In multi-file mode the primary doc is whichever
    /// currently-assigned signal owns the first ref — that's the document the
    /// user most recently added, which is the intuitive choice for the
    /// cursor's fine-grained stepping.
    private func handleArrowStep(direction: ArrowStepDirection, modifiers: NSEvent.ModifierFlags) {
        guard let primary = primaryDocument(), !primary.timeValues.isEmpty else { return }

        let startTime: Double
        if let existing = cursorTimeX {
            startTime = existing
        } else if let viewport = effectiveViewport() {
            startTime = (viewport.lowerBound + viewport.upperBound) / 2
        } else {
            return
        }

        let times = primary.timeValues
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
            step = times.count
        } else if modifiers.contains(.shift) {
            step = 10
        } else {
            step = 1
        }

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
        if boxZoomLayer.frame != bounds {
            boxZoomLayer.frame = bounds
        }
        if gridLayer.frame != traceContainer.bounds {
            gridLayer.frame = traceContainer.bounds
        }
        CATransaction.commit()
        rebuildIfNeeded()
    }

    // MARK: - Public API

    func setContent(
        documents: [DocumentID: LoadedDocument],
        documentOrder: [DocumentID],
        assignment: PlotTraceAssignment,
        overallRange: ClosedRange<Double>?,
        viewport: ClosedRange<Double>?,
        yOverride: ClosedRange<Double>?,
        focusedSignalRef: SignalRef?,
        cursorTimeX: Double?,
        showGrid: Bool,
        colorSignature: [ColorSignatureEntry],
        colorFor: @escaping (SignalRef) -> NSColor
    ) {
        let docsChanged = (self.documentOrder != documentOrder)
        self.documents = documents
        self.documentOrder = documentOrder
        self.assignment = assignment
        self.overallRange = overallRange
        self.viewportX = viewport
        self.yOverride = yOverride
        self.focusedSignalRef = focusedSignalRef
        self.cursorTimeX = cursorTimeX
        self.showGrid = showGrid
        self.colorSignature = colorSignature
        self.colorFor = colorFor
        if docsChanged {
            decimationCache.removeAll()
        }
        rebuildIfNeeded()
    }

    private func computePlotArea() -> CGRect {
        let m = margins
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

        var sampleCounts: [Int] = []
        sampleCounts.reserveCapacity(documentOrder.count)
        for id in documentOrder {
            sampleCounts.append(documents[id]?.timeValues.count ?? 0)
        }

        let yRange = currentYRange()
        let key = RebuildKey(
            documentSignature: documentOrder.map(\.raw),
            sampleCounts: sampleCounts,
            refs: assignment.refs,
            unit: assignment.unit.routingID,
            boundsSize: bounds.size,
            viewportLowerBits: effective?.lowerBound.bitPattern ?? 0,
            viewportUpperBits: effective?.upperBound.bitPattern ?? 0,
            focusedSignalRef: focusedSignalRef,
            cursorBits: cursorTimeX?.bitPattern,
            showGrid: showGrid,
            yLowerBits: yRange?.lowerBound.bitPattern ?? 0,
            yUpperBits: yRange?.upperBound.bitPattern ?? 0,
            colorSignature: colorSignature
        )
        if key == lastRebuildKey {
            return
        }
        lastRebuildKey = key
        axisLayer.setNeedsDisplay()
        gridLayer.setNeedsDisplay()
        rebuildTraces()
    }

    // MARK: - Viewport helpers

    private func effectiveViewport() -> ClosedRange<Double>? {
        if let viewportX = viewportX {
            return viewportX
        }
        return overallRange
    }

    private func applyViewport(_ proposed: ClosedRange<Double>) {
        guard let full = overallRange, proposed.lowerBound < proposed.upperBound else {
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
        switch gesture.state {
        case .began:
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            pinchIsYAxis = modifiers.contains(.option)

            if pinchIsYAxis {
                guard let geometry = computeGeometry() else { return }
                pinchStartY = geometry.yMin...geometry.yMax
            } else {
                guard let full = overallRange else { return }
                pinchStartViewport = effectiveViewport() ?? full
            }

        case .changed:
            let factor = 1.0 + gesture.magnification
            guard factor > 0.01 else { return }

            if pinchIsYAxis {
                guard let start = pinchStartY else { return }
                let plotArea = computePlotArea()
                let cursor = gesture.location(in: self)
                let clampedY = max(plotArea.minY, min(plotArea.maxY, cursor.y))
                let anchorFraction: Double
                if plotArea.height > 0 {
                    anchorFraction = Double(clampedY - plotArea.minY) / Double(plotArea.height)
                } else {
                    anchorFraction = 0.5
                }
                let startSpan = start.upperBound - start.lowerBound
                let newSpan = max(startSpan / factor, startSpan * 1e-6)
                let anchorValue = start.lowerBound + anchorFraction * startSpan
                let newLower = anchorValue - anchorFraction * newSpan
                let newUpper = anchorValue + (1 - anchorFraction) * newSpan
                applyYViewport(newLower...newUpper)
                return
            }

            guard let start = pinchStartViewport, let full = overallRange else { return }
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
            pinchStartY = nil
            pinchIsYAxis = false
        default:
            break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        if deltaX != 0 {
            panX(deltaX: Double(deltaX))
        }
        if deltaY != 0 {
            panY(deltaY: Double(deltaY))
        }
        if deltaX == 0 && deltaY == 0 {
            super.scrollWheel(with: event)
        }
    }

    private func panX(deltaX: Double) {
        guard let current = effectiveViewport() else { return }
        let plotArea = computePlotArea()
        guard plotArea.width > 0 else { return }
        let span = current.upperBound - current.lowerBound
        let timeDelta = -deltaX / Double(plotArea.width) * span
        let proposed = (current.lowerBound + timeDelta)...(current.upperBound + timeDelta)
        applyViewport(proposed)
    }

    private func panY(deltaY: Double) {
        let plotArea = computePlotArea()
        guard plotArea.height > 0 else { return }
        guard let geometry = computeGeometry() else { return }

        let span = geometry.yMax - geometry.yMin
        guard span > 0 else { return }
        let shift = -deltaY / Double(plotArea.height) * span
        let proposed = (geometry.yMin + shift)...(geometry.yMax + shift)
        applyYViewport(proposed)
    }

    /// Propose a new Y range, clamping into the auto-scaled full range from
    /// all visible signals of this unit (across every owning document).
    private func applyYViewport(_ proposed: ClosedRange<Double>) {
        guard proposed.upperBound > proposed.lowerBound else { return }
        guard let full = fullAutoYRange() else {
            onYViewportChange?(proposed)
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

        if abs(lower - full.lowerBound) < 1e-18 && abs(upper - full.upperBound) < 1e-18 {
            onYViewportChange?(nil)
        } else {
            onYViewportChange?(lower...upper)
        }
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        onResetAll?()
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
        let yMin: Double
        let yMax: Double
    }

    /// Computes a padded Y range covering every assigned signal's values.
    private func fullAutoYRange() -> ClosedRange<Double>? {
        var yMin: Float = .greatestFiniteMagnitude
        var yMax: Float = -.greatestFiniteMagnitude
        var seen = false
        for ref in assignment.refs {
            guard let (_, signal) = resolve(ref) else { continue }
            for v in signal.values {
                if v < yMin { yMin = v }
                if v > yMax { yMax = v }
                seen = true
            }
        }
        guard seen, yMin.isFinite, yMax.isFinite, yMin <= yMax else { return nil }

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
        return yMinD...yMaxD
    }

    private func currentYRange() -> ClosedRange<Double>? {
        if let override = yOverride { return override }
        return fullAutoYRange()
    }

    private func computeGeometry() -> PlotGeometry? {
        guard !assignment.refs.isEmpty else { return nil }
        guard let yRange = currentYRange() else { return nil }
        guard let viewport = effectiveViewport() else { return nil }

        return PlotGeometry(
            plotArea: computePlotArea(),
            tMin: viewport.lowerBound,
            tMax: viewport.upperBound,
            yMin: yRange.lowerBound,
            yMax: yRange.upperBound
        )
    }

    // MARK: - Trace rendering

    private func rebuildTraces() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let geometry = computeGeometry() else {
            for trace in traceLayers {
                trace.removeFromSuperlayer()
            }
            traceLayers.removeAll()
            return
        }

        // Pair each ref with its resolved (document, signal). Drop refs that
        // dangle — the closing-a-file code path prunes visibleRefs eagerly,
        // but it's still possible to see a stale ref during a transient
        // rebuild, so be defensive.
        let resolved: [(ref: SignalRef, doc: LoadedDocument, signal: Signal)] = assignment.refs
            .compactMap { ref in
                guard let (doc, signal) = resolve(ref) else { return nil }
                return (ref, doc, signal)
            }
        guard !resolved.isEmpty else {
            for trace in traceLayers {
                trace.removeFromSuperlayer()
            }
            traceLayers.removeAll()
            return
        }

        traceContainer.frame = geometry.plotArea

        while traceLayers.count < resolved.count {
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
        while traceLayers.count > resolved.count {
            traceLayers.removeLast().removeFromSuperlayer()
        }

        let width = Double(geometry.plotArea.width)
        let height = Double(geometry.plotArea.height)
        let rasterScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        let pixelWidth = max(1, Int(width.rounded(.up)))
        let viewport: ClosedRange<Double> = geometry.tMin...geometry.tMax

        let ySpan = geometry.yMax - geometry.yMin

        for (traceIndex, entry) in resolved.enumerated() {
            let shape = traceLayers[traceIndex]
            let signal = entry.signal
            guard signal.values.count > 1, ySpan > 0 else {
                shape.path = nil
                continue
            }

            let decimated = decimationCache.decimatedTrace(
                for: signal,
                ref: entry.ref,
                timeValues: entry.doc.timeValues,
                viewport: viewport,
                pixelWidth: pixelWidth
            )

            let path = buildDecimatedPath(
                decimated: decimated,
                yMin: geometry.yMin,
                ySpan: ySpan,
                plotHeight: height
            )

            let isFocused = (entry.ref == focusedSignalRef)
            shape.frame = traceContainer.bounds
            shape.path = path
            shape.strokeColor = colorFor(entry.ref).cgColor
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

    private func hitTestCandidates(at point: CGPoint) -> [SignalRef] {
        let plotArea = computePlotArea()
        guard plotArea.contains(point) else { return [] }

        guard let geometry = computeGeometry() else { return [] }

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

        let ySpan = geometry.yMax - geometry.yMin
        guard ySpan > 0 else { return [] }

        struct Match {
            let ref: SignalRef
            let traceIndex: Int
            var distance: Double
        }
        var matches: [SignalRef: Match] = [:]

        for (traceIndex, ref) in assignment.refs.enumerated() {
            guard let (doc, signal) = resolve(ref) else { continue }

            let decimated = decimationCache.decimatedTrace(
                for: signal,
                ref: ref,
                timeValues: doc.timeValues,
                viewport: viewport,
                pixelWidth: pixelWidth
            )
            guard decimated.buckets.count == pixelWidth else { continue }

            for column in lowColumn...highColumn {
                let bucket = decimated.buckets[column]
                guard bucket.isPopulated else { continue }

                let bucketX = Double(column)
                let yLow = (Double(bucket.minValue) - geometry.yMin) / ySpan * plotHeight
                let yHigh = (Double(bucket.maxValue) - geometry.yMin) / ySpan * plotHeight

                let clampedY = max(yLow, min(yHigh, clickY))
                let dx = clickXOffset - bucketX
                let dy = clickY - clampedY
                let distance = (dx * dx + dy * dy).squareRoot()

                guard distance <= radius else { continue }

                if let existing = matches[ref] {
                    if distance < existing.distance {
                        matches[ref] = Match(ref: ref, traceIndex: traceIndex, distance: distance)
                    }
                } else {
                    matches[ref] = Match(ref: ref, traceIndex: traceIndex, distance: distance)
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
            .map(\.ref)
    }

    // MARK: - Resolution helpers

    private func resolve(_ ref: SignalRef) -> (LoadedDocument, Signal)? {
        guard let doc = documents[ref.document],
              let signal = doc.signal(withLocalID: ref.local) else {
            return nil
        }
        return (doc, signal)
    }

    private func primaryDocument() -> LoadedDocument? {
        for ref in assignment.refs {
            if let doc = documents[ref.document] {
                return doc
            }
        }
        // Fall back to the first loaded document so arrow keys still work
        // before any trace has been checked.
        return documentOrder.first.flatMap { documents[$0] }
    }
}

// MARK: - CALayerDelegate (axis drawing)

extension PlotNSView: CALayerDelegate {
    func draw(_ layer: CALayer, in ctx: CGContext) {
        if layer === axisLayer {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                drawAxes(in: ctx)
            }
        } else if layer === gridLayer {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                drawGrid(in: ctx)
            }
        }
    }

    private func drawGrid(in ctx: CGContext) {
        guard showGrid else { return }
        guard let geometry = computeGeometry() else { return }

        let width = gridLayer.bounds.width
        let height = gridLayer.bounds.height
        guard width > 1, height > 1 else { return }

        let tSpan = geometry.tMax - geometry.tMin
        let ySpan = geometry.yMax - geometry.yMin
        guard tSpan > 0, ySpan > 0 else { return }

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: [2, 3])

        let xTicks = AxisTicks.niceTicks(min: geometry.tMin, max: geometry.tMax, target: 6)
        for tick in xTicks {
            let fraction = (tick - geometry.tMin) / tSpan
            guard fraction > 0.001, fraction < 0.999 else { continue }
            let x = CGFloat(fraction) * width
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: height))
        }

        let yTicks = AxisTicks.niceTicks(min: geometry.yMin, max: geometry.yMax, target: 6)
        for tick in yTicks {
            let fraction = (tick - geometry.yMin) / ySpan
            guard fraction > 0.001, fraction < 0.999 else { continue }
            let y = CGFloat(fraction) * height
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: width, y: y))
        }

        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawAxes(in ctx: CGContext) {
        let plotArea = computePlotArea()
        guard plotArea.width > 1, plotArea.height > 1 else { return }

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: plotArea.minX, y: plotArea.minY))
        ctx.addLine(to: CGPoint(x: plotArea.minX, y: plotArea.maxY))
        ctx.move(to: CGPoint(x: plotArea.minX, y: plotArea.minY))
        ctx.addLine(to: CGPoint(x: plotArea.maxX, y: plotArea.minY))
        ctx.strokePath()
        ctx.restoreGState()

        guard let geometry = computeGeometry() else { return }

        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

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

        // Y axis ticks and labels (single axis now — whatever unit this window
        // is bound to).
        let yUnit = unitLabel(for: assignment.unit)
        let yTicks = AxisTicks.niceTicks(min: geometry.yMin, max: geometry.yMax, target: 6)
        let ySpan = geometry.yMax - geometry.yMin
        if ySpan > 0 {
            for tick in yTicks {
                let fraction = (tick - geometry.yMin) / ySpan
                let y = plotArea.minY + CGFloat(fraction) * plotArea.height

                ctx.saveGState()
                ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
                ctx.setLineWidth(1.0)
                ctx.move(to: CGPoint(x: plotArea.minX - tickLength, y: y))
                ctx.addLine(to: CGPoint(x: plotArea.minX, y: y))
                ctx.strokePath()
                ctx.restoreGState()

                let label = EngFormat.format(tick, unit: yUnit)
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

        // Cursor overlay.
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

    private func unitLabel(for kind: SignalKind) -> String {
        switch kind {
        case .voltage, .logicVoltage: return "V"
        case .current:                return "A"
        case .power:                  return "W"
        case .unknown(let raw):       return raw
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
}
