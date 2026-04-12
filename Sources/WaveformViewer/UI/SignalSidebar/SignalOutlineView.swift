import AppKit
import SwiftUI

/// SwiftUI wrapper around an `NSOutlineView` displaying a hierarchical signal tree. Source
/// list styling gives it the native vibrant sidebar look; filtering rebuilds a subset of
/// the tree and reloads the outline view.
struct SignalOutlineView: NSViewRepresentable {
    let document: WaveformDocument
    let filterText: String
    @Binding var selectedSignalID: SignalID?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView(frame: .zero)
        outline.headerView = nil
        outline.allowsMultipleSelection = false
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
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

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

            let cell = NSTableCellView()

            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            cell.addSubview(image)
            cell.imageView = image

            let text = NSTextField(labelWithString: node.name)
            text.font = .systemFont(ofSize: NSFont.systemFontSize)
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text

            if let signalID = node.signalID,
               let signal = parent.document.signal(withID: signalID) {
                image.image = NSImage(
                    systemSymbolName: iconName(for: signal.kind),
                    accessibilityDescription: nil
                )
                image.contentTintColor = iconColor(for: signal.kind)
            } else {
                image.image = NSImage(
                    systemSymbolName: "folder",
                    accessibilityDescription: nil
                )
                image.contentTintColor = .secondaryLabelColor
            }

            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            ])

            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline = notification.object as? NSOutlineView else { return }
            let row = outline.selectedRow
            if row >= 0, let node = outline.item(atRow: row) as? HierarchyNode {
                parent.selectedSignalID = node.signalID
            } else {
                parent.selectedSignalID = nil
            }
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            // Placeholder for the Phase 9 "add to plot" flow. Until the plot panel exists
            // there is nothing to do with a double-click.
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

        private func iconColor(for kind: SignalKind) -> NSColor {
            switch kind {
            case .voltage:      return .systemYellow
            case .current:      return .systemBlue
            case .power:        return .systemOrange
            case .logicVoltage: return .systemPurple
            case .unknown:      return .secondaryLabelColor
            }
        }
    }
}
