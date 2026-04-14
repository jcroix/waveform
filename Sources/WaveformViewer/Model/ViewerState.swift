import AppKit
import Foundation
import Observation

/// App-global state for the waveform viewer. Phase 15 replaced the per-window
/// `ViewerState` with a single shared instance that lives on `WaveformViewerApp`
/// and is injected into every scene (hub window + per-unit plot windows). All
/// loaded files, the signal hierarchy forest, the visibility gate state, the
/// cursor, the linked-X viewport, and the per-unit Y viewports live here so
/// that closing and reopening a unit window is lossless and so the hub sidebar
/// can drive every open unit window in lockstep.
///
/// Why one global state object instead of several per-window states?
/// - The user's mental model is "my files are loaded in the app, and these
///   windows are views onto subsets of them" — not "each window owns its own
///   files". Two windows observing one appState is the literal implementation
///   of that model.
/// - Unit windows are SwiftUI `Window` scenes (singletons). Closing one tears
///   down the view instance but keeps the state alive, so reopening pulls the
///   prior zoom/visible-trace state straight out of `appState` rather than
///   needing a separate persistence layer.
/// - The File menu (Open… / Close File) targets the whole app state once
///   instead of routing through `@FocusedValue` to whichever window happens to
///   be frontmost.
@Observable @MainActor
public final class WaveformAppState {
    // MARK: - Loaded documents

    /// All currently-loaded documents in the order they were opened. Each entry
    /// carries its freshly-minted `DocumentID` so the visibility and gate state
    /// can reference it without going through a URL comparison.
    public private(set) var documents: [LoadedDocument] = []

    /// One file-kind `HierarchyNode` per entry in `documents`, built at load
    /// time. Parallel array — `fileNodes[i]` describes `documents[i]`. Exposed
    /// as the top-level forest to the sidebar's `NSOutlineView`.
    public private(set) var fileNodes: [HierarchyNode] = []

    /// Human-readable error for the most recent failed load, or nil. Populated
    /// when `open(urls:)` catches at least one parse failure and merged with
    /// newlines when a multi-file open has partial failures.
    public var loadError: String?

    // MARK: - Sidebar filter

    public var filterText: String = ""

    // MARK: - Visibility

    /// Child-checkbox state: every signal the user has ticked in the sidebar,
    /// in z-order. The last element is drawn on top, just like the previous
    /// `visibleSignalIDs` array. Unchecking a parent gate does NOT remove
    /// entries from this list — it only hides them from the plot via the
    /// `gateOff` mask — so re-checking the parent restores the whole
    /// previously-checked set instantly.
    public var checkedSignals: [SignalRef] = []

    /// Set of hierarchy nodes whose gate checkbox is currently OFF. The gate
    /// defaults to ON for every node, so absence from this set means "gate
    /// open". A signal is plot-visible iff it's in `checkedSignals` AND none
    /// of its ancestors (file-level, subckt-level) appear in this set.
    public var gateOff: Set<HierarchyKey> = []

    /// Signal the user has focused by clicking a trace in the plot area. Used
    /// to render the focused trace at a heavier line width and to target the
    /// move-to-front / move-to-back commands. Cleared when the focused signal
    /// is hidden, when all signals are hidden, and when the focused signal's
    /// owning file is closed.
    public var focusedSignalRef: SignalRef?

    // MARK: - Plot viewport (X)

    /// Per-unit local X viewports, keyed by `SignalKind`. Used when linked-X is
    /// off so each unit window can zoom/pan independently. Missing entry =
    /// "full span" (the union of loaded documents' time ranges).
    public var localViewportsX: [SignalKind: ClosedRange<Double>] = [:]

    // MARK: - Plot viewport (Y)

    /// Per-unit Y viewport overrides, keyed by `SignalKind`. Missing key =
    /// auto-scale from data. Each unit window writes and reads its own entry.
    public var viewportsY: [SignalKind: ClosedRange<Double>] = [:]

    // MARK: - Cursor

    public var cursorTimeX: Double?

    // MARK: - UI prefs

    public var showGrid: Bool = true

    // MARK: - Shared linked-zoom state

    /// Reference to the app-level shared-X plot state. Still exists so multi-
    /// window linking works across hub + every unit window.
    public let sharedState: SharedPlotState

    public init(sharedState: SharedPlotState) {
        self.sharedState = sharedState
    }

    // MARK: - Linked-X convenience

