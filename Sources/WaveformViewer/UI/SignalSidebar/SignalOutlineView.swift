import AppKit
import SwiftUI

/// SwiftUI wrapper around an `NSOutlineView` displaying a signal-hierarchy
/// forest — one file-kind root node per loaded document, each with the
/// document's own signal tree beneath it.
///
/// Every row shows a checkbox. For leaf rows the checkbox toggles that
/// signal's entry in `WaveformAppState.checkedSignals`; the main window's
/// detail pane observes this and auto-spawns a stacked plot panel for any
/// unit with at least one effective-visible signal.
/// For file-level and interior-subckt rows the checkbox toggles a gate in
/// `WaveformAppState.gateOff`: when off, every descendant's trace is hidden
/// from the plot *without* touching the descendants' own checkbox state, so
/// re-checking the gate restores the entire previously-checked set at once.
/// When the user ticks a child under an already-closed gate, every ancestor
/// gate along the path auto-re-opens so the new trace actually draws.
///
/// File rows additionally carry:
/// - a visible × button on the trailing edge that calls
///   `appState.closeDocument(_:)` (the right-click "Close File" context menu
///   works too, but people miss context menus).
///
/// Leaf rows additionally carry:
/// - an `NSColorWell` to the right of the signal-kind icon so users can
///   override the palette-derived default color per signal. Clicking the
///   well opens the shared color panel; on selection change the new color
///   flows into `WaveformAppState.customColors` and the plot rebuilds.
///
/// Focus sync: the outline's native selection is driven by
/// `WaveformAppState.focusedSignalRef`. Clicking a leaf row sets focus;
/// clicking a trace in the plot pops the corresponding sidebar row into the
/// selection. A re-entrancy guard (`isApplyingStateFocus`) prevents the
/// selection change delegate from fighting the state update during
/// programmatic selects.
///
/// `checkedSignals`, `gateOff`, `customColors`, `focusedSignalRef`, and
/// `cursorTimeX` are threaded through as direct struct properties so the
/// outer `SignalSidebar` body reads them at construction time and gets
/// subscribed to them through the Observation framework. Without those
/// reads, menu commands and plot-driven cursor moves would mutate state
/// but never trigger `updateNSView` here.
struct SignalOutlineView: NSViewRepresentable {
    let fileNodes: [HierarchyNode]
    let filterText: String
    let checkedSignals: [SignalRef]
    let gateOff: Set<HierarchyKey>
    let customColors: [SignalRef: RGBColor]
    let focusedSignalRef: SignalRef?
    let cursorTimeX: Double?
    @Bindable var state: WaveformAppState

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView(frame: .zero)
        outline.headerView = nil
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.autoresizesOutlineColumn = true
        outline.indentationPerLevel = 14
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.usesAlternatingRowBackgroundColors = false

        let column = NSTableColumn(identifier: .init("signal"))
        column.title = "Signal"
        column.minWidth = 120
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.menu = coordinator.makeFileContextMenu()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = outline

        coordinator.outlineView = outline
        coordinator.rebuild(fileNodes: fileNodes, filter: filterText)
        outline.reloadData()
        coordinator.applyFocusedRow(focusedSignalRef: focusedSignalRef)

        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let outline = context.coordinator.outlineView else { return }
        if context.coordinator.needsRebuild(fileNodes: fileNodes, filter: filterText) {
            context.coordinator.rebuild(fileNodes: fileNodes, filter: filterText)
            outline.reloadData()
        } else {
            outline.enumerateAvailableRowViews { rowView, _ in
                for column in 0..<rowView.numberOfColumns {
                    if let cell = rowView.view(atColumn: column) as? SignalCellView {
                        cell.refreshDynamicContent()
                    }
                }
            }
        }
        context.coordinator.applyFocusedRow(focusedSignalRef: focusedSignalRef)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: SignalOutlineView
        weak var outlineView: NSOutlineView?

