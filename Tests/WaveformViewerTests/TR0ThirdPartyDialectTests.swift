import Foundation
import Testing
@testable import WaveformViewer

// Regression tests that exercise the TR0 parser against the segregated
// `third-party-tr0-samples/` directory at the repo root. These files are
// NOT Nascentric-produced — they come from the gwave and HMC-ACE public
// repositories and represent the "real HSPICE" dialect (nauto includes
// TIME, end-of-table signaled by a time value ≥ 1e29).
//
// The purpose of these tests is to guard against dialect-handling
// regressions in `TR0Parser`, not to validate specific sample values.
// If any of them break, read `TR0Format.md` for a description of what
// the parser is supposed to accept.

private func thirdPartySampleURL(_ path: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // WaveformViewerTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("third-party-tr0-samples")
        .appendingPathComponent(path)
}

// MARK: - gwave samples (big-endian, real HSPICE dialect)

@Test func gwaveQuickINVDecodes() throws {
    let doc = try TR0Parser.parse(url: thirdPartySampleURL("gwave/quickINV.tr0"))
    #expect(doc.byteOrder == .big)
    #expect(doc.probes.count == 8)
    #expect(doc.title == "inverter circuit")
    #expect(doc.probes.map(\.name) == [
        "0", "in", "out", "vcc", "I(vcc)", "I(vin)", "v(in)", "v(out)"
    ])
    // Type codes: 1 for voltages, 8 for currents.
    #expect(doc.probes.first(where: { $0.name == "I(vcc)" })?.typeCode == 8)
    #expect(doc.probes.first(where: { $0.name == "v(in)"  })?.typeCode == 1)
    // Every probe has one value per time sample.
    for probe in doc.probes {
        #expect(probe.values.count == doc.timeValues.count)
    }
}

@Test func gwaveQuickTRANDecodes() throws {
    let doc = try TR0Parser.parse(url: thirdPartySampleURL("gwave/quickTRAN.tr0"))
    #expect(doc.byteOrder == .big)
    #expect(doc.probes.count == 8)
    // nauto=5 includes TIME, nprobe=4 → totalIds = 9 → 8 probes.
    for probe in doc.probes {
        #expect(probe.values.count == doc.timeValues.count)
    }
}

@Test func gwaveTest1DecodesTinyFile() throws {
    let doc = try TR0Parser.parse(url: thirdPartySampleURL("gwave/test1.tr0.binary"))
    #expect(doc.byteOrder == .big)
    #expect(doc.probes.map(\.name) == ["v(a)", "v(b)", "i1(r1)"])
    // Type code 15 = current in some HSPICE dialects; parser keeps it raw.
    #expect(doc.probes.first(where: { $0.name == "i1(r1)" })?.typeCode == 15)
}

// MARK: - HMC-ACE samples (little-endian, real HSPICE dialect)

@Test func hmcAceTest9601Decodes() throws {
    let doc = try TR0Parser.parse(url: thirdPartySampleURL("hmc-ace/test_9601.tr0"))
    #expect(doc.byteOrder == .little)
    #expect(doc.probes.count == 4)
    #expect(doc.probes.map(\.name) == ["v(0)", "v(vo)", "v(vs)", "i(vs)"])
    // 3 voltages + 1 current.
    #expect(doc.probes.filter({ $0.typeCode == 1 }).count == 3)
    #expect(doc.probes.filter({ $0.typeCode == 8 }).count == 1)
    for probe in doc.probes {
        #expect(probe.values.count == doc.timeValues.count)
    }
}

@Test func hmcAceTest2001Decodes() throws {
    // Same dialect as 9601 but with the 8-digit "00002001" version tag.
    let doc = try TR0Parser.parse(url: thirdPartySampleURL("hmc-ace/test_2001.tr0"))
    #expect(doc.byteOrder == .little)
    #expect(doc.probes.count == 4)
    #expect(doc.probes.map(\.name) == ["v(0)", "v(vo)", "v(vs)", "i(vs)"])
    for probe in doc.probes {
        #expect(probe.values.count == doc.timeValues.count)
    }
}
