import Foundation
import Testing
@testable import WaveformViewer

// MARK: - Fixture access

private func fixtureData(named name: String, ext: String) throws -> Data {
    guard let url = Bundle.module.url(
        forResource: name,
        withExtension: ext,
        subdirectory: "Fixtures"
    ) else {
        Issue.record("Missing fixture \(name).\(ext)")
        throw CocoaError(.fileReadNoSuchFile)
    }
    return try Data(contentsOf: url)
}

// MARK: - Real LFSR9 fixture (little-endian, 3 voltage probes + 1 current probe)

@Test func lfsr9FlatFixtureParses() throws {
    let data = try fixtureData(named: "lfsr9-flat", ext: "tr0")
    let doc = try TR0Parser.parse(data: data)

    #expect(doc.byteOrder == .little)
    #expect(doc.title.contains("linear feedback shift register"))
    #expect(doc.date == "04/12/2026")
    #expect(doc.probes.count == 4)
    #expect(doc.probes.map(\.name) == ["v(clk)", "v(setb)", "v(out)", "i(vdd)"])

    // First three are voltages (typeCode 1); i(vdd) is a current (typeCode 8).
    #expect(doc.probes[0].typeCode == 1)
    #expect(doc.probes[1].typeCode == 1)
    #expect(doc.probes[2].typeCode == 1)
    #expect(doc.probes[3].typeCode == 8)

    // Every probe has one value per time point.
    for probe in doc.probes {
        #expect(probe.values.count == doc.timeValues.count)
    }

    // First time sample should be ~3.5e-10 s.
    #expect(doc.timeValues[0] > 3.4e-10)
    #expect(doc.timeValues[0] < 3.6e-10)

    // First sample: v(clk) low, v(setb) and v(out) at NASC_VHIGH=1.3 V.
    #expect(doc.probes[0].values[0] == 0.0)
    #expect(abs(doc.probes[1].values[0] - 1.3) < 0.01)
    #expect(abs(doc.probes[2].values[0] - 1.3) < 0.01)

    // i(vdd) should be a small (sub-milliamp) current, sign-checked rather than
    // value-checked since the exact static current depends on the model.
    let iVdd0 = doc.probes[3].values[0]
    #expect(abs(iVdd0) < 1e-2)
    #expect(iVdd0 != 0.0)
}

// MARK: - Rejects non-TR0 data

@Test func garbageRejected() throws {
    let garbage = Data(repeating: 0xff, count: 64)
    #expect(throws: ParseError.self) {
        _ = try TR0Parser.parse(data: garbage)
    }
}

@Test func tooShortRejected() throws {
    let tiny = Data(repeating: 0x00, count: 8)
    do {
        _ = try TR0Parser.parse(data: tiny)
        Issue.record("Expected parse to throw on 8-byte input")
    } catch ParseError.notTR0 {
        // expected
    }
}

// MARK: - Byte-order round-trip

// Build a minimal TR0 file from scratch with configurable byte order. Used to prove the
// auto-detect path works end-to-end for both little- and big-endian files, without requiring
// a hand-crafted big-endian fixture from OmegaSim (which currently only emits native-endian).
@Test(arguments: [ByteOrder.little, ByteOrder.big])
func syntheticRoundTrip(order: ByteOrder) throws {
    let data = SyntheticTR0.build(byteOrder: order)
    let doc = try TR0Parser.parse(data: data)

    #expect(doc.byteOrder == order)
    #expect(doc.title == "synthetic round trip")
    #expect(doc.probes.count == 2)
    #expect(doc.probes[0].name == "v(a)")
    #expect(doc.probes[0].typeCode == 1)
    #expect(doc.probes[1].name == "i(r1)")
    #expect(doc.probes[1].typeCode == 8)

    #expect(doc.timeValues == [0.0, 1e-9, 2e-9])
    #expect(doc.probes[0].values == [0.0, 0.5, 1.0])
    #expect(doc.probes[1].values == [0.0, -0.25, -0.5])
}

// MARK: - Synthetic TR0 builder (test only)

