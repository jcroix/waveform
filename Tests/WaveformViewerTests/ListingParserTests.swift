import Foundation
import Testing
@testable import WaveformViewer

// MARK: - Real LFSR9 listing fixture (TXT mode, 4 probes including current)

@Test func lfsr9FlatListingParses() throws {
    guard let url = Bundle.module.url(
        forResource: "lfsr9-flat",
        withExtension: "out",
        subdirectory: "Fixtures"
    ) else {
        Issue.record("Missing fixture lfsr9-flat.out")
        return
    }
    let listing = try ListingParser.parse(url: url)

    #expect(listing.title == "linear feedback shift register random sequence generator")
    #expect(listing.hierarchySeparator == ".")
    #expect(listing.outputFormat == "txt")
    #expect(listing.succeeded)
    #expect(listing.hasEmbeddedWaveforms)

    // Both DC and Transient should have completed.
    #expect(listing.analyses.contains(AnalysisRecord(kind: .dc, endTime: nil)))
    #expect(listing.analyses.contains(AnalysisRecord(kind: .transient, endTime: "50ns")))

    // Exactly one waveform block.
    #expect(listing.waveformBlocks.count == 1)
    let block = listing.waveformBlocks[0]

    // The block is tagged as the most recently seen analysis (transient).
    #expect(block.analysisKind == .transient)

    #expect(block.columnNames == ["Time", "v(clk)", "v(setb)", "v(out)", "i(vdd)"])
    #expect(block.columnUnits == ["s", "V", "V", "V", "A"])
    #expect(block.probes.count == 4)
    #expect(block.probes.map(\.name) == ["v(clk)", "v(setb)", "v(out)", "i(vdd)"])
    #expect(block.probes.map(\.unit) == ["V", "V", "V", "A"])
    #expect(block.probes.map(\.kind) == [.voltage, .voltage, .voltage, .current])

    // ~26619 data rows.
    #expect(block.timeValues.count > 25_000)
    #expect(block.timeValues.count < 30_000)
    for probe in block.probes {
        #expect(probe.values.count == block.timeValues.count)
    }

    // First sample line: 3.50000e-10  0.0000e+00  1.3000e+00  1.2998e+00  -2.4356e-04
    #expect(abs(block.timeValues[0] - 3.5e-10) < 1e-12)
    #expect(block.probes[0].values[0] == 0.0)
    #expect(abs(block.probes[1].values[0] - 1.3) < 1e-4)
    #expect(abs(block.probes[2].values[0] - 1.2998) < 1e-4)
    #expect(abs(block.probes[3].values[0] - (-2.4356e-04)) < 1e-7)

    // Last sample line should be at t = 5.00000e-08.
    #expect(abs(block.timeValues.last! - 5.0e-8) < 1e-11)
}

// MARK: - Cross-validation against TR0 parser

@Test func lfsr9ListingMatchesTR0() throws {
    guard let outURL = Bundle.module.url(
        forResource: "lfsr9-flat",
        withExtension: "out",
        subdirectory: "Fixtures"
    ),
    let trURL = Bundle.module.url(
        forResource: "lfsr9-flat",
        withExtension: "tr0",
        subdirectory: "Fixtures"
    ) else {
        Issue.record("Missing fixture")
        return
    }

    let listing = try ListingParser.parse(url: outURL)
    let tr0 = try TR0Parser.parse(url: trURL)

    let block = listing.waveformBlocks[0]

    // Same probe set in the same order.
    #expect(block.probes.map(\.name) == tr0.probes.map(\.name))
    // Sample counts should match exactly (same simulation, deterministic output).
    #expect(block.timeValues.count == tr0.timeValues.count)

    // Spot-check a handful of samples for value agreement within scientific-notation precision.
    let n = min(block.timeValues.count, tr0.timeValues.count)
    let spotIndices = [0, n / 4, n / 2, 3 * n / 4, n - 1]
    for idx in spotIndices {
        let listingT = block.timeValues[idx]
        let tr0T = tr0.timeValues[idx]
        #expect(abs(listingT - tr0T) < max(1e-12, 1e-4 * abs(tr0T)))

        for probeIndex in 0..<min(block.probes.count, tr0.probes.count) {
            let lv = block.probes[probeIndex].values[idx]
            let tv = tr0.probes[probeIndex].values[idx]
            // Listing has 4-digit precision; allow 1e-3 relative or 1e-6 absolute, whichever larger.
            let tol = max(1e-6, 1e-3 * abs(tv))
            #expect(abs(lv - tv) < tol,
                    "probe \(probeIndex) (\(block.probes[probeIndex].name)) mismatch at index \(idx): listing=\(lv), tr0=\(tv)")
        }
    }
}

