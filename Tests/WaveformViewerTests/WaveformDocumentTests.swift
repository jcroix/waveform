import Foundation
import Testing
@testable import WaveformViewer

// MARK: - loadTR0 on the real LFSR9 fixture

@Test func loadTR0BuildsSignalsAndHierarchy() throws {
    guard let url = Bundle.module.url(
        forResource: "lfsr9-flat",
        withExtension: "tr0",
        subdirectory: "Fixtures"
    ) else {
        Issue.record("Missing lfsr9-flat.tr0")
        return
    }

    let doc = try WaveformDocument.loadTR0(url: url)

    #expect(doc.title.contains("linear feedback shift register"))
    #expect(doc.analysisKind == .transient)
    #expect(doc.format == .tr0(.little))
    #expect(doc.hierarchySeparator == ".")

    // 4 signals, correct kinds based on display-name prefix.
    #expect(doc.signals.count == 4)
    #expect(doc.signals.map(\.displayName) == ["v(clk)", "v(setb)", "v(out)", "i(vdd)"])
    #expect(doc.signals.map(\.kind) == [.voltage, .voltage, .voltage, .current])
    #expect(doc.signals.map(\.unit) == ["V", "V", "V", "A"])

    // Hierarchy tree: a flat circuit → all 4 signals at root level.
    let root = doc.hierarchyRoot
    #expect(root.children.count == 4)
    for child in root.children {
        #expect(child.signalID != nil)
        #expect(child.children.isEmpty)
    }
    // Names are the inner (unwrapped) bare names: clk, setb, out, vdd.
    let childNames = Set(root.children.map(\.name))
    #expect(childNames == Set(["clk", "setb", "out", "vdd"]))

    // Round-trip: look up a signal through the document.
    let vClk = doc.signal(withID: 0)
    #expect(vClk?.displayName == "v(clk)")
    #expect(vClk?.values.first == 0.0)

    // Time values promoted to Double without precision loss at this scale.
    #expect(abs(doc.timeValues[0] - 3.5e-10) < 1e-12)
}

// MARK: - loadListing on the real LFSR9 .out (embedded waveforms)

@Test func loadListingWithEmbeddedWaveforms() throws {
    guard let url = Bundle.module.url(
        forResource: "lfsr9-flat",
        withExtension: "out",
        subdirectory: "Fixtures"
    ) else {
        Issue.record("Missing lfsr9-flat.out")
        return
    }

    let doc = try WaveformDocument.loadListing(url: url)

    #expect(doc.title == "linear feedback shift register random sequence generator")
    #expect(doc.format == .listing(outputFormat: "txt"))
    #expect(doc.analysisKind == .transient)
    #expect(doc.signals.count == 4)
    #expect(doc.signals.map(\.displayName) == ["v(clk)", "v(setb)", "v(out)", "i(vdd)"])
    #expect(doc.signals[3].kind == .current)
    #expect(doc.sampleCount > 25_000)
}

// MARK: - Auto-discovery of sibling .tr0 when listing is in tr0 mode

@Test func listingInTr0ModeAutoDiscoversSiblingBinary() throws {
    guard let realTR0 = Bundle.module.url(
        forResource: "lfsr9-flat",
        withExtension: "tr0",
        subdirectory: "Fixtures"
    ) else {
        Issue.record("Missing lfsr9-flat.tr0")
        return
    }

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("wv-sibling-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let basename = "autoload_run"
    let siblingTR0 = tmp.appendingPathComponent("\(basename).tr0")
    let listing = tmp.appendingPathComponent("\(basename).out")

    try FileManager.default.copyItem(at: realTR0, to: siblingTR0)

    // Synthetic listing in tr0 mode — no x/y block, but analyses and title declared.
    let listingText = """
    ################################################################################
    #                                   OmegaSim                                   #
    ################################################################################

    Title: sibling autoload smoke

    Option Settings:
    NASC_HIERID = "."
    NASC_OUTFORMAT = "tr0" (default: "TXT")

    DC analysis completed.
    Transient analysis completed at time 50ns.

    [info 1521] Simulation succeeded.
    """
    try listingText.write(to: listing, atomically: true, encoding: .utf8)

    let doc = try WaveformDocument.load(from: listing)

    // Entry-point URL should still be the listing, not the binary we actually read from.
    #expect(doc.sourceURL == listing)
    // But the format records where the waveforms really came from.
    if case .tr0 = doc.format {
        // ok — auto-loader substituted the TR0 as the source of samples
    } else {
        Issue.record("expected format == .tr0 after auto-discovery, got \(doc.format)")
    }
    // Title comes from the listing (more authoritative) not from the TR0 header.
    #expect(doc.title == "sibling autoload smoke")
    #expect(doc.signals.count == 4)
    #expect(doc.signals.map(\.displayName) == ["v(clk)", "v(setb)", "v(out)", "i(vdd)"])
    #expect(doc.sampleCount > 20_000)
}

@Test func listingInTr0ModeWithoutSiblingFails() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("wv-no-sibling-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let listing = tmp.appendingPathComponent("lonely.out")
    let text = """
    Title: lonely

    Option Settings:
    NASC_OUTFORMAT = "tr0"

    Transient analysis completed at time 50ns.

    [info 1521] Simulation succeeded.
    """
    try text.write(to: listing, atomically: true, encoding: .utf8)

    #expect(throws: ParseError.self) {
        _ = try WaveformDocument.load(from: listing)
    }
}

// MARK: - Extension dispatch

@Test func loadDispatchesOnExtension() throws {
    guard let tr0URL = Bundle.module.url(
        forResource: "lfsr9-flat",
        withExtension: "tr0",
        subdirectory: "Fixtures"
    ) else {
        Issue.record("Missing fixture")
        return
    }
    let doc = try WaveformDocument.load(from: tr0URL)
    if case .tr0 = doc.format {
        // ok
    } else {
        Issue.record("expected .tr0 format, got \(doc.format)")
    }
}

@Test func loadRejectsUnknownExtension() {
    let url = URL(fileURLWithPath: "/tmp/foo.bogus")
    #expect(throws: ParseError.self) {
        _ = try WaveformDocument.load(from: url)
    }
}
