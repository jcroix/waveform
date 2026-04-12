import Foundation

// MARK: - Public types

public enum SignalKind: Sendable, Equatable {
    case voltage
    case current
    case power
    case logicVoltage
    case unknown(String)
}

public enum AnalysisKind: String, Sendable, Equatable {
    case dc
    case transient
    case ac
}

public struct AnalysisRecord: Sendable, Equatable {
    public let kind: AnalysisKind
    public let endTime: String?  // raw text such as "50ns"
}

public struct ListingProbe: Sendable, Equatable {
    public let name: String      // "v(clk)", "i(vdd)" — exact column header
    public let unit: String      // "V","A","W","L"
    public let kind: SignalKind
    public let values: [Float]
}

public struct ListingWaveformBlock: Sendable, Equatable {
    public let analysisKind: AnalysisKind?
    public let columnNames: [String]   // includes "Time" at index 0
    public let columnUnits: [String]   // includes "s" at index 0
    public let timeValues: [Float]
    public let probes: [ListingProbe]
}

public struct OutListing: Sendable, Equatable {
    public let title: String
    public let hierarchySeparator: String   // from NASC_HIERID, default "."
    public let outputFormat: String?        // from NASC_OUTFORMAT
    public let analyses: [AnalysisRecord]
    public let waveformBlocks: [ListingWaveformBlock]
    public let succeeded: Bool

    public var hasEmbeddedWaveforms: Bool { !waveformBlocks.isEmpty }
}

// MARK: - Parser

