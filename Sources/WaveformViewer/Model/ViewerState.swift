import AppKit
import Foundation
import Observation

/// The top-level app-wide state for a single viewer window. Owned by the `WaveformViewerApp`
/// scene as `@State` and passed to subviews via `@Bindable`. One instance per window scene;
/// Phase 14 introduced multi-window support — each `WindowGroup` window gets its own
/// `ViewerState` and menu commands route to the focused window via `@FocusedValue`.
@Observable @MainActor
public final class ViewerState {
    // MARK: - Document

    public var document: WaveformDocument?
    public var loadError: String?

    // MARK: - Sidebar filter

    public var filterText: String = ""

    // MARK: - Visible traces

    /// Ordered list of signals currently plotted. The order IS the z-order: the last
    /// element is drawn on top. Phase 9.2 added move-to-front / move-to-back commands
    /// that rearrange this array.
    public var visibleSignalIDs: [SignalID] = []

    /// Signal the user has focused by clicking a trace in the plot area. Used to
    /// render the focused trace at a heavier line width and to target the
    /// move-to-front / move-to-back commands. Cleared by toggleVisibility when the
    /// focused signal is hidden, by hideAllSignals, and by open(url:).
    public var focusedSignalID: SignalID?

    // MARK: - Plot viewport

    /// Visible time range on the X axis. `nil` means "full sample span". Pinch and
    /// scroll-pan gestures mutate this in place; menu commands (View → Zoom to Fit)
    /// and ⌘0 reset it to `nil`. Viewport is deliberately per-state, so cross-window
    /// linked-zoom mode can share it later by pointing multiple windows at the same
    /// underlying viewport.
    public var viewportX: ClosedRange<Double>?

    /// Per-unit Y viewport overrides, keyed by the signal unit string (`"V"`, `"A"`,
    /// `"W"`, …). Missing key = auto-scale to the full data range (the Phase 13
    /// default behavior). Present key = lock the Y axis of every plot rendering that
    /// unit to the given range. ⌥-pinch and vertical scroll gestures mutate this
    /// map; ⌘0 and double-click clear it entirely.
    public var viewportsY: [String: ClosedRange<Double>] = [:]

    // MARK: - Cursor

    /// X-axis position of the single cursor, in simulation-time units. `nil` means
    /// no cursor is placed. Clicking anywhere in the plot area sets this to the
    /// click's time; View → Clear Cursor or ⌘L clears it. Persists across
    /// visibility changes and zoom/pan — the cursor is tied to a time value, not a
    /// pixel, so panning slides it naturally with the content.
    public var cursorTimeX: Double?

    // MARK: - Plot layout

    /// How traces with different units are arranged in this window. Defaults to
    /// stacked strips, which gives each unit its own auto-scaled Y axis in a
    /// separate pane.
    public var plotLayout: PlotLayout = .stackedStrips

    /// Whether the plot draws gridlines at the axis-tick positions. Defaults to
    /// `true`; toggled via View → Show Grid.
    public var showGrid: Bool = true

    public init() {}

    // MARK: - Document open

    /// Load a file and swap it in as the current document. On failure, clears the
    /// document and records `loadError` for display in the UI.
    public func open(url: URL) {
        do {
            let next = try WaveformDocument.load(from: url)
            document = next
            loadError = nil
            visibleSignalIDs = []
            focusedSignalID = nil
            viewportX = nil
            viewportsY = [:]
            cursorTimeX = nil
            filterText = ""
        } catch {
            loadError = String(describing: error)
            document = nil
            visibleSignalIDs = []
            focusedSignalID = nil
            viewportX = nil
            viewportsY = [:]
            cursorTimeX = nil
        }
    }

