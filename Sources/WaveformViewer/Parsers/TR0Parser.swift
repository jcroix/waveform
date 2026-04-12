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

        let nodeCount = try readAsciiIntField(&reader, field: "nodeCount")
        _ = try readAsciiIntField(&reader, field: "probeCount")
        _ = try readAsciiIntField(&reader, field: "sweepCount")
        _ = try reader.readRawASCII(4)   // reserved
        _ = try reader.readRawASCII(8)   // "9601    "
        let title = try reader.readASCIIField(64)
        let date = try reader.readASCIIField(16)
        let time = try reader.readASCIIField(8)
        _ = try reader.readRawASCII(72)  // copyright

        // Sweep info: 4B count + 19 × 4B padding = 80B
        _ = try reader.readRawASCII(80)

        // Waveform IDs: (nodeCount + 1) × 8B, first is the time column
        let totalIds = nodeCount + 1
        var typeCodes: [Int] = []
        typeCodes.reserveCapacity(nodeCount)
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
        let probeNames = Array(allNames.dropFirst())

        // Trailer: 8B "$&%#    "
        let trailer = try reader.readRawASCII(8)
        guard trailer == "$&%#    " else {
            throw ParseError.invalidHeader(reason: "bad trailer '\(trailer)'")
        }

        // File-header checksum (4B). Not validated — writer records adjusted size, not a real hash.
        _ = try reader.readUInt32()

        // ─── Data blocks ────────────────────────────────────────────────────
        let valuesPerSample = nodeCount + 1
        let estimatedSamples = max(16, reader.remaining / (valuesPerSample * 4))
        var timeValues: [Float] = []
        timeValues.reserveCapacity(estimatedSamples)
        var probeValues: [[Float]] = Array(repeating: [], count: nodeCount)
        for idx in 0..<nodeCount {
            probeValues[idx].reserveCapacity(estimatedSamples)
        }

        var tupleIndex = 0  // 0 = time, 1..nodeCount = probe (tupleIndex - 1)
        var sawTerminator = false

        while !sawTerminator, reader.remaining >= 16 {
            let payloadSize = try readBlockHeader(&reader, kind: .subBlock)
            guard payloadSize >= 0, reader.remaining >= payloadSize else {
                throw ParseError.truncatedDataBlock(offset: reader.offset)
            }

            // Check for terminator at the tail of this payload. To minimize false positives we
            // also require the sub-block end to land at EOF-minus-checksum (4B).
            var floatsByteCount = payloadSize
            if payloadSize >= 4 {
                let tailOffset = reader.offset + payloadSize - 4
                let tail = try reader.peekBytes(4, at: tailOffset)
                if tail == dataBlockTerminator, tailOffset + 4 + 4 == data.count {
                    sawTerminator = true
                    floatsByteCount -= 4
                }
            }

            guard floatsByteCount % 4 == 0 else {
                throw ParseError.invalidSubBlockHeader(offset: reader.offset)
            }
            let floatCount = floatsByteCount / 4

            for _ in 0..<floatCount {
                let value = try reader.readFloat32()
                if tupleIndex == 0 {
                    timeValues.append(value)
                } else {
                    probeValues[tupleIndex - 1].append(value)
                }
                tupleIndex = (tupleIndex + 1) % valuesPerSample
            }

            if sawTerminator {
                // Skip the 4B terminator bytes that live in the block payload.
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

        guard probeNames.count == nodeCount, typeCodes.count == nodeCount else {
            throw ParseError.invalidHeader(
                reason: "probe count mismatch: names=\(probeNames.count), types=\(typeCodes.count), nodeCount=\(nodeCount)"
            )
        }

        var probes: [TR0Probe] = []
        probes.reserveCapacity(nodeCount)
        for index in 0..<nodeCount {
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
