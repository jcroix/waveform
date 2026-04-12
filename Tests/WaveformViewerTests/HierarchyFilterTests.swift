import Foundation
import Testing
@testable import WaveformViewer

private func makeSignal(id: SignalID, path: [String]) -> Signal {
    Signal(
        id: id,
        displayName: "v(\(path.joined(separator: ".")))",
        path: path,
        bareName: path.last ?? "",
        kind: .voltage,
        unit: "V",
        values: []
    )
}

private func makeTree() -> HierarchyNode {
    let signals = [
        makeSignal(id: 0, path: ["x1", "x2", "net1"]),
        makeSignal(id: 1, path: ["x1", "x2", "net2"]),
        makeSignal(id: 2, path: ["x1", "y", "probe"]),
        makeSignal(id: 3, path: ["z", "clock"]),
    ]
    return HierarchyNode.build(signals: signals, separator: ".")
}

@Test func emptyFilterReturnsOriginalTreeIdentity() {
    let tree = makeTree()
    let filtered = HierarchyNode.filter(tree, matching: "")
    // Empty filter is the identity; same reference should come back.
    #expect(filtered === tree)
}

@Test func filterKeepsMatchingLeafAndAncestors() {
    let tree = makeTree()
    let filtered = HierarchyNode.filter(tree, matching: "net1")
    #expect(filtered != nil)

    // Walk down: root -> x1 -> x2 -> net1 only. z and x1/y should be pruned.
    let root = filtered!
    #expect(root.children.count == 1)
    #expect(root.children[0].name == "x1")
    let x1 = root.children[0]
    #expect(x1.children.count == 1)
    #expect(x1.children[0].name == "x2")
    let x2 = x1.children[0]
    #expect(x2.children.count == 1)
    #expect(x2.children[0].name == "net1")
    #expect(x2.children[0].signalID == 0)
}

@Test func filterIsCaseInsensitive() {
    let tree = makeTree()
    let filtered = HierarchyNode.filter(tree, matching: "CLOCK")
    #expect(filtered != nil)
    // Only z/clock should remain.
    let names = filtered!.children.map(\.name)
    #expect(names == ["z"])
    #expect(filtered!.children[0].children.map(\.name) == ["clock"])
}

@Test func filterKeepsBranchWhenInteriorNodeMatches() {
    let tree = makeTree()
    // "x2" matches the interior node itself — the whole x2 subtree should come through.
    let filtered = HierarchyNode.filter(tree, matching: "x2")
    #expect(filtered != nil)
    let root = filtered!
    #expect(root.children.count == 1)
    let x1 = root.children[0]
    #expect(x1.children.map(\.name) == ["x2"])
    let x2 = x1.children[0]
    #expect(x2.children.map(\.name) == ["net1", "net2"])
}

@Test func filterReturnsNilWhenNothingMatches() {
    let tree = makeTree()
    let filtered = HierarchyNode.filter(tree, matching: "nonexistent_net")
    #expect(filtered == nil)
}
