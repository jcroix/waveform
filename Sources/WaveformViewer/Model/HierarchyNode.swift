import Foundation

/// A node in the signal hierarchy tree displayed in the sidebar.
///
/// Multi-file mode (Phase 15) introduced a `Kind` enum so file-level containers,
/// subckt interiors, and signal leaves all flow through one type. The sidebar's
/// top-level items are `.file(DocumentID)` nodes whose `children` are the root's
/// direct subtrees for that loaded document. Inside a document the structure is
/// unchanged from the single-file era: interior nodes have `kind == .interior`
/// and no `signalID`; leaf nodes have `kind == .leaf` and always do. An interior
/// node can also carry its own signal when a user probes a subcircuit instance
/// as well as signals beneath it (e.g. both `v(x1)` and `v(x1.a)` probed).
public final class HierarchyNode: @unchecked Sendable {
    public enum Kind: Sendable {
        /// Top-level node representing an entire loaded file. Its `fullPath` is
        /// always the empty string; its `children` are the per-document tree
        /// produced by `HierarchyNode.build(signals:separator:)`. Never carries
        /// a `signalID`.
        case file(DocumentID)
        /// Intermediate node along a signal's hierarchical path. May carry a
        /// `signalID` in the rare case where a probe exists on the subckt
        /// instance itself (not just leaves under it).
        case interior
        /// Terminal signal probe. Always carries a `signalID`.
        case leaf
    }

    public let kind: Kind
    public let name: String          // "" for the synthetic root / file-kind placeholder
    public let fullPath: String      // "" for the synthetic root or any file-kind node
    public let signalID: SignalID?   // nil for pure interior and all file nodes
    public let children: [HierarchyNode]

    public init(
        kind: Kind,
        name: String,
        fullPath: String,
        signalID: SignalID?,
        children: [HierarchyNode]
    ) {
        self.kind = kind
        self.name = name
        self.fullPath = fullPath
        self.signalID = signalID
        self.children = children
    }

    public var isLeaf: Bool { children.isEmpty }
    public var carriesSignal: Bool { signalID != nil }

    /// Returns the `DocumentID` when this node is a file-kind container; nil
    /// otherwise. Used by the sidebar's right-click "Close File" command and
    /// by the effective-visibility gate walk to identify the file a child
    /// belongs to.
    public var documentID: DocumentID? {
        if case .file(let id) = kind { return id }
        return nil
    }

    /// Builds an immutable hierarchy tree from a flat list of signals. The tree's children
    /// at every level are sorted by name using Finder-style natural comparison so that
    /// `net2` comes before `net10`.
    ///
    /// The returned root is a synthetic `.interior` node with `name == ""`. Callers that
    /// want a forest entry for a full file should wrap it with
    /// `HierarchyNode.fileContainer(for:documentID:name:)` instead of exposing the
    /// synthetic root directly.
    public static func build(signals: [Signal], separator: String) -> HierarchyNode {
        let sep = separator.isEmpty ? "." : separator

        final class MutableNode {
            let name: String
            let fullPath: String
            var signalID: SignalID?
            var children: [String: MutableNode] = [:]
            init(name: String, fullPath: String, signalID: SignalID? = nil) {
                self.name = name
                self.fullPath = fullPath
                self.signalID = signalID
            }
        }

        let root = MutableNode(name: "", fullPath: "")

        for signal in signals {
            var current = root
            var running: [String] = []
            for (index, component) in signal.path.enumerated() {
                running.append(component)
                let full = running.joined(separator: sep)
                let next: MutableNode
                if let existing = current.children[component] {
                    next = existing
                } else {
                    let created = MutableNode(name: component, fullPath: full)
                    current.children[component] = created
                    next = created
                }
                if index == signal.path.count - 1 {
                    next.signalID = signal.id
                }
                current = next
            }
        }

        func freeze(_ mutable: MutableNode, kind: Kind) -> HierarchyNode {
            let sorted = mutable.children.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { freeze($0, kind: $0.children.isEmpty ? .leaf : .interior) }
            return HierarchyNode(
                kind: kind,
                name: mutable.name,
                fullPath: mutable.fullPath,
                signalID: mutable.signalID,
                children: sorted
            )
        }

        return freeze(root, kind: .interior)
    }

    /// Wraps an already-built per-document tree under a file-kind root node.
    /// The file node itself carries no `signalID`; its `children` are the
    /// synthetic root's children, flattened into the file row. `name` is the
    /// user-visible label for the row (typically the document's basename or
    /// its title).
    public static func fileContainer(
        wrapping root: HierarchyNode,
        documentID: DocumentID,
        name: String
    ) -> HierarchyNode {
        HierarchyNode(
            kind: .file(documentID),
            name: name,
            fullPath: "",
            signalID: nil,
            children: root.children
        )
    }

    /// Walks the tree top-down and invokes `body` for every node (including the root).
    public func forEach(_ body: (HierarchyNode) -> Void) {
        body(self)
        for child in children {
            child.forEach(body)
        }
    }

    /// Returns a filtered copy of the subtree rooted at `node`, keeping only nodes whose
    /// `name` or `fullPath` contains the needle (case-insensitive) or which have any
    /// descendant that does. Returns `nil` if nothing in the subtree matches. An empty
    /// needle returns `node` unchanged (identity is preserved for the no-op case).
    ///
    /// File-kind nodes stay whenever any of their descendants match — matching purely
    /// against the file's own `name` is possible (the basename is text-searchable), but
    /// the common case is a filter against a signal name, and users expect their file
    /// to stay in the forest as long as something under it still matches.
    public static func filter(_ node: HierarchyNode, matching needle: String) -> HierarchyNode? {
        if needle.isEmpty { return node }
        let lower = needle.lowercased()

        func walk(_ n: HierarchyNode) -> HierarchyNode? {
            let selfMatches: Bool
            switch n.kind {
            case .file:
                // File nodes survive via their descendants, not their display name.
                // Users searching for a signal expect the file row to remain as an
                // anchor even if the filter needle doesn't appear in the basename.
                selfMatches = false
            case .interior, .leaf:
                selfMatches = n.name.lowercased().contains(lower)
                    || n.fullPath.lowercased().contains(lower)
            }
            let keptChildren = n.children.compactMap(walk)
            if selfMatches || !keptChildren.isEmpty {
                return HierarchyNode(
                    kind: n.kind,
                    name: n.name,
                    fullPath: n.fullPath,
                    signalID: n.signalID,
                    children: keptChildren
                )
            }
            return nil
        }
        return walk(node)
    }

}