        /// Filtered forest shown in the outline. Parallels `parent.fileNodes`
        /// with any file nodes whose descendants no longer match the filter
        /// removed.
        private var displayedFileNodes: [HierarchyNode] = []
        private var lastFileIdentities: [ObjectIdentifier] = []
        private var lastFilter: String = ""

        /// Re-entrancy guard for the focus sync. Set to `true` around our
        /// own calls to `selectRowIndexes` so the `selectionDidChange`
        /// delegate callback doesn't echo the value right back into
        /// `state.focusedSignalRef`.
        private var isApplyingStateFocus = false

        init(parent: SignalOutlineView) {
            self.parent = parent
            super.init()
        }

        func needsRebuild(fileNodes: [HierarchyNode], filter: String) -> Bool {
            if filter != lastFilter { return true }
            let identities = fileNodes.map(ObjectIdentifier.init)
            if identities != lastFileIdentities { return true }
            return false
        }

        func rebuild(fileNodes: [HierarchyNode], filter: String) {
            lastFilter = filter
            lastFileIdentities = fileNodes.map(ObjectIdentifier.init)
            if filter.isEmpty {
                displayedFileNodes = fileNodes
            } else {
                displayedFileNodes = fileNodes.compactMap { node in
                    HierarchyNode.filter(node, matching: filter)
                }
            }
        }

        /// Sync the outline's selected row to match the currently focused
        /// signal ref. Called after every `reloadData` and every
        /// `updateNSView` so the row stays highlighted through filter
        /// rebuilds. Clears the selection when `focusedSignalRef` is nil.
        func applyFocusedRow(focusedSignalRef: SignalRef?) {
            guard let outline = outlineView else { return }
            guard let ref = focusedSignalRef else {
                if outline.selectedRow >= 0 {
                    isApplyingStateFocus = true
                    outline.deselectAll(nil)
                    isApplyingStateFocus = false
                }
                return
            }
            guard let node = findLeafNode(for: ref) else {
                // Focused ref isn't visible in the current filtered forest —
                // nothing to highlight.
                if outline.selectedRow >= 0 {
                    isApplyingStateFocus = true
                    outline.deselectAll(nil)
                    isApplyingStateFocus = false
                }
                return
            }
            // Expand every ancestor so the row is actually in the outline
            // before we try to select it.
            expandAncestors(of: node)
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            if outline.selectedRow == row { return }
            isApplyingStateFocus = true
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            isApplyingStateFocus = false
        }

        /// Walk the filtered forest looking for a leaf node whose signal
        /// matches `ref`. Returns the matching `HierarchyNode` or nil when
        /// the ref isn't visible in the current filter.
        private func findLeafNode(for ref: SignalRef) -> HierarchyNode? {
            for fileNode in displayedFileNodes {
                guard case .file(let documentID) = fileNode.kind,
                      documentID == ref.document else { continue }
                if let found = findLeafNode(for: ref, in: fileNode) {
                    return found
                }
            }
            return nil
        }

        private func findLeafNode(for ref: SignalRef, in node: HierarchyNode) -> HierarchyNode? {
            if node.signalID == ref.local {
                return node
            }
            for child in node.children {
                if let found = findLeafNode(for: ref, in: child) {
                    return found
                }
            }
            return nil
        }

        /// Expand every ancestor of `node` so that NSOutlineView can return
        /// a row index for it. Walks from the top-level file nodes downward
        /// since NSOutlineView requires parents to be expanded for
        /// `row(forItem:)` to return a valid index.
        private func expandAncestors(of node: HierarchyNode) {
            guard let outline = outlineView else { return }
            let path = pathFromRoot(to: node)
            for ancestor in path.dropLast() {
                if outline.isExpandable(ancestor), !outline.isItemExpanded(ancestor) {
                    outline.expandItem(ancestor)
                }
            }
        }

        private func pathFromRoot(to target: HierarchyNode) -> [HierarchyNode] {
            for fileNode in displayedFileNodes {
                if let trail = pathFromRoot(to: target, in: fileNode) {
                    return trail
                }
            }
            return []
        }