// MARK: - Synthetic minimal listing (state machine coverage)

@Test func minimalSyntheticListing() throws {
    let text = """
    ##############
    #  OmegaSim  #
    ##############

    [info 1004] Time: now
    [info 1015] Hostname: x

    Title: tiny test

    Element Counts:
    Resistor Count = 1

    Option Settings:
    NASC_HIERID = ":"
    NASC_OUTFORMAT = "TXT"

    DC analysis completed.
    Transient analysis completed at time 10ns.

    x
    Time         v(a)         i(b)
    s            V            A
    0.0000e+00   0.0000e+00   1.0000e-03
    5.0000e-09   1.2500e+00  -2.5000e-04
    1.0000e-08   2.5000e+00   5.0000e-04
    y

    [info 1521] Simulation succeeded.
    """

    let listing = try ListingParser.parse(text: text)
    #expect(listing.title == "tiny test")
    #expect(listing.hierarchySeparator == ":")
    #expect(listing.outputFormat == "TXT")
    #expect(listing.succeeded)
    #expect(listing.analyses.count == 2)
    #expect(listing.analyses[0].kind == .dc)
    #expect(listing.analyses[1].kind == .transient)
    #expect(listing.analyses[1].endTime == "10ns")

    #expect(listing.waveformBlocks.count == 1)
    let block = listing.waveformBlocks[0]
    #expect(block.analysisKind == .transient)
    #expect(block.probes.map(\.name) == ["v(a)", "i(b)"])
    #expect(block.probes.map(\.kind) == [.voltage, .current])
    #expect(block.timeValues == [0.0, 5e-9, 1e-8])
    #expect(block.probes[0].values == [0.0, 1.25, 2.5])
    #expect(block.probes[1].values == [1e-3, -2.5e-4, 5e-4])
}

// MARK: - Listings that have no embedded waveforms (NASC_OUTFORMAT = "tr0")

@Test func listingWithoutEmbeddedWaveforms() throws {
    let text = """
    Title: bare listing

    Option Settings:
    NASC_HIERID = "."
    NASC_OUTFORMAT = "tr0" (default: "TXT")

    DC analysis completed.
    Transient analysis completed at time 50ns.

    [info 1521] Simulation succeeded.
    """
    let listing = try ListingParser.parse(text: text)
    #expect(listing.outputFormat == "tr0")
    #expect(!listing.hasEmbeddedWaveforms)
    #expect(listing.waveformBlocks.isEmpty)
    #expect(listing.succeeded)
    #expect(listing.analyses.count == 2)
}

// MARK: - Option extractor edge cases

@Test func optionParserHandlesQuotedValuesAndDefaults() throws {
    let text = """
    Title: opt test

    Option Settings:
    BARE = 42
    QUOTED = "hello"
    QUOTED_WITH_DEFAULT = "txt" (default: "TXT")
    EMPTY = ""

    [info 1521] Simulation succeeded.
    """
    // We can't directly inspect the options dictionary (parser only surfaces NASC_HIERID and
    // NASC_OUTFORMAT), but we can at least verify the parser doesn't choke on the extra keys.
    let listing = try ListingParser.parse(text: text)
    #expect(listing.title == "opt test")
    #expect(listing.succeeded)
}

// MARK: - Truncated block is rejected

@Test func truncatedBlockRejected() throws {
    let text = """
    Title: bad

    x
    Time     v(a)
    s        V
    0.0000   1.0000
    """
    #expect(throws: ParseError.self) {
        _ = try ListingParser.parse(text: text)
    }
}
