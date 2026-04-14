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
/// File rows have a right-click context menu with a single "Close File"
/// action that calls `appState.closeDocument(_:)`.
///
/// `checkedSignals`, `gateOff`, and `cursorTimeX` are threaded through as
/// direct struct properties so the outer `SignalSidebar` body reads them at
/// construction time and gets subscribed to them through the Observation
/// framework. Without those reads, menu commands and plot-driven cursor moves
/// would mutate state but never trigger `updateNSView` here.
struct SignalOutlineView: NSViewRepresentable {
    let fileNodes: [HierarchyNode]
    let filterText: String
    let checkedSignals: [SignalRef]
    let gateOff: Set<HierarchyKey>
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

            // Resolve the document this node belongs to so we can build refs
            // and gate keys without re-walking the forest every refresh.
            let owningDocument: DocumentID? = owningDocumentID(for: node)
            let signal: Signal? = {
                guard case .leaf = node.kind,
                      let local = node.signalID,
                      let doc = owningDocument,
                      let loaded = parent.state.documents.first(where: { $0.id == doc }) else {
                    return nil
                }
                return loaded.signal(withLocalID: local)
            }()

            let cell = SignalCellView(
                node: node,
                owningDocument: owningDocument,
                signal: signal,
                state: parent.state
            )
            return cell
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

        /// Build a one-item NSMenu bound to our coordinator. NSOutlineView
        /// raises -menu(for:) on right-click; we use the dynamic
        /// outlineView:menu: delegate method approach via the plain `menu`
        /// property plus per-row validation inside the action.
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

/// Row view for the signal outline. Layout:
///
///     [checkbox] [icon] [name]                 [value]
///
/// Leaf rows drive `WaveformAppState.checkedSignals`; file and interior rows
/// drive `WaveformAppState.gateOff`. `value` is populated only when a cursor
/// is placed in the plot and this row corresponds to a real signal. The file
/// row icon is a tray, interior rows get a folder, leaves get the
/// signal-kind-specific glyph.
final class SignalCellView: NSTableCellView {
    private let node: HierarchyNode
    private let owningDocument: DocumentID?
    private let signal: Signal?
    private let state: WaveformAppState

    private let checkbox = NSButton()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")

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

        addSubview(checkbox)
        addSubview(iconView)
        addSubview(nameField)
        addSubview(valueField)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 16),

            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: valueField.leadingAnchor, constant: -8),

            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func populate() {
        nameField.stringValue = node.name.isEmpty ? "(unnamed)" : node.name

        switch node.kind {
        case .file:
            checkbox.isHidden = false
            nameField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            iconView.image = NSImage(
                systemSymbolName: "tray.full",
                accessibilityDescription: nil
            )
            iconView.contentTintColor = .secondaryLabelColor
            valueField.isHidden = true
        case .interior:
            checkbox.isHidden = false
            if let signal = signal {
                iconView.image = NSImage(
                    systemSymbolName: iconName(for: signal.kind),
                    accessibilityDescription: nil
                )
                if let ref = leafRef() {
                    iconView.contentTintColor = ColorPalette.stableColor(for: ref)
                } else {
                    iconView.contentTintColor = .secondaryLabelColor
                }
                valueField.isHidden = false
            } else {
                iconView.image = NSImage(
                    systemSymbolName: "folder",
                    accessibilityDescription: nil
                )
                iconView.contentTintColor = .secondaryLabelColor
                valueField.isHidden = true
            }
        case .leaf:
            checkbox.isHidden = false
            if let signal = signal {
                iconView.image = NSImage(
                    systemSymbolName: iconName(for: signal.kind),
                    accessibilityDescription: nil
                )
                if let ref = leafRef() {
                    iconView.contentTintColor = ColorPalette.stableColor(for: ref)
                }
                valueField.isHidden = false
            }
        }

        refreshDynamicContent()
    }

    /// Refreshes the checkbox (gate or visibility) and the cursor-readout
    /// value label. Called from `updateNSView` on observed-state changes.
    func refreshDynamicContent() {
        switch node.kind {
        case .file, .interior:
            if let key = hierarchyKey() {
                checkbox.state = state.isGateOpen(key) ? .on : .off
            } else {
                checkbox.state = .on
            }
            if case .interior = node.kind, signal != nil, let ref = leafRef() {
                // Interior node that also probes a signal: show cursor value.
                populateCursorValue(ref: ref, signal: signal!)
            }
        case .leaf:
            if let ref = leafRef() {
                checkbox.state = state.isChecked(ref) ? .on : .off
                if let signal = signal {
                    populateCursorValue(ref: ref, signal: signal)
                }
            }
        }
    }

    private func populateCursorValue(ref: SignalRef, signal: Signal) {
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
        let turningOn = (sender.state == .on)
        switch node.kind {
        case .file:
            guard let key = hierarchyKey() else { return }
            state.setGateOpen(key, open: turningOn)
        case .interior:
            // Interior nodes that don't carry their own signal behave as
            // subckt gates. Interior nodes that DO carry a signal (the
            // v(x1) + v(x1.a) case) drive that signal's own visibility
            // just like a leaf.
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