        private func pathFromRoot(to target: HierarchyNode, in node: HierarchyNode) -> [HierarchyNode]? {
            if node === target { return [node] }
            for child in node.children {
                if let tail = pathFromRoot(to: target, in: child) {
                    return [node] + tail
                }
            }
            return nil
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let node = item as? HierarchyNode {
                return node.children.count
            }
            return displayedFileNodes.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let node = item as? HierarchyNode {
                return node.children[index]
            }
            return displayedFileNodes[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? HierarchyNode else { return false }
            return !node.children.isEmpty
        }

        // MARK: NSOutlineViewDelegate

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let node = item as? HierarchyNode else { return nil }

            let owningDocument: DocumentID? = owningDocumentID(for: node)
            let signal: Signal? = resolveSignal(for: node, owningDocument: owningDocument)

            let cell = SignalCellView(
                node: node,
                owningDocument: owningDocument,
                signal: signal,
                state: parent.state
            )
            return cell
        }

        /// Every row in the forest is selectable. The delegate callback
        /// `outlineViewSelectionDidChange` handles routing the new
        /// selection to `state.focusedSignalRef`.
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            return true
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingStateFocus, let outline = outlineView else { return }
            let row = outline.selectedRow
            guard row >= 0,
                  let node = outline.item(atRow: row) as? HierarchyNode else {
                // Clearing the selection in the sidebar also clears focus
                // in the state so the plot unhighlights its trace.
                if row < 0 {
                    parent.state.focusedSignalRef = nil
                }
                return
            }
            guard let owningDocument = owningDocumentID(for: node),
                  let localID = node.signalID else {
                // File-kind or interior-without-signal row: don't touch
                // focus. (Users can still select these rows to read the
                // highlight.)
                return
            }
            let ref = SignalRef(document: owningDocument, local: localID)
            if parent.state.focusedSignalRef != ref {
                parent.state.focusedSignalRef = ref
            }
        }

        private func resolveSignal(
            for node: HierarchyNode,
            owningDocument: DocumentID?
        ) -> Signal? {
            guard let localID = node.signalID,
                  let doc = owningDocument,
                  let loaded = parent.state.documents.first(where: { $0.id == doc }) else {
                return nil
            }
            return loaded.signal(withLocalID: localID)
        }

        /// Find the `DocumentID` of the file that contains `node`. For a file
        /// node that's trivially the documentID on its kind; for interior /
        /// leaf nodes we walk the displayedFileNodes forest.
        private func owningDocumentID(for node: HierarchyNode) -> DocumentID? {
            if let id = node.documentID { return id }
            for fileNode in displayedFileNodes {
                guard case .file(let id) = fileNode.kind else { continue }
                if contains(node, in: fileNode) {
                    return id
                }
            }
            return nil
        }

        private func contains(_ target: HierarchyNode, in root: HierarchyNode) -> Bool {
            if root === target { return true }
            for child in root.children {
                if contains(target, in: child) { return true }
            }
            return false
        }

        // MARK: File context menu

        func makeFileContextMenu() -> NSMenu {
            let menu = NSMenu()
            let close = NSMenuItem(
                title: "Close File",
                action: #selector(handleCloseFile(_:)),
                keyEquivalent: ""
            )
            close.target = self
            menu.addItem(close)
            menu.delegate = self
            return menu
        }

        @objc func handleCloseFile(_ sender: NSMenuItem) {
            guard let outline = outlineView else { return }
            let row = outline.clickedRow
            guard row >= 0 else { return }
            guard let node = outline.item(atRow: row) as? HierarchyNode,
                  let documentID = node.documentID else { return }
            parent.state.closeDocument(documentID)
        }
    }
}

