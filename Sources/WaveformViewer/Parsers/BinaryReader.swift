import Foundation

public enum ByteOrder: Sendable, Equatable {
    case little
    case big
}

struct BinaryReader {
    let data: Data
    var offset: Int
    let byteOrder: ByteOrder

    init(data: Data, byteOrder: ByteOrder, offset: Int = 0) {
        self.data = data
        self.byteOrder = byteOrder
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else {
            throw ParseError.unexpectedEndOfData(offset: offset, needed: 4)
        }
        let result: UInt32 = data.withUnsafeBytes { buf -> UInt32 in
            let b0 = UInt32(buf[offset])
            let b1 = UInt32(buf[offset + 1])
            let b2 = UInt32(buf[offset + 2])
            let b3 = UInt32(buf[offset + 3])
            switch byteOrder {
            case .little: return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
            case .big:    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            }
        }
        offset += 4
        return result
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readFloat32() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard remaining >= count else {
            throw ParseError.unexpectedEndOfData(offset: offset, needed: count)
        }
        let result = data.withUnsafeBytes { buf -> Data in
            Data(buf[offset..<(offset + count)])
        }
        offset += count
        return result
    }

    mutating func readRawASCII(_ count: Int) throws -> String {
        let bytes = try readBytes(count)
        return String(data: bytes, encoding: .ascii) ?? ""
    }

    mutating func readASCIIField(_ count: Int) throws -> String {
        try readRawASCII(count).trimmingCharacters(in: .whitespaces)
    }

    mutating func skip(_ count: Int) throws {
        guard remaining >= count else {
            throw ParseError.unexpectedEndOfData(offset: offset, needed: count)
        }
        offset += count
    }

    func peekBytes(_ count: Int, at position: Int) throws -> [UInt8] {
        guard position >= 0, position + count <= data.count else {
            throw ParseError.unexpectedEndOfData(offset: position, needed: count)
        }
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> [UInt8] in
            (position..<(position + count)).map { buf[$0] }
        }
    }
}