    public var linkedXZoom: Bool {
        get { sharedState.linkedXZoom }
        set { setLinkedXZoom(newValue) }
    }

    /// Toggle the linked-X mode, handling the transition cleanly. On an
    /// unlinked → linked flip we seed the shared viewport from the "most
    /// zoomed" local so every window converges onto the same range. On a
    /// linked → unlinked flip we capture the current shared value into every
    /// visible unit's local so nothing jumps.
    public func setLinkedXZoom(_ linked: Bool) {
        let wasLinked = sharedState.linkedXZoom
        if linked && !wasLinked {
            // Seed shared from any populated local, preferring the first
            // visible-unit entry to cover the common single-unit case.
            if let first = localViewportsX.values.first {
                sharedState.viewportX = first
            }
        }
        sharedState.linkedXZoom = linked
        if wasLinked && !linked {
            let shared = sharedState.viewportX
            for unit in visibleUnits() {
                if let shared = shared {
                    localViewportsX[unit] = shared
                } else {
                    localViewportsX.removeValue(forKey: unit)
                }
            }
        }
    }

    // MARK: - X viewport routing

    /// Returns the effective X viewport for a given unit. When linked, every
    /// unit shares `sharedState.viewportX`. When unlinked, each unit reads its
    /// own entry from `localViewportsX`.
    public func xViewport(for unit: SignalKind) -> ClosedRange<Double>? {
        if sharedState.linkedXZoom {
            return sharedState.viewportX
        }
        return localViewportsX[unit]
    }

    /// Writes the effective X viewport for a given unit. Linked mode writes
    /// to the shared viewport; unlinked mode writes to the per-unit slot.
    public func setXViewport(_ range: ClosedRange<Double>?, for unit: SignalKind) {
        if sharedState.linkedXZoom {
            sharedState.viewportX = range
            return
        }
        if let range = range {
            localViewportsX[unit] = range
        } else {
            localViewportsX.removeValue(forKey: unit)
        }
    }

    // MARK: - Document open/close

    /// Test-only seam that installs a pre-built `[LoadedDocument]` directly,
    /// skipping the `WaveformDocument.load(from:)` parse step. Production
    /// code must not call this — the filesystem pathway is the only
    /// authoritative way to add a document.
    internal func testResetDocuments(_ loaded: [LoadedDocument]) {
        documents = loaded
        fileNodes = loaded.map { entry in
            HierarchyNode.fileContainer(
                wrapping: entry.document.hierarchyRoot,
                documentID: entry.id,
                name: fileNodeName(for: entry)
            )
        }
        checkedSignals.removeAll()
        gateOff.removeAll()
        focusedSignalRef = nil
        loadError = nil
        if !documents.isEmpty {
            seedViewportsFromOverallRange()
            filterText = ""
            cursorTimeX = nil
        }
    }

    /// Load one or more files and append them to the currently-loaded set.
    /// Parse errors for individual files are collected into `loadError` with
    /// newline separators; successfully-parsed files are still appended so
    /// partial multi-file opens don't lose data.
    public func open(urls: [URL]) {
        var errors: [String] = []
        let wasEmpty = documents.isEmpty

        for url in urls {
            do {
                let doc = try WaveformDocument.load(from: url)
                let id = DocumentID()
                let loaded = LoadedDocument(id: id, document: doc)
                documents.append(loaded)
                let fileNode = HierarchyNode.fileContainer(
                    wrapping: doc.hierarchyRoot,
                    documentID: id,
                    name: fileNodeName(for: loaded)
                )
                fileNodes.append(fileNode)
            } catch {
                errors.append("\(url.lastPathComponent): \(error)")
            }
        }

        if errors.isEmpty {
            loadError = nil
        } else {
            loadError = errors.joined(separator: "\n")
        }

        if wasEmpty && !documents.isEmpty {
            // First load seeds the X viewport to full range.
            seedViewportsFromOverallRange()
            filterText = ""
            cursorTimeX = nil
        }
    }

