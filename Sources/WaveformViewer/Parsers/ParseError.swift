import Foundation

public enum ParseError: Error, CustomStringConvertible, Equatable {
    case unexpectedEndOfData(offset: Int, needed: Int)
    case invalidHeader(reason: String)
    case invalidSubBlockHeader(offset: Int)
    case invalidASCIIInt(field: String, raw: String)
    case badWaveformId(offset: Int, raw: String)
    case notTR0
    case truncatedDataBlock(offset: Int)
    case inconsistentProbeLength(probeIndex: Int, got: Int, expected: Int)

    public var description: String {
        switch self {
        case .unexpectedEndOfData(let offset, let needed):
            return "Unexpected end of data at offset \(offset) (needed \(needed) more bytes)"
        case .invalidHeader(let reason):
            return "Invalid TR0 header: \(reason)"
        case .invalidSubBlockHeader(let offset):
            return "Invalid sub-block header at offset \(offset)"
        case .invalidASCIIInt(let field, let raw):
            return "Invalid ASCII integer in \(field): '\(raw)'"
        case .badWaveformId(let offset, let raw):
            return "Unknown waveform ID at offset \(offset): '\(raw)'"
        case .notTR0:
            return "Not a TR0 file (header sentinels did not validate in either byte order)"
        case .truncatedDataBlock(let offset):
            return "Truncated data block at offset \(offset)"
        case .inconsistentProbeLength(let index, let got, let expected):
            return "Probe \(index) has \(got) samples, expected \(expected)"
        }
    }
}