    /// Show an `NSOpenPanel` and, on confirmation, load the chosen file.
    public func presentOpenPanel() {
        // Force the app to the front before the modal runs. Without this, an
        // un-bundled `swift run` process can drop the panel's focus the moment the
        // user clicks into it.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select a .tr0 or .out file"
        panel.prompt = "Open"

        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    // MARK: - Signal visibility

    /// Returns whether `signalID` is currently plotted.
    public func isVisible(_ signalID: SignalID) -> Bool {
        visibleSignalIDs.contains(signalID)
    }

    /// Toggle visibility for a single signal. Adding appends to the end of the array
    /// (so newly-added traces start at the top of the z-order).
    public func toggleVisibility(_ signalID: SignalID) {
        if let index = visibleSignalIDs.firstIndex(of: signalID) {
            visibleSignalIDs.remove(at: index)
            if focusedSignalID == signalID {
                focusedSignalID = nil
            }
        } else {
            visibleSignalIDs.append(signalID)
        }
    }

    /// Show every signal in the loaded document.
    public func showAllSignals() {
        guard let document = document else { return }
        visibleSignalIDs = document.signals.map(\.id)
    }

    /// Hide every visible trace.
    public func hideAllSignals() {
        visibleSignalIDs.removeAll()
        focusedSignalID = nil
    }

    // MARK: - Z-order (Phase 9.2)

    /// Move the focused trace to the top of the z-order (drawn last = on top).
    /// No-op if no trace is focused or the focused trace isn't visible.
    public func moveFocusedToFront() {
        guard let id = focusedSignalID,
              let index = visibleSignalIDs.firstIndex(of: id),
              index != visibleSignalIDs.count - 1 else { return }
        visibleSignalIDs.remove(at: index)
        visibleSignalIDs.append(id)
    }

    /// Move the focused trace to the bottom of the z-order (drawn first = behind
    /// every other trace). No-op if no trace is focused or the focused trace isn't
    /// visible.
    public func moveFocusedToBack() {
        guard let id = focusedSignalID,
              let index = visibleSignalIDs.firstIndex(of: id),
              index != 0 else { return }
        visibleSignalIDs.remove(at: index)
        visibleSignalIDs.insert(id, at: 0)
    }

    // MARK: - Viewport commands

    /// Reset both the X-axis viewport and every Y-axis override to "auto-scale"
    /// behavior. Called by ⌘0 and double-click.
    public func resetViewport() {
        viewportX = nil
        viewportsY = [:]
    }

    /// Reset the X viewport only.
    public func resetXViewport() {
        viewportX = nil
    }

    /// Remove every per-unit Y viewport override, letting each unit auto-scale to its
    /// full data range again.
    public func resetYViewport() {
        viewportsY = [:]
    }

    // MARK: - Fixed-level zooms

    /// Zoom the X axis around the cursor (or viewport midpoint if no cursor is
    /// placed) by `factor`. `factor > 1` zooms IN (shrinks span); `factor < 1` zooms
    /// OUT. Clamped to the simulation's full time span.
    public func zoomX(by factor: Double) {
        guard factor > 0,
              let document = document,
              let fullStart = document.timeValues.first,
              let fullEnd = document.timeValues.last,
              fullEnd > fullStart else { return }

        let full = fullStart...fullEnd
        let current = viewportX ?? full
        let anchor: Double
        if let cursor = cursorTimeX, cursor >= current.lowerBound, cursor <= current.upperBound {
            anchor = cursor
        } else {
            anchor = (current.lowerBound + current.upperBound) / 2
        }
        let currentSpan = current.upperBound - current.lowerBound
        let newSpan = currentSpan / factor

        let anchorFraction = (anchor - current.lowerBound) / currentSpan
        var newLower = anchor - anchorFraction * newSpan
        var newUpper = anchor + (1 - anchorFraction) * newSpan

        if newLower < full.lowerBound {
            let shift = full.lowerBound - newLower
            newLower += shift
            newUpper += shift
        }
        if newUpper > full.upperBound {
            let shift = newUpper - full.upperBound
            newLower -= shift
            newUpper -= shift
        }
        newLower = max(newLower, full.lowerBound)
        newUpper = min(newUpper, full.upperBound)
        guard newLower < newUpper else { return }

        if abs(newLower - full.lowerBound) < 1e-18 && abs(newUpper - full.upperBound) < 1e-18 {
            viewportX = nil
        } else {
            viewportX = newLower...newUpper
        }
    }

    /// Set the X viewport span to `fullSpan / absolute` centered on the cursor (or
    /// midpoint) at the current zoom level. `absolute = 1` is the full range.
    public func setZoomX(absolute: Double) {
        guard absolute >= 1,
              let document = document,
              let fullStart = document.timeValues.first,
              let fullEnd = document.timeValues.last,
              fullEnd > fullStart else { return }

        let fullSpan = fullEnd - fullStart
        let newSpan = fullSpan / absolute
        let anchor: Double
        if let cursor = cursorTimeX {
            anchor = cursor
        } else if let existing = viewportX {
            anchor = (existing.lowerBound + existing.upperBound) / 2
        } else {
            anchor = (fullStart + fullEnd) / 2
        }

        var newLower = anchor - newSpan / 2
        var newUpper = newLower + newSpan
        if newLower < fullStart {
            newLower = fullStart
            newUpper = newLower + newSpan
        }
        if newUpper > fullEnd {
            newUpper = fullEnd
            newLower = max(fullStart, newUpper - newSpan)
        }
        if newLower == fullStart && newUpper == fullEnd {
            viewportX = nil
        } else {
            viewportX = newLower...newUpper
        }
    }

    /// Zoom every Y axis by `factor` around each axis's midpoint. `factor > 1` zooms
    /// IN; `factor < 1` zooms OUT. Each unit's current effective range (either an
    /// override or the auto-scaled full range computed from the signals) is taken
    /// as the starting point. The result is stored as an override in `viewportsY`.
    public func zoomY(by factor: Double) {
        guard factor > 0, let document = document else { return }

        for unit in uniqueVisibleUnits() {
            let current = effectiveYRange(for: unit, document: document) ?? fullYRange(for: unit, document: document)
            guard let current = current else { continue }
            let mid = (current.lowerBound + current.upperBound) / 2
            let span = current.upperBound - current.lowerBound
            let newSpan = span / factor
            viewportsY[unit] = (mid - newSpan / 2)...(mid + newSpan / 2)
        }
    }

    /// Set every Y axis's span to `(full range of that unit) / absolute`, centered on
    /// each unit's full-range midpoint.
    public func setZoomY(absolute: Double) {
        guard absolute >= 1, let document = document else { return }
        for unit in uniqueVisibleUnits() {
            guard let full = fullYRange(for: unit, document: document) else { continue }
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

    // MARK: Y-viewport helpers (internal)

    /// Returns the set of unique signal units represented in `visibleSignalIDs`. The
    /// fixed-level Y zoom commands apply to every unique unit so stacked strips and
    /// dual-axis panes both get zoomed in one action.
    private func uniqueVisibleUnits() -> [String] {
        guard let document = document else { return [] }
        var seen: Set<String> = []
        var result: [String] = []
        for id in visibleSignalIDs {
            guard let signal = document.signal(withID: id) else { continue }
            if !seen.contains(signal.unit) {
                seen.insert(signal.unit)
                result.append(signal.unit)
            }
        }
        return result
    }

    private func effectiveYRange(for unit: String, document: WaveformDocument) -> ClosedRange<Double>? {
        if let override = viewportsY[unit] { return override }
        return fullYRange(for: unit, document: document)
    }

    private func fullYRange(for unit: String, document: WaveformDocument) -> ClosedRange<Double>? {
        var yMin = Float.greatestFiniteMagnitude
        var yMax = -Float.greatestFiniteMagnitude
        var seen = false
        for signal in document.signals where signal.unit == unit && visibleSignalIDs.contains(signal.id) {
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

    // MARK: - Cursor commands

    /// Remove the cursor from the plot.
    public func clearCursor() {
        cursorTimeX = nil
    }

    /// Set the cursor to `time` (clamped to the simulation's sample span) and recenter
    /// the current viewport on it. If the requested time is too close to either end
    /// for a full centered view at the current zoom level, the viewport anchors
    /// against that end instead. At full-range zoom this leaves the viewport alone;
    /// only the cursor moves.
    public func goToTime(_ time: Double) {
        guard let document = document,
              let fullStart = document.timeValues.first,
              let fullEnd = document.timeValues.last,
              fullEnd > fullStart else { return }

        let clamped = min(max(time, fullStart), fullEnd)

        let currentViewport = viewportX ?? (fullStart...fullEnd)
        let span = currentViewport.upperBound - currentViewport.lowerBound

        var newLower = clamped - span / 2
        var newUpper = newLower + span

        if newLower < fullStart {
            newLower = fullStart
            newUpper = newLower + span
        }
        if newUpper > fullEnd {
            newUpper = fullEnd
            newLower = max(fullStart, newUpper - span)
        }

        if newLower == fullStart && newUpper == fullEnd {
            viewportX = nil
        } else {
            viewportX = newLower...newUpper
        }

        cursorTimeX = clamped
    }

    /// Show a modal prompting the user for a time, then call `goToTime(_:)`.
    /// Parses the input via `EngFormat.parseTime`; silently ignores parse failures
    /// so the user can correct and retry.
    public func presentGoToTimeDialog() {
        guard document != nil else { return }
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

    // MARK: - Signal grouping for plot layout

    /// Groups the visible signal IDs by unit, preserving `visibleSignalIDs` z-order
    /// within each group. Returns an ordered array: the first unit encountered in
    /// the visible list appears first. Used by the stacked-strips plot layout to
    /// give each unit (V, A, W, L, …) its own pane with its own auto-scaled Y axis.
    public func visibleSignalGroups() -> [PlotUnitGroup] {
        guard let document = document else { return [] }
        var groupsByUnit: [String: PlotUnitGroup] = [:]
        var unitOrder: [String] = []
        for id in visibleSignalIDs {
            guard let signal = document.signal(withID: id) else { continue }
            let unit = signal.unit
            if groupsByUnit[unit] == nil {
                groupsByUnit[unit] = PlotUnitGroup(unit: unit, signalIDs: [])
                unitOrder.append(unit)
            }
            groupsByUnit[unit]?.signalIDs.append(id)
        }
        return unitOrder.compactMap { groupsByUnit[$0] }
    }
}

public struct PlotUnitGroup: Sendable, Equatable, Identifiable {
    public var unit: String
    public var signalIDs: [SignalID]

    public var id: String { unit }
}