private enum SyntheticTR0 {
    static func build(byteOrder: ByteOrder) -> Data {
        var out = Data()

        func writeInt32(_ value: Int32) {
            let raw = UInt32(bitPattern: value)
            let bytes: [UInt8] = [
                UInt8(raw & 0xff),
                UInt8((raw >> 8) & 0xff),
                UInt8((raw >> 16) & 0xff),
                UInt8((raw >> 24) & 0xff),
            ]
            switch byteOrder {
            case .little: out.append(contentsOf: bytes)
            case .big:    out.append(contentsOf: bytes.reversed())
            }
        }

        func writeFloat32(_ value: Float) {
            writeInt32(Int32(bitPattern: value.bitPattern))
        }

        func writeAscii(_ text: String, width: Int) {
            var bytes = Array(text.utf8)
            if bytes.count > width { bytes = Array(bytes.prefix(width)) }
            while bytes.count < width { bytes.append(0x20) }
            out.append(contentsOf: bytes)
        }

        func patchInt32(at offset: Int, value: Int32) {
            let raw = UInt32(bitPattern: value)
            let bytes: [UInt8] = [
                UInt8(raw & 0xff),
                UInt8((raw >> 8) & 0xff),
                UInt8((raw >> 16) & 0xff),
                UInt8((raw >> 24) & 0xff),
            ]
            let ordered: [UInt8]
            switch byteOrder {
            case .little: ordered = bytes
            case .big:    ordered = bytes.reversed()
            }
            for (index, byte) in ordered.enumerated() {
                out[offset + index] = byte
            }
        }

        // ── File header block ──────────────────────────────────────────────
        let headerStart = out.count
        writeInt32(4)      // mI0
        writeInt32(0)      // item count placeholder
        writeInt32(4)      // mI1
        writeInt32(0)      // adjusted size placeholder
        let payloadStart = out.count

        // Run info
        writeAscii("   2", width: 4)    // nodeCount = 2
        writeAscii("   1", width: 4)    // probeCount
        writeAscii("   0", width: 4)    // sweepCount
        writeAscii("   0", width: 4)    // reserved
        writeAscii("9601", width: 8)
        writeAscii("synthetic round trip", width: 64)
        writeAscii("04/12/2026", width: 16)
        writeAscii("00:00:00", width: 8)
        writeAscii("(C) Copyright Nascentric, Inc.", width: 72)

        // Sweep info: 4B + 19 × 4B
        writeAscii("   0", width: 4)
        for _ in 0..<19 {
            writeAscii("", width: 4)
        }

        // Waveform IDs: time + 2 probes
        writeAscii("  1     ", width: 8)   // time
        writeAscii("  1     ", width: 8)   // v(a) — voltage
        writeAscii("  8     ", width: 8)   // i(r1) — current

        // Waveform names (each 16-byte aligned; names ≤15 chars fit in 16B)
        writeAscii("time", width: 16)
        writeAscii("v(a)", width: 16)
        writeAscii("i(r1)", width: 16)

        // Trailer
        writeAscii("$&%#    ", width: 8)

        // Patch header's adjustedSize field (offset headerStart + 12, little-endian-safe via patchInt32)
        let payloadSize = Int32(out.count - payloadStart)
        patchInt32(at: headerStart + 12, value: payloadSize)

        // File-header checksum (4B) = adjusted size
        writeInt32(payloadSize)

        // ── Data block ─────────────────────────────────────────────────────
        // 3 samples × 3 floats (time + 2 probes) = 9 floats = 36 B.
        // Plus 4 B terminator ⇒ adjustedSize = 40.
        let dataHeaderStart = out.count
        writeInt32(4)
        writeInt32(0)       // item count
        writeInt32(4)
        writeInt32(40)      // adjusted size

        // Samples
        let times: [Float] = [0.0, 1e-9, 2e-9]
        let v_a: [Float] = [0.0, 0.5, 1.0]
        let i_r1: [Float] = [0.0, -0.25, -0.5]
        for (index, t) in times.enumerated() {
            writeFloat32(t)
            writeFloat32(v_a[index])
            writeFloat32(i_r1[index])
        }

        // Data-block terminator (raw bytes; NOT byte-swapped — writer emits literally)
        out.append(contentsOf: [0xca, 0xf2, 0x49, 0x71])

        // Sub-block checksum
        writeInt32(40)

        _ = dataHeaderStart  // silence unused-variable warning
        return out
    }
}
