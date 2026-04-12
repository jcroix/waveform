import Foundation
import Testing
@testable import WaveformViewer

// MARK: - parseSignalName

@Test func parseVoltageName() {
    let (path, bare) = parseSignalName(displayName: "v(x1.x2.net3)", separator: ".")
    #expect(path == ["x1", "x2", "net3"])
    #expect(bare == "net3")
}

@Test func parseCurrentName() {
    let (path, bare) = parseSignalName(displayName: "i(vdd)", separator: ".")
    #expect(path == ["vdd"])
    #expect(bare == "vdd")
}

@Test func parseNameWithoutWrapper() {
    let (path, bare) = parseSignalName(displayName: "net_local", separator: ".")
    #expect(path == ["net_local"])
    #expect(bare == "net_local")
}

@Test func parseNameWithNonDotSeparator() {
    let (path, bare) = parseSignalName(displayName: "v(x1:x2:sig)", separator: ":")
    #expect(path == ["x1", "x2", "sig"])
    #expect(bare == "sig")
}

@Test func parseNameDropsEmptyComponents() {
    let (path, bare) = parseSignalName(displayName: "v(x1..net)", separator: ".")
    #expect(path == ["x1", "net"])
    #expect(bare == "net")
}

// MARK: - HierarchyNode.build

private func makeSignal(id: SignalID, displayName: String, path: [String]) -> Signal {
    Signal(
        id: id,
        displayName: displayName,
        path: path,
        bareName: path.last ?? displayName,
        kind: .voltage,
        unit: "V",
        values: []
    )
}

@Test func flatSignalsProduceRootLevelChildren() {
    let signals = [
        makeSignal(id: 0, displayName: "v(a)", path: ["a"]),
        makeSignal(id: 1, displayName: "v(b)", path: ["b"]),
        makeSignal(id: 2, displayName: "v(c)", path: ["c"]),
    ]
    let root = HierarchyNode.build(signals: signals, separator: ".")
    #expect(root.name == "")
    #expect(root.children.count == 3)
    #expect(root.children.map(\.name) == ["a", "b", "c"])
    for child in root.children {
        #expect(child.signalID != nil)
        #expect(child.children.isEmpty)
    }
}

@Test func hierarchicalSignalsBuildNestedTree() {
    let signals = [
        makeSignal(id: 0, displayName: "v(x1.x2.net)", path: ["x1", "x2", "net"]),
        makeSignal(id: 1, displayName: "v(x1.x2.m1)",  path: ["x1", "x2", "m1"]),
        makeSignal(id: 2, displayName: "v(x1.y)",      path: ["x1", "y"]),
        makeSignal(id: 3, displayName: "v(z)",         path: ["z"]),
    ]
    let root = HierarchyNode.build(signals: signals, separator: ".")
    #expect(root.children.map(\.name) == ["x1", "z"])

    let x1 = root.children.first { $0.name == "x1" }!
    #expect(x1.signalID == nil)
    #expect(x1.children.map(\.name) == ["x2", "y"])  // x2 before y alphabetically

    let x2 = x1.children.first { $0.name == "x2" }!
    #expect(x2.signalID == nil)
    // m1 before net by localized standard compare
    #expect(x2.children.map(\.name) == ["m1", "net"])
    #expect(x2.children[0].signalID == 1)
    #expect(x2.children[1].signalID == 0)

    let y = x1.children.first { $0.name == "y" }!
    #expect(y.signalID == 2)
    #expect(y.children.isEmpty)

    let z = root.children.first { $0.name == "z" }!
    #expect(z.signalID == 3)
    #expect(z.children.isEmpty)
}

@Test func interiorNodeCanCarrySignal() {
    // When both v(x1) and v(x1.a) are probed, x1 is both an interior node (has children)
    // and a leaf (has its own signalID).
    let signals = [
        makeSignal(id: 0, displayName: "v(x1)",   path: ["x1"]),
        makeSignal(id: 1, displayName: "v(x1.a)", path: ["x1", "a"]),
    ]
    let root = HierarchyNode.build(signals: signals, separator: ".")
    let x1 = root.children[0]
    #expect(x1.name == "x1")
    #expect(x1.signalID == 0)        // carries its own signal
    #expect(x1.children.count == 1)  // AND has a child
    #expect(x1.children[0].signalID == 1)
}

@Test func naturalSortPutsNet2BeforeNet10() {
    let signals = [
        makeSignal(id: 0, displayName: "v(net10)", path: ["net10"]),
        makeSignal(id: 1, displayName: "v(net2)",  path: ["net2"]),
        makeSignal(id: 2, displayName: "v(net1)",  path: ["net1"]),
    ]
    let root = HierarchyNode.build(signals: signals, separator: ".")
    #expect(root.children.map(\.name) == ["net1", "net2", "net10"])
}