extension SignalOutlineView.Coordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let outline = outlineView else {
            menu.items.forEach { $0.isHidden = true }
            return
        }
        let row = outline.clickedRow
        let isFileRow: Bool
        if row >= 0, let node = outline.item(atRow: row) as? HierarchyNode,
           node.documentID != nil {
            isFileRow = true
        } else {
            isFileRow = false
        }
        for item in menu.items {
            item.isHidden = !isFileRow
        }
    }
}

// MARK: - Custom cell view

/// Row view for the signal outline. Layout differs by node kind:
///
///     file:     [checkbox] [tray-icon] [name]                         [×]
///     interior: [checkbox] [folder]    [name]                 [value]
///     leaf:     [checkbox] [kind-icon] [colorWell] [name]     [value]
///
/// Leaf rows drive `WaveformAppState.checkedSignals`; file and interior
/// rows drive `WaveformAppState.gateOff`. The color well in leaf rows
/// forwards its picked color to `WaveformAppState.customColors`.
final class SignalCellView: NSTableCellView {
    private let node: HierarchyNode
    private let owningDocument: DocumentID?
    private let signal: Signal?
    private weak var state: WaveformAppState?

    private let checkbox = NSButton()
    private let iconView = NSImageView()
    private let colorWell = NSColorWell(style: .minimal)
    private let nameField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    init(
        node: HierarchyNode,
        owningDocument: DocumentID?,
        signal: Signal?,
        state: WaveformAppState
    ) {
        self.node = node
        self.owningDocument = owningDocument
        self.signal = signal
        self.state = state
        super.init(frame: .zero)
        setupSubviews()
        populate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupSubviews() {
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.imagePosition = .imageOnly
        checkbox.target = self
        checkbox.action = #selector(handleCheckbox(_:))

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.isBordered = false
        colorWell.target = self
        colorWell.action = #selector(handleColorWell(_:))
        colorWell.toolTip = "Click to change this signal's trace color"

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.textField = nameField

        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        valueField.textColor = .secondaryLabelColor
        valueField.alignment = .right
        valueField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        valueField.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close file"
        )
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(handleCloseFile(_:))
        closeButton.toolTip = "Close this file"

        addSubview(checkbox)
        addSubview(iconView)
        addSubview(colorWell)
        addSubview(nameField)
        addSubview(valueField)
        addSubview(closeButton)

        // The icon and the color well share the same "leading widget" slot.
        // Each row only shows one or the other (file/interior-folder rows
        // get the icon; leaf rows get the color well). Sharing the slot
        // keeps every row's name column aligned at the same x regardless
        // of kind, which is what NSOutlineView's source-list style wants.
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 16),

            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            colorWell.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            colorWell.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorWell.widthAnchor.constraint(equalToConstant: 16),
            colorWell.heightAnchor.constraint(equalToConstant: 14),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: valueField.leadingAnchor, constant: -8),

            valueField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func populate() {
        nameField.stringValue = node.name.isEmpty ? "(unnamed)" : node.name

        switch node.kind {
        case .file:
            // File rows show a tray glyph in the leading slot, bold name,
            // and a close button on the trailing edge. No color well —
            // files aren't drawn in the plot.
            checkbox.isHidden = false
            nameField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            iconView.isHidden = false
            iconView.image = NSImage(
                systemSymbolName: "tray.full",
                accessibilityDescription: nil
            )
            iconView.contentTintColor = .secondaryLabelColor
            colorWell.isHidden = true
            valueField.isHidden = true
            closeButton.isHidden = false
        case .interior:
            // Interior rows without a probe show a folder icon. Interior
            // rows that DO probe their own signal act like leaves and
            // show a color well instead.
            checkbox.isHidden = false
            nameField.font = .systemFont(ofSize: NSFont.systemFontSize)
            closeButton.isHidden = true
            if signal != nil {
                iconView.isHidden = true
                colorWell.isHidden = false
                valueField.isHidden = false
            } else {
                iconView.isHidden = false
                iconView.image = NSImage(
                    systemSymbolName: "folder",
                    accessibilityDescription: nil
                )
                iconView.contentTintColor = .secondaryLabelColor
                colorWell.isHidden = true
                valueField.isHidden = true
            }
        case .leaf:
            // Leaf rows: the color well IS the leading glyph. The kind
            // (voltage / current / power) is implicit from the hosting
            // plot panel's unit label, so we don't also clutter the row
            // with a bolt/arrows/sun glyph next to the swatch.
            checkbox.isHidden = false
            nameField.font = .systemFont(ofSize: NSFont.systemFontSize)
            closeButton.isHidden = true
            iconView.isHidden = true
            if signal != nil {
                colorWell.isHidden = false
                valueField.isHidden = false
            } else {
                colorWell.isHidden = true
                valueField.isHidden = true
            }
        }

        refreshDynamicContent()
    }

    /// Refreshes the checkbox (gate or visibility), the color well, and
    /// the cursor-readout value label. Called from `updateNSView` on
    /// observed-state changes.
    func refreshDynamicContent() {
        guard let state = state else { return }
        switch node.kind {
        case .file, .interior:
            if let key = hierarchyKey() {
                checkbox.state = state.isGateOpen(key) ? .on : .off
            } else {
                checkbox.state = .on
            }
            if case .interior = node.kind, signal != nil, let ref = leafRef() {
                populateCursorValue(ref: ref, signal: signal!, state: state)
                colorWell.color = state.color(for: ref)
            }
        case .leaf:
            if let ref = leafRef() {
                checkbox.state = state.isChecked(ref) ? .on : .off
                if let signal = signal {
                    populateCursorValue(ref: ref, signal: signal, state: state)
                }
                colorWell.color = state.color(for: ref)
            }
        }
    }

    private func populateCursorValue(ref: SignalRef, signal: Signal, state: WaveformAppState) {
        if let cursorTime = state.cursorTimeX,
           let loaded = state.documents.first(where: { $0.id == ref.document }),
           let value = signal.value(atTime: cursorTime, timeValues: loaded.timeValues) {
            valueField.stringValue = EngFormat.format(Double(value), unit: signal.unit)
            valueField.isHidden = false
        } else {
            valueField.stringValue = ""
            valueField.isHidden = true
        }
    }

    @objc private func handleCheckbox(_ sender: NSButton) {
        guard let state = state else { return }
        let turningOn = (sender.state == .on)
        switch node.kind {
        case .file:
            guard let key = hierarchyKey() else { return }
            state.setGateOpen(key, open: turningOn)
        case .interior:
            if signal == nil {
                guard let key = hierarchyKey() else { return }
                state.setGateOpen(key, open: turningOn)
            } else {
                guard let ref = leafRef() else { return }
                state.setSignalChecked(ref, checked: turningOn)
            }
        case .leaf:
            guard let ref = leafRef() else { return }
            state.setSignalChecked(ref, checked: turningOn)
        }
    }

    @objc private func handleColorWell(_ sender: NSColorWell) {
        guard let state = state, let ref = leafRef() else { return }
        state.setCustomColor(sender.color, for: ref)
    }

    @objc private func handleCloseFile(_ sender: NSButton) {
        guard let state = state, let id = node.documentID else { return }
        state.closeDocument(id)
    }

    private func hierarchyKey() -> HierarchyKey? {
        guard let doc = owningDocument else { return nil }
        return HierarchyKey(document: doc, fullPath: node.fullPath)
    }

    private func leafRef() -> SignalRef? {
        guard let doc = owningDocument, let local = node.signalID else { return nil }
        return SignalRef(document: doc, local: local)
    }

    private func iconName(for kind: SignalKind) -> String {
        switch kind {
        case .voltage:      return "bolt.fill"
        case .current:      return "arrow.left.and.right.circle.fill"
        case .power:        return "sun.max.fill"
        case .logicVoltage: return "waveform.path"
        case .unknown:      return "questionmark.circle"
        }
    }
}
