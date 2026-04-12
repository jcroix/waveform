import Foundation

/// A node in the signal hierarchy tree displayed in the sidebar. Interior nodes have no
/// `signalID`; leaf nodes always do. An interior node can also carry its own signal when
/// a user probes a subcircuit instance as well as signals beneath it.
public final class HierarchyNode: @unchecked Sendable {
    public let name: String          // "" for the synthetic root
    public let fullPath: String      // "" for the synthetic root
    public let signalID: SignalID?   // nil for pure interior nodes
    public let children: [HierarchyNode]

    public init(
        name: String,
        fullPath: String,
        signalID: SignalID?,
        children: [HierarchyNode]
    ) {
        self.name = name
        self.fullPath = fullPath
        self.signalID = signalID
        self.children = children
    }

    public var isLeaf: Bool { children.isEmpty }
    public var carriesSignal: Bool { signalID != nil }

    /// Builds an immutable hierarchy tree from a flat list of signals. The tree's children
    /// at every level are sorted by name using Finder-style natural comparison so that
    /// `net2` comes before `net10`.
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

        func freeze(_ mutable: MutableNode) -> HierarchyNode {
            let sorted = mutable.children.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map(freeze)
            return HierarchyNode(
                name: mutable.name,
                fullPath: mutable.fullPath,
                signalID: mutable.signalID,
                children: sorted
            )
        }

        return freeze(root)
    }

    /// Walks the tree top-down and invokes `body` for every node (including the root).
    public func forEach(_ body: (HierarchyNode) -> Void) {
        body(self)
        for child in children {
            child.forEach(body)
        }
    }
}