public enum ListingParser {
    public static func parse(url: URL) throws -> OutListing {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) else {
            throw ParseError.invalidHeader(reason: "could not decode listing as UTF-8/ASCII")
        }
        return try parse(text: text)
    }

    public static func parse(text: String) throws -> OutListing {
        var lines: [Substring] = []
        text.split(omittingEmptySubsequences: false) { $0.isNewline }.forEach {
            lines.append($0)
        }

        var index = 0
        var title = ""
        var hierarchySeparator = "."
        var outputFormat: String? = nil
        var analyses: [AnalysisRecord] = []
        var blocks: [ListingWaveformBlock] = []
        var inOptions = false
        // Default to true so that listings without an explicit failure marker are
        // treated as successful; flipped on detection of an explicit failure line.
        var succeeded = true
        var sawSuccessLine = false

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Title line: "Title: …"
            if trimmed.hasPrefix("Title:") {
                title = String(trimmed.dropFirst("Title:".count))
                    .trimmingCharacters(in: .whitespaces)
                index += 1
                continue
            }

            // Option-settings block boundary
            if trimmed == "Option Settings:" {
                inOptions = true
                index += 1
                continue
            }

            if inOptions {
                if trimmed.isEmpty {
                    inOptions = false
                    index += 1
                    continue
                }
                let (key, value) = parseOption(trimmed)
                switch key {
                case "NASC_HIERID":
                    if !value.isEmpty { hierarchySeparator = value }
                case "NASC_OUTFORMAT":
                    outputFormat = value
                default:
                    break
                }
                index += 1
                continue
            }

            // Analysis-status messages
            if let analysis = parseAnalysisStatus(trimmed) {
                analyses.append(analysis)
                index += 1
                continue
            }

            // Waveform block
            if trimmed == "x" {
                index += 1
                let block = try parseWaveformBlock(
                    lines: lines,
                    index: &index,
                    analysisKind: analyses.last?.kind
                )
                blocks.append(block)
                continue
            }

            // Success / failure footers
            if trimmed.contains("[info 1521]") || trimmed.contains("Simulation succeeded") {
                succeeded = true
                sawSuccessLine = true
            } else if trimmed.lowercased().contains("simulation failed") {
                succeeded = false
                sawSuccessLine = true
            }

            index += 1
        }

        // If we saw neither a success nor a failure marker, leave succeeded == true
        // (the default). This matches OmegaSim's behavior of always emitting [info 1521].
        _ = sawSuccessLine

        return OutListing(
            title: title,
            hierarchySeparator: hierarchySeparator,
            outputFormat: outputFormat,
            analyses: analyses,
            waveformBlocks: blocks,
            succeeded: succeeded
        )
    }

    // MARK: - Helpers

    private static func parseOption(_ line: String) -> (key: String, value: String) {
        guard let eq = line.firstIndex(of: "=") else { return ("", "") }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        var value = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: .whitespaces)

        // Strip a trailing "(default: …)" annotation if present.
        if let paren = value.firstIndex(of: "(") {
            value = String(value[..<paren]).trimmingCharacters(in: .whitespaces)
        }

        // Strip surrounding double quotes if both ends quoted.
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }

        return (key, value)
    }

    private static func parseAnalysisStatus(_ line: String) -> AnalysisRecord? {
        if line == "DC analysis completed." {
            return AnalysisRecord(kind: .dc, endTime: nil)
        }
        if line.hasPrefix("Transient analysis completed at time ") {
            let suffix = line.dropFirst("Transient analysis completed at time ".count)
            let endTime = suffix.trimmingCharacters(in: CharacterSet(charactersIn: ". \t"))
            return AnalysisRecord(kind: .transient, endTime: endTime)
        }
        if line == "AC analysis completed." {
            return AnalysisRecord(kind: .ac, endTime: nil)
        }
        return nil
    }

    private static func parseWaveformBlock(
        lines: [Substring],
        index: inout Int,
        analysisKind: AnalysisKind?
    ) throws -> ListingWaveformBlock {
        // index is currently pointing at the line right after "x".
        guard index < lines.count else {
            throw ParseError.invalidHeader(reason: "waveform block: missing name row")
        }
        let columnNames = lines[index]
            .split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .map(String.init)
        index += 1

        guard index < lines.count else {
            throw ParseError.invalidHeader(reason: "waveform block: missing unit row")
        }
        let columnUnits = lines[index]
            .split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .map(String.init)
        index += 1

        guard columnNames.count >= 2 else {
            throw ParseError.invalidHeader(reason: "waveform block: too few columns")
        }
        guard columnUnits.count == columnNames.count else {
            throw ParseError.invalidHeader(
                reason: "waveform block: name/unit count mismatch (\(columnNames.count) vs \(columnUnits.count))"
            )
        }

        let probeCount = columnNames.count - 1
        var timeValues: [Float] = []
        var probeArrays: [[Float]] = Array(repeating: [], count: probeCount)
        // Estimate row count from remaining lines so we don't hammer the allocator.
        let remaining = lines.count - index
        timeValues.reserveCapacity(remaining)
        for idx in 0..<probeCount {
            probeArrays[idx].reserveCapacity(remaining)
        }

        var sawTerminator = false
        while index < lines.count {
            let row = lines[index].trimmingCharacters(in: .whitespaces)
            if row == "y" {
                index += 1
                sawTerminator = true
                break
            }
            if row.isEmpty {
                index += 1
                continue
            }

            let columns = row.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard columns.count == columnNames.count else {
                throw ParseError.invalidHeader(
                    reason: "waveform row column count \(columns.count) != header \(columnNames.count) (line \(index + 1))"
                )
            }

            guard let t = Float(columns[0]) else {
                throw ParseError.invalidHeader(reason: "bad time value '\(columns[0])' on line \(index + 1)")
            }
            timeValues.append(t)
            for probeIndex in 0..<probeCount {
                guard let v = Float(columns[probeIndex + 1]) else {
                    throw ParseError.invalidHeader(
                        reason: "bad numeric value '\(columns[probeIndex + 1])' on line \(index + 1)"
                    )
                }
                probeArrays[probeIndex].append(v)
            }
            index += 1
        }

        guard sawTerminator else {
            throw ParseError.invalidHeader(reason: "waveform block: missing closing 'y'")
        }

        var probes: [ListingProbe] = []
        probes.reserveCapacity(probeCount)
        for i in 0..<probeCount {
            let name = columnNames[i + 1]
            let unit = columnUnits[i + 1]
            probes.append(ListingProbe(
                name: name,
                unit: unit,
                kind: signalKind(for: unit),
                values: probeArrays[i]
            ))
        }

        return ListingWaveformBlock(
            analysisKind: analysisKind,
            columnNames: columnNames,
            columnUnits: columnUnits,
            timeValues: timeValues,
            probes: probes
        )
    }

    private static func signalKind(for unit: String) -> SignalKind {
        switch unit.uppercased() {
        case "V": return .voltage
        case "A": return .current
        case "W": return .power
        case "L": return .logicVoltage
        default:  return .unknown(unit)
        }
    }
}
