import Foundation

public struct TR0Document: Sendable, Equatable {
    public let title: String
    public let date: String
    public let time: String
    public let byteOrder: ByteOrder
    public let timeValues: [Float]
    public let probes: [TR0Probe]
}

public struct TR0Probe: Sendable, Equatable {
    public let name: String      // as stored in file (lowercased by writer)
    public let typeCode: Int     // 1 = V / LogicV, 8 = I / Power
    public let values: [Float]   // length == TR0Document.timeValues.count
}

public enum TR0Parser {
    private static let dataBlockTerminator: [UInt8] = [0xca, 0xf2, 0x49, 0x71]

    public static func parse(url: URL) throws -> TR0Document {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> TR0Document {
        let byteOrder = try detectByteOrder(data: data)
        var reader = BinaryReader(data: data, byteOrder: byteOrder)

        // ─── Header block ───────────────────────────────────────────────────
        let headerPayloadSize = try readBlockHeader(&reader, kind: .fileHeader)
        let headerPayloadStart = reader.offset

        // The first two count fields are `nauto` and `nprobe` in gwave's
        // terminology. Total waveform-ID slots = nauto + nprobe. Nascentric
        // writes `probes.size()` as nauto and literal `1` as nprobe, which
        // yields `probes.size() + 1` — still correct under this formula.
        let nauto = try readAsciiIntField(&reader, field: "nauto")
        let nprobe = try readAsciiIntField(&reader, field: "nprobe")
        _ = try readAsciiIntField(&reader, field: "sweepCount")
        _ = try reader.readRawASCII(4)   // reserved
        _ = try reader.readRawASCII(8)   // "9601    " / "00002001" / etc.
        let title = try reader.readASCIIField(64)
        let date = try reader.readASCIIField(16)
        let time = try reader.readASCIIField(8)
        _ = try reader.readRawASCII(72)  // copyright

        // Sweep info: 4B count + 19 × 4B padding = 80B
        _ = try reader.readRawASCII(80)

        // Waveform IDs: totalIds × 8B, first is the time column. `probeCount`
        // is the number of non-time signals that the rest of the parser
        // tracks.
        let totalIds = nauto + nprobe
        guard totalIds >= 1 else {
            throw ParseError.invalidHeader(
                reason: "nauto+nprobe = \(nauto)+\(nprobe) must include at least the time slot"
            )
        }
        let probeCount = totalIds - 1
        var typeCodes: [Int] = []
        typeCodes.reserveCapacity(probeCount)
        for index in 0..<totalIds {
            let raw = try reader.readRawASCII(8)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let code = Int(trimmed) else {
                throw ParseError.badWaveformId(offset: reader.offset - 8, raw: raw)
            }
            if index > 0 {
                typeCodes.append(code)
            }
        }

        // Waveform names region: headerPayloadSize minus everything consumed so far minus the 8B trailer
        let consumedSoFar = reader.offset - headerPayloadStart
        let nameRegionSize = headerPayloadSize - consumedSoFar - 8
        guard nameRegionSize >= 0, nameRegionSize % 16 == 0 else {
            throw ParseError.invalidHeader(reason: "bad name region size \(nameRegionSize)")
        }

        let nameBlob = try reader.readBytes(nameRegionSize)
        let allNames = try parseWaveformNames(blob: nameBlob, expectedCount: totalIds)
        let probeNames = allNames.dropFirst().map(normalizeProbeName)

        // Trailer: 8B "$&%#    "
        let trailer = try reader.readRawASCII(8)
        guard trailer == "$&%#    " else {
            throw ParseError.invalidHeader(reason: "bad trailer '\(trailer)'")
        }

        // File-header checksum (4B). Not validated — writer records adjusted size, not a real hash.
        _ = try reader.readUInt32()

        // ─── Data blocks ────────────────────────────────────────────────────
        let valuesPerSample = totalIds
        let estimatedSamples = max(16, reader.remaining / (valuesPerSample * 4))
        var timeValues: [Float] = []
        timeValues.reserveCapacity(estimatedSamples)
        var probeValues: [[Float]] = Array(repeating: [], count: probeCount)
        for idx in 0..<probeCount {
            probeValues[idx].reserveCapacity(estimatedSamples)
        }

        var tupleIndex = 0  // 0 = time, 1..probeCount = probe (tupleIndex - 1)
        var sawTerminator = false

        while !sawTerminator, reader.remaining >= 16 {
            let payloadSize = try readBlockHeader(&reader, kind: .subBlock)
            guard payloadSize >= 0, reader.remaining >= payloadSize else {
                throw ParseError.truncatedDataBlock(offset: reader.offset)
            }

            // Two end-of-data markers to recognize:
            //
            // 1. Nascentric's custom sentinel `0xca f2 49 71` in the last 4
            //    bytes of the final sub-block's payload, with EOF exactly
            //    4 bytes (the block checksum) past the sentinel.
            // 2. Real HSPICE files (the gwave and HMC-ACE dialects) use the
            //    HSPICE-canonical in-band marker: a time value of ~1e31 at
            //    the start of a row signals end-of-table. The rest of that
            //    row's floats are undefined and must be discarded.
            var floatsByteCount = payloadSize
            var nascentricTailSentinel = false
            if payloadSize >= 4 {
                let tailOffset = reader.offset + payloadSize - 4
                let tail = try reader.peekBytes(4, at: tailOffset)
                if tail == dataBlockTerminator, tailOffset + 4 + 4 == data.count {
                    nascentricTailSentinel = true
                    floatsByteCount -= 4
                }
            }

            guard floatsByteCount % 4 == 0 else {
                throw ParseError.invalidSubBlockHeader(offset: reader.offset)
            }
            let floatCount = floatsByteCount / 4

            var floatIndex = 0
            while floatIndex < floatCount {
                let value = try reader.readFloat32()
                floatIndex += 1

                if tupleIndex == 0 && value >= Float(1e29) {
                    // HSPICE in-band end-of-table marker. Skip any remaining
                    // floats in this block; they are garbage padding.
                    sawTerminator = true
                    let bytesRemaining = (floatCount - floatIndex) * 4
                    try reader.skip(bytesRemaining)
                    break
                }

                if tupleIndex == 0 {
                    timeValues.append(value)
                } else {
                    probeValues[tupleIndex - 1].append(value)
                }
                tupleIndex = (tupleIndex + 1) % valuesPerSample
            }

            if nascentricTailSentinel {
                sawTerminator = true
                // Consume the 4B sentinel bytes at the end of the payload.
                _ = try reader.readBytes(4)
            }

            // Sub-block checksum (4B)
            _ = try reader.readUInt32()
        }

        guard tupleIndex == 0 else {
            throw ParseError.truncatedDataBlock(offset: reader.offset)
        }

        for (index, array) in probeValues.enumerated() {
            guard array.count == timeValues.count else {
                throw ParseError.inconsistentProbeLength(
                    probeIndex: index,
                    got: array.count,
                    expected: timeValues.count
                )
            }
        }

        guard probeNames.count == probeCount, typeCodes.count == probeCount else {
            throw ParseError.invalidHeader(
                reason: "probe count mismatch: names=\(probeNames.count), types=\(typeCodes.count), probeCount=\(probeCount)"
            )
        }

        var probes: [TR0Probe] = []
        probes.reserveCapacity(probeCount)
        for index in 0..<probeCount {
            probes.append(TR0Probe(
                name: probeNames[index],
                typeCode: typeCodes[index],
                values: probeValues[index]
            ))
        }

        return TR0Document(
            title: title,
            date: date,
            time: time,
            byteOrder: byteOrder,
            timeValues: timeValues,
            probes: probes
        )
    }

    // MARK: - Helpers

    private enum BlockKind { case fileHeader, subBlock }

    private static func detectByteOrder(data: Data) throws -> ByteOrder {
        guard data.count >= 16 else { throw ParseError.notTR0 }
        for order in [ByteOrder.little, ByteOrder.big] {
            var reader = BinaryReader(data: data, byteOrder: order)
            guard let mI0 = try? reader.readInt32() else { continue }
            _ = try? reader.readInt32()
            guard let mI1 = try? reader.readInt32() else { continue }
            _ = try? reader.readInt32()
            if mI0 == 4 && mI1 == 4 {
                return order
            }
        }
        // If the first bytes are printable ASCII digits, the file is HSPICE
        // ASCII "post=2" text format (e.g. gwave's tlong.tr0.9601). That
        // format is a different codepath and this parser doesn't support it;
        // emit a specific error rather than the generic `notTR0`.
        if data.count >= 16 {
            let prefix = data.prefix(16)
            let allPrintable = prefix.allSatisfy { byte in
                (0x20...0x7e).contains(byte) || byte == 0x09 || byte == 0x0a || byte == 0x0d
            }
            let startsWithDigits = prefix.prefix(4).allSatisfy { (0x30...0x39).contains($0) }
            if allPrintable && startsWithDigits {
                throw ParseError.invalidHeader(
                    reason: "file appears to be ASCII HSPICE post=2 text format; only binary TR0 is supported"
                )
            }
        }
        throw ParseError.notTR0
    }

    private static func readBlockHeader(_ reader: inout BinaryReader, kind: BlockKind) throws -> Int {
        let start = reader.offset
        let mI0 = try reader.readInt32()
        _ = try reader.readInt32()       // item count — redundant with payload size
        let mI1 = try reader.readInt32()
        let adjustedSize = try reader.readInt32()
        guard mI0 == 4, mI1 == 4 else {
            switch kind {
            case .fileHeader:
                throw ParseError.invalidHeader(reason: "sentinels not 4/4 at offset \(start)")
            case .subBlock:
                throw ParseError.invalidSubBlockHeader(offset: start)
            }
        }
        return Int(adjustedSize)
    }

    /// HSPICE binary writers (gwave samples, HMC-ACE samples, real HSPICE)
    /// consistently omit the trailing `)` from probe names, storing `v(out)`
    /// as `v(out`, `i(r2)` as `i(r2`, etc. The 16-byte name slot has plenty
    /// of room; the writer just doesn't emit the closing paren. Nascentric's
    /// `wTrZeroWriter.cpp` does write it. Normalize all names so downstream
    /// code sees the fully-parenthesized form regardless of source dialect.
    /// No-op for names without any `(` (e.g. `TIME`, plain node numbers).
    private static func normalizeProbeName(_ raw: String) -> String {
        guard raw.contains("(") else { return raw }
        if raw.contains(")") { return raw }
        return raw + ")"
    }

    private static func readAsciiIntField(_ reader: inout BinaryReader, field: String) throws -> Int {
        let raw = try reader.readRawASCII(4)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // An empty string (all-space field) is legal and means zero.
        if trimmed.isEmpty { return 0 }
        guard let value = Int(trimmed) else {
            throw ParseError.invalidASCIIInt(field: field, raw: raw)
        }
        return value
    }

    private static func parseWaveformNames(blob: Data, expectedCount: Int) throws -> [String] {
        // The writer pads each name to (1 + rawLength/16) * 16 bytes with trailing spaces, so the
        // last byte of every name's allocation is guaranteed to be a space. Read 16-byte chunks,
        // accumulating into the current name until a chunk ends with a space — that chunk is the
        // last chunk of the current name.
        let names: [String] = blob.withUnsafeBytes { buf -> [String] in
            var result: [String] = []
            result.reserveCapacity(expectedCount)
            var current = ""
            var chunkStart = 0
            while chunkStart < buf.count && result.count < expectedCount {
                let chunkEnd = min(chunkStart + 16, buf.count)
                let bytes = (chunkStart..<chunkEnd).map { buf[$0] }
                let chunkStr = String(bytes: bytes, encoding: .ascii) ?? ""
                current += chunkStr
                chunkStart += 16
                if chunkStr.last == " " {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            return result
        }

        guard names.count == expectedCount else {
            throw ParseError.invalidHeader(
                reason: "waveform name parse got \(names.count) names, expected \(expectedCount)"
            )
        }
        return names
    }
}