    /// Remove a loaded file from the app state. Prunes every reference to its
    /// `DocumentID` from checked signals, gates, focus, and per-unit X/Y
    /// viewports; recomputes `overallTimeRange` and clamps any active
    /// viewport into the new union.
    public func closeDocument(_ id: DocumentID) {
        documents.removeAll { $0.id == id }
        fileNodes.removeAll { $0.documentID == id }
        checkedSignals.removeAll { $0.document == id }
        gateOff = gateOff.filter { $0.document != id }
        if focusedSignalRef?.document == id {
            focusedSignalRef = nil
        }

        if documents.isEmpty {
            localViewportsX.removeAll()
            viewportsY.removeAll()
            if sharedState.linkedXZoom {
                sharedState.viewportX = nil
            }
            cursorTimeX = nil
            loadError = nil
            return
        }

        // Clamp any in-use X viewport into the new overall time range.
        if let full = overallTimeRange {
            if sharedState.linkedXZoom {
                if let current = sharedState.viewportX {
                    sharedState.viewportX = clamp(current, into: full)
                }
            } else {
                for (unit, current) in localViewportsX {
                    localViewportsX[unit] = clamp(current, into: full)
                }
            }
            if let cursor = cursorTimeX {
                cursorTimeX = min(max(cursor, full.lowerBound), full.upperBound)
            }
        }
    }

    /// Show an `NSOpenPanel` and, on confirmation, load every selected file
    /// into the app state.
    public func presentOpenPanel() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select one or more .tr0 or .out files"
        panel.prompt = "Open"

