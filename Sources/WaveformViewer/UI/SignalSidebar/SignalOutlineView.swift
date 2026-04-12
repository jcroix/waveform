import AppKit
import SwiftUI

/// SwiftUI wrapper around an `NSOutlineView` displaying a hierarchical signal tree.
/// Each leaf row carries: a checkbox bound to `ViewerState.visibleSignalIDs`, an icon
/// tinted with the signal's stable palette color, the signal name, and (when a cursor
/// is placed) the interpolated signal value at the cursor time, right-aligned.
///
/// `visibleSignalIDs` and `cursorTimeX` are threaded through as direct struct
/// properties so the outer `SignalSidebar` body reads them at construction time and
/// gets subscribed to them through the Observation framework. Without those reads,
/// menu commands and plot-driven cursor moves would mutate state but never trigger
/// `updateNSView` here.
struct SignalOutlineView: NSViewRepresentable {
    let document: WaveformDocument
    let filterText: String
    let visibleSignalIDs: [SignalID]
    let cursorTimeX: Double?
    @Bindable var state: ViewerState

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

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = outline

        coordinator.outlineView = outline
        coordinator.rebuild(document: document, filter: filterText)
        outline.reloadData()

        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let outline = context.coordinator.outlineView else { return }
        if context.coordinator.needsRebuild(document: document, filter: filterText) {
            context.coordinator.rebuild(document: document, filter: filterText)
            outline.reloadData()
        } else {
            // Neither the tree shape nor the filter changed — we just need to refresh
            // each visible cell so its checkbox and (cursor-dependent) value stay in
            // sync with the latest `state.visibleSignalIDs` and `state.cursorTimeX`.
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

        private var displayedRoot: HierarchyNode?
        private var lastDocumentID: ObjectIdentifier?
        private var lastFilter: String = ""

        init(parent: SignalOutlineView) {
            self.parent = parent
            super.init()
        }

        func needsRebuild(document: WaveformDocument, filter: String) -> Bool {
            if filter != lastFilter { return true }
            if lastDocumentID != ObjectIdentifier(document.hierarchyRoot) { return true }
            return false
        }

        func rebuild(document: WaveformDocument, filter: String) {
            lastFilter = filter
            lastDocumentID = ObjectIdentifier(document.hierarchyRoot)
            displayedRoot = HierarchyNode.filter(document.hierarchyRoot, matching: filter)
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            let node = (item as? HierarchyNode) ?? displayedRoot
            return node?.children.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let node = (item as? HierarchyNode) ?? displayedRoot!
            return node.children[index]
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
            let signal: Signal? = node.signalID.flatMap { parent.document.signal(withID: $0) }
            let cell = SignalCellView(
                node: node,
                signal: signal,
                state: parent.state,
                document: parent.document
            )
            return cell
        }
    }
}

// MARK: - Custom cell view

/// Row view for the signal outline. Layout:
///
///     [checkbox] [icon] [name]                 [value]
///
/// `value` is populated only when a cursor is placed in the plot and this row
/// corresponds to a real signal. Interior nodes (no `signalID`) get a folder glyph,
/// no checkbox, and no value field.
final class SignalCellView: NSTableCellView {
    private let node: HierarchyNode
    private let signal: Signal?
    private let state: ViewerState
    private let document: WaveformDocument

    private let checkbox = NSButton()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")

    init(
        node: HierarchyNode,
        signal: Signal?,
        state: ViewerState,
        document: WaveformDocument
    ) {
        self.node = node
        self.signal = signal
        self.state = state
        self.document = document
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
        nameField.stringValue = node.name

        if let signal = signal {
            checkbox.isHidden = false
            iconView.image = NSImage(
                systemSymbolName: iconName(for: signal.kind),
                accessibilityDescription: nil
            )
            iconView.contentTintColor = ColorPalette.stableColor(for: signal.id)
        } else {
            // Interior node: no checkbox, folder glyph.
            checkbox.isHidden = true
            valueField.isHidden = true
            iconView.image = NSImage(
                systemSymbolName: "folder",
                accessibilityDescription: nil
            )
            iconView.contentTintColor = .secondaryLabelColor
        }

        refreshDynamicContent()
    }

    /// Updates the checkbox (visibility) and value label (cursor readout) to reflect
    /// the latest state. Called from `SignalOutlineView.updateNSView` whenever
    /// visibleSignalIDs or cursorTimeX change without touching the tree shape.
    func refreshDynamicContent() {
        guard let signal = signal else { return }
        checkbox.state = state.isVisible(signal.id) ? .on : .off

        if let cursorTime = state.cursorTimeX,
           let value = signal.value(atTime: cursorTime, timeValues: document.timeValues) {
            valueField.stringValue = EngFormat.format(Double(value), unit: signal.unit)
            valueField.isHidden = false
        } else {
            valueField.stringValue = ""
            valueField.isHidden = true
        }
    }

    @objc private func handleCheckbox(_ sender: NSButton) {
        guard let signal = signal else { return }
        state.toggleVisibility(signal.id)
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