        if panel.runModal() == .OK {
            open(urls: panel.urls)
        }
    }

    // MARK: - Titles

    /// Window title for the hub and (prefixed) for the per-unit plot windows.
    /// 0 docs → "Waveform Viewer". 1 doc → its document title. ≥2 docs → a
    /// comma-joined list of basenames, truncated to "a, b, +N more" when
    /// there are more than 2.
    public var hubTitle: String {
        switch documents.count {
        case 0:
            return "Waveform Viewer"
        case 1:
            return documents[0].title
        case 2:
            return "\(documents[0].sourceURL.lastPathComponent), \(documents[1].sourceURL.lastPathComponent)"
        default:
            let first = documents[0].sourceURL.lastPathComponent
            let second = documents[1].sourceURL.lastPathComponent
            return "\(first), \(second), +\(documents.count - 2) more"
        }
    }

    public func unitWindowTitle(for unit: SignalKind) -> String {
        if documents.isEmpty {
            return unit.displayName
        }
        return "\(unit.displayName) — \(hubTitle)"
    }

    // MARK: - Time range / overall span

    public var overallTimeRange: ClosedRange<Double>? {
        var lo: Double = .infinity
        var hi: Double = -.infinity
        for loaded in documents {
            guard let range = loaded.timeRange else { continue }
            if range.lowerBound < lo { lo = range.lowerBound }
            if range.upperBound > hi { hi = range.upperBound }
        }
        guard lo.isFinite, hi.isFinite, hi > lo else { return nil }
        return lo...hi
    }

    // MARK: - Visibility model

    /// The effective (plot-visible) signals for a given unit, in z-order.
    /// Filters `checkedSignals` by unit and drops any signal whose ancestor
    /// gate is currently OFF.
    public func effectiveVisibleSignals(unit: SignalKind) -> [SignalRef] {
        checkedSignals.filter { ref in
            signalKind(for: ref) == unit && !anyAncestorGateOff(of: ref)
        }
    }

    /// Every unit kind that currently has at least one effective-visible
    /// signal. Used by zoom-to-fit menu commands that operate on every
    /// currently-visible unit window at once.
    public func visibleUnits() -> [SignalKind] {
        var seen: Set<SignalKind> = []
        var result: [SignalKind] = []
        for ref in checkedSignals {
            guard !anyAncestorGateOff(of: ref) else { continue }
            let kind = signalKind(for: ref)
            if !seen.contains(kind) {
                seen.insert(kind)
                result.append(kind)
            }
        }
        return result
    }

    /// The `SignalKind` of a given ref, resolving through `documents`. Returns
    /// `.unknown("")` if the reference dangles (the caller has held onto a ref
    /// past its owning document's close, which we treat as a silent no-op).
    public func signalKind(for ref: SignalRef) -> SignalKind {
        resolve(ref)?.kind ?? .unknown("")
    }

    /// Resolve a `SignalRef` to its underlying `Signal` plus the owning
    /// `LoadedDocument`. Returns `nil` when the ref has gone stale (its
    /// document has been closed).
    public func resolve(_ ref: SignalRef) -> Signal? {
        guard let doc = documents.first(where: { $0.id == ref.document }) else {
            return nil
        }
        return doc.signal(withLocalID: ref.local)
    }

    /// Resolve a ref to the `(loadedDocument, signal)` pair. Used by the plot
    /// rebuild path which needs both the `Signal.values` and the owning
    /// document's `timeValues` to build a per-trace path.
    public func resolveFull(_ ref: SignalRef) -> (LoadedDocument, Signal)? {
        guard let doc = documents.first(where: { $0.id == ref.document }),
              let signal = doc.signal(withLocalID: ref.local) else {
            return nil
        }
        return (doc, signal)
    }

    /// Whether the signal referenced by `ref` would actually draw right now:
    /// present in `checkedSignals` AND every ancestor gate is open.
    public func isEffectiveVisible(_ ref: SignalRef) -> Bool {
        guard checkedSignals.contains(ref) else { return false }
        return !anyAncestorGateOff(of: ref)
    }

    /// Whether the raw checkbox state for `ref` is on. Distinct from
    /// `isEffectiveVisible`: the user can have a signal ticked whose parent
    /// gate is off, in which case it shows as checked in the sidebar but
    /// doesn't draw in the plot.
    public func isChecked(_ ref: SignalRef) -> Bool {
        checkedSignals.contains(ref)
    }

    /// Toggle the child-checkbox state for a single signal.
    ///
    /// Adding appends to the end of `checkedSignals` (so new traces start at
    /// the top of the z-order, matching the old single-file behavior). When
    /// checking a signal whose ancestor gate is currently off, every ancestor
    /// gate along the path is flipped back on so the new trace actually
    /// appears — otherwise the user would wonder why checking produced no
    /// visible change.
    public func setSignalChecked(_ ref: SignalRef, checked: Bool) {
        if checked {
            if !checkedSignals.contains(ref) {
                checkedSignals.append(ref)
            }
            // Re-enable any ancestor gates that were off so the newly-checked
            // signal is actually drawable.
            for ancestor in ancestorKeys(of: ref) {
                gateOff.remove(ancestor)
            }
        } else {
            checkedSignals.removeAll { $0 == ref }
            if focusedSignalRef == ref {
                focusedSignalRef = nil
            }
        }
    }

    /// Toggle the hierarchy gate for `key`. `on == true` opens the gate (the
    /// default, i.e. "no override"); `on == false` closes it, hiding every
    /// descendant from the plot while leaving their child checkbox state
    /// intact. If the focused signal is under a newly-closed gate, unfocus so
    /// trace-move commands don't target a signal the user can't see.
    public func setGateOpen(_ key: HierarchyKey, open: Bool) {
        if open {
            gateOff.remove(key)
        } else {
            gateOff.insert(key)
            if let focus = focusedSignalRef,
               focus.document == key.document,
               pathComponents(of: focus).contains(where: { ancestorKey in
                   ancestorKey.fullPath == key.fullPath
               }) {
                focusedSignalRef = nil
            }
        }
    }

    /// Whether the gate for `key` is currently open (the default).
    public func isGateOpen(_ key: HierarchyKey) -> Bool {
        !gateOff.contains(key)
    }

    /// The hierarchy keys of every ancestor gate above `ref`, ordered from
    /// file-level down to (but not including) the leaf's own level.
    public func ancestorKeys(of ref: SignalRef) -> [HierarchyKey] {
        guard let signal = resolve(ref) else { return [] }
        // File-level gate always exists, with fullPath "".
        var keys: [HierarchyKey] = [HierarchyKey(document: ref.document, fullPath: "")]
        // Every intermediate path-prefix is a potential interior gate.
        let separator = documents.first { $0.id == ref.document }?.document.hierarchySeparator ?? "."
        var running: [String] = []
        // path contains every component; stop BEFORE the last one so the leaf
        // itself isn't treated as its own ancestor.
        for component in signal.path.dropLast() {
            running.append(component)
            keys.append(HierarchyKey(
                document: ref.document,
                fullPath: running.joined(separator: separator)
            ))
        }
        return keys
    }

    /// Whether any ancestor gate above `ref` is currently closed.
    public func anyAncestorGateOff(of ref: SignalRef) -> Bool {
        for key in ancestorKeys(of: ref) where gateOff.contains(key) {
            return true
        }
        return false
    }

    private func pathComponents(of ref: SignalRef) -> [HierarchyKey] {
        ancestorKeys(of: ref)
    }

    // MARK: - Bulk visibility commands

    /// Check every signal in every loaded document. Used by View → Show All
    /// Signals.
    public func showAllSignals() {
        checkedSignals = documents.flatMap { loaded in
            loaded.signals.map { SignalRef(document: loaded.id, local: $0.id) }
        }
        // Open every gate so the user actually sees everything.
        gateOff.removeAll()
    }

    /// Uncheck every signal. Focus is cleared as a side effect.
    public func hideAllSignals() {
        checkedSignals.removeAll()
        focusedSignalRef = nil
    }

    // MARK: - Z-order (Phase 9.2)

    public func moveFocusedToFront() {
        guard let ref = focusedSignalRef,
              let index = checkedSignals.firstIndex(of: ref),
              index != checkedSignals.count - 1 else { return }
        checkedSignals.remove(at: index)
        checkedSignals.append(ref)
    }

    public func moveFocusedToBack() {
        guard let ref = focusedSignalRef,
              let index = checkedSignals.firstIndex(of: ref),
              index != 0 else { return }
        checkedSignals.remove(at: index)
        checkedSignals.insert(ref, at: 0)
    }

    // MARK: - Viewport commands

    /// Reset every X viewport and Y override. Called by ⌘0 and double-click.
    public func resetViewport() {
        resetXViewport()
        viewportsY.removeAll()
    }

    public func resetXViewport() {
        localViewportsX.removeAll()
        sharedState.viewportX = nil
    }

    public func resetYViewport() {
        viewportsY.removeAll()
    }

    // MARK: - Fixed-level X zoom

    /// Zoom the X axis of every visible unit around the cursor (or viewport
    /// midpoint) by `factor`. Called by View → Horizontal Zoom In/Out.
    public func zoomX(by factor: Double) {
        guard factor > 0,
              let full = overallTimeRange,
              full.upperBound > full.lowerBound else { return }

        let units = sharedState.linkedXZoom ? [SignalKind.voltage] : visibleUnits()
        // In linked mode we only need to zoom once (the shared viewport is
        // the same for every unit); the .voltage dummy above is just to get
        // the loop to run exactly once.
        for unit in units {
            let current = effectiveXViewport(for: unit, full: full)
            let anchor: Double
            if let cursor = cursorTimeX, cursor >= current.lowerBound, cursor <= current.upperBound {
                anchor = cursor
            } else {
                anchor = (current.lowerBound + current.upperBound) / 2
            }
            let span = current.upperBound - current.lowerBound
            let newSpan = span / factor
            let fraction = (anchor - current.lowerBound) / span
            var lower = anchor - fraction * newSpan
            var upper = anchor + (1 - fraction) * newSpan
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
            guard lower < upper else { continue }

            if abs(lower - full.lowerBound) < 1e-18 && abs(upper - full.upperBound) < 1e-18 {
                setXViewport(nil, for: unit)
            } else {
                setXViewport(lower...upper, for: unit)
            }
        }
    }

    /// Set the X viewport to `fullSpan / absolute` centered on the cursor
    /// (or midpoint). `absolute = 1` is full range.
    public func setZoomX(absolute: Double) {
        guard absolute >= 1, let full = overallTimeRange else { return }
        let fullSpan = full.upperBound - full.lowerBound
        let newSpan = fullSpan / absolute

        let units = sharedState.linkedXZoom ? [SignalKind.voltage] : visibleUnits()
        for unit in units {
            let currentViewport = effectiveXViewport(for: unit, full: full)
            let anchor: Double
            if let cursor = cursorTimeX {
                anchor = cursor
            } else {
                anchor = (currentViewport.lowerBound + currentViewport.upperBound) / 2
            }
            var lower = anchor - newSpan / 2
            var upper = lower + newSpan
            if lower < full.lowerBound {
                lower = full.lowerBound
                upper = lower + newSpan
            }
            if upper > full.upperBound {
                upper = full.upperBound
                lower = max(full.lowerBound, upper - newSpan)
            }
            if lower == full.lowerBound && upper == full.upperBound {
                setXViewport(nil, for: unit)
            } else {
                setXViewport(lower...upper, for: unit)
            }
        }
    }

    /// Zoom every visible Y axis by `factor` around each axis's midpoint.
    public func zoomY(by factor: Double) {
        guard factor > 0 else { return }
        for unit in visibleUnits() {
            let current = viewportsY[unit] ?? fullYRange(for: unit)
            guard let current = current else { continue }
            let mid = (current.lowerBound + current.upperBound) / 2
            let span = current.upperBound - current.lowerBound
            let newSpan = span / factor
            viewportsY[unit] = (mid - newSpan / 2)...(mid + newSpan / 2)
        }
    }

    public func setZoomY(absolute: Double) {
        guard absolute >= 1 else { return }
        for unit in visibleUnits() {
            guard let full = fullYRange(for: unit) else { continue }
            let span = full.upperBound - full.lowerBound
            let newSpan = span / absolute
            let mid = (full.lowerBound + full.upperBound) / 2
            if absolute <= 1.0 + 1e-9 {
                viewportsY.removeValue(forKey: unit)
            } else {
                viewportsY[unit] = (mid - newSpan / 2)...(mid + newSpan / 2)
            }
        }
    }

    /// The auto-scale Y range for a unit, computed from every currently-
    /// checked-and-ungated signal of that unit across every loaded document.
    /// Used as the fallback when the user has no explicit Y override and as
    /// the clamp target for pan-limit calculations.
    public func fullYRange(for unit: SignalKind) -> ClosedRange<Double>? {
        var yMin: Float = .greatestFiniteMagnitude
        var yMax: Float = -.greatestFiniteMagnitude
        var seen = false
        for ref in checkedSignals where !anyAncestorGateOff(of: ref) {
            guard let signal = resolve(ref), signal.kind == unit else { continue }
            for v in signal.values {
                if v < yMin { yMin = v }
                if v > yMax { yMax = v }
                seen = true
            }
        }
        guard seen, yMin.isFinite, yMax.isFinite else { return nil }
        var lo = Double(yMin)
        var hi = Double(yMax)
        if lo == hi {
            let fallback = lo == 0 ? 1.0 : abs(lo) * 0.1
            lo -= fallback
            hi += fallback
        } else {
            let pad = (hi - lo) * 0.05
            lo -= pad
            hi += pad
        }
        return lo...hi
    }

    // MARK: - Cursor

    public func clearCursor() {
        cursorTimeX = nil
    }

    public func goToTime(_ time: Double) {
        guard let full = overallTimeRange else { return }
        let clamped = min(max(time, full.lowerBound), full.upperBound)
        let units = sharedState.linkedXZoom ? [SignalKind.voltage] : visibleUnits()
        for unit in units {
            let current = effectiveXViewport(for: unit, full: full)
            let span = current.upperBound - current.lowerBound
            var lower = clamped - span / 2
            var upper = lower + span
            if lower < full.lowerBound {
                lower = full.lowerBound
                upper = lower + span
            }
            if upper > full.upperBound {
                upper = full.upperBound
                lower = max(full.lowerBound, upper - span)
            }
            if lower == full.lowerBound && upper == full.upperBound {
                setXViewport(nil, for: unit)
            } else {
                setXViewport(lower...upper, for: unit)
            }
        }
        cursorTimeX = clamped
    }

    public func presentGoToTimeDialog() {
        guard !documents.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Go to Time"
        alert.informativeText = "Enter a time (e.g. 17ns, 1.5us, 3.2e-9)."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.placeholderString = "17ns"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        guard let parsed = EngFormat.parseTime(textField.stringValue) else { return }
        goToTime(parsed)
    }

    // MARK: - Private helpers

    private func fileNodeName(for loaded: LoadedDocument) -> String {
        // Prefer the basename of the file the user clicked — that's what they
        // recognize in a multi-file comparison. Fall back to the document's
        // parsed title (which for TR0 is the truncated 64-char header title).
        let basename = loaded.sourceURL.lastPathComponent
        return basename.isEmpty ? loaded.title : basename
    }

    private func seedViewportsFromOverallRange() {
        localViewportsX.removeAll()
        if sharedState.linkedXZoom {
            sharedState.viewportX = nil
        }
    }

    private func effectiveXViewport(
        for unit: SignalKind,
        full: ClosedRange<Double>
    ) -> ClosedRange<Double> {
        if let explicit = xViewport(for: unit) {
            return explicit
        }
        return full
    }

    private func clamp(
        _ range: ClosedRange<Double>,
        into full: ClosedRange<Double>
    ) -> ClosedRange<Double>? {
        let lower = max(range.lowerBound, full.lowerBound)
        let upper = min(range.upperBound, full.upperBound)
        guard lower < upper else { return nil }
        if lower == full.lowerBound && upper == full.upperBound {
            return nil
        }
        return lower...upper
    }
}
