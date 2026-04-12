import Foundation

public enum LoadedFormat: Sendable, Equatable {
    case tr0(ByteOrder)
    case listing(outputFormat: String?)
}

/// Unified in-memory representation of a loaded simulation result. Both the TR0 binary parser
/// and the `.out` listing parser feed into this type via `WaveformDocument.load(from:)`, so
/// downstream UI code is source-agnostic.
public struct WaveformDocument: Sendable {
    public let sourceURL: URL
    public let format: LoadedFormat
    public let title: String
    public let analysisKind: AnalysisKind
    public let hierarchySeparator: String
    public let timeValues: [Double]
    public let signals: [Signal]
    public let hierarchyRoot: HierarchyNode

    public init(
        sourceURL: URL,
        format: LoadedFormat,
        title: String,
        analysisKind: AnalysisKind,
        hierarchySeparator: String,
        timeValues: [Double],
        signals: [Signal]
    ) {
        self.sourceURL = sourceURL
        self.format = format
        self.title = title
        self.analysisKind = analysisKind
        self.hierarchySeparator = hierarchySeparator
        self.timeValues = timeValues
        self.signals = signals
        self.hierarchyRoot = HierarchyNode.build(signals: signals, separator: hierarchySeparator)
    }

    public var sampleCount: Int { timeValues.count }

    public func signal(withID id: SignalID) -> Signal? {
        if id >= 0 && id < signals.count && signals[id].id == id {
            return signals[id]
        }
        return signals.first { $0.id == id }
    }
}

// MARK: - Loading

extension WaveformDocument {
    public static func load(from url: URL) throws -> WaveformDocument {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "tr0":
            return try loadTR0(url: url)
        case "out":
            return try loadListing(url: url)
        default:
            throw ParseError.invalidHeader(reason: "unsupported file extension: '\(ext)'")
        }
    }

    public static func loadTR0(url: URL) throws -> WaveformDocument {
        let parsed = try TR0Parser.parse(url: url)
        return fromTR0(parsed, sourceURL: url, separatorHint: ".", titleOverride: nil)
    }

    public static func loadListing(url: URL) throws -> WaveformDocument {
        let listing = try ListingParser.parse(url: url)

        if listing.hasEmbeddedWaveforms {
            return try fromListing(listing, sourceURL: url)
        }

        // Auto-discover a sibling .tr0 with the same basename in the same directory.
        // This is the NASC_OUTFORMAT = "tr0" case where the listing carries only the run
        // log and the waveforms live in the companion binary file.
        let sibling = url.deletingPathExtension().appendingPathExtension("tr0")
        guard FileManager.default.fileExists(atPath: sibling.path) else {
            throw ParseError.invalidHeader(
                reason: "listing has no embedded waveforms and no sibling .tr0 at '\(sibling.lastPathComponent)'"
            )
        }
        let parsed = try TR0Parser.parse(url: sibling)
        return fromTR0(
            parsed,
            sourceURL: url,    // keep the listing as the user-visible source
            separatorHint: listing.hierarchySeparator,
            titleOverride: listing.title.isEmpty ? nil : listing.title
        )
    }

    // MARK: Converters

    private static func fromTR0(
        _ doc: TR0Document,
        sourceURL: URL,
        separatorHint: String,
        titleOverride: String?
    ) -> WaveformDocument {
        let separator = separatorHint.isEmpty ? "." : separatorHint
        var signals: [Signal] = []
        signals.reserveCapacity(doc.probes.count)
        for (index, probe) in doc.probes.enumerated() {
            let kind = signalKindFromTR0(typeCode: probe.typeCode, name: probe.name)
            let unit = defaultUnit(for: kind)
            let (path, bareName) = parseSignalName(displayName: probe.name, separator: separator)
            signals.append(Signal(
                id: index,
                displayName: probe.name,
                path: path,
                bareName: bareName,
                kind: kind,
                unit: unit,
                values: probe.values
            ))
        }
        return WaveformDocument(
            sourceURL: sourceURL,
            format: .tr0(doc.byteOrder),
            title: titleOverride ?? doc.title,
            analysisKind: .transient,
            hierarchySeparator: separator,
            timeValues: doc.timeValues.map(Double.init),
            signals: signals
        )
    }

    private static func fromListing(
        _ listing: OutListing,
        sourceURL: URL
    ) throws -> WaveformDocument {
        // Prefer a transient block; otherwise take the first available block.
        let block = listing.waveformBlocks.first(where: { $0.analysisKind == .transient })
                  ?? listing.waveformBlocks.first
        guard let block = block else {
            throw ParseError.invalidHeader(reason: "listing has no usable waveform block")
        }

        let separator = listing.hierarchySeparator.isEmpty ? "." : listing.hierarchySeparator
        var signals: [Signal] = []
        signals.reserveCapacity(block.probes.count)
        for (index, probe) in block.probes.enumerated() {
            let (path, bareName) = parseSignalName(displayName: probe.name, separator: separator)
            signals.append(Signal(
                id: index,
                displayName: probe.name,
                path: path,
                bareName: bareName,
                kind: probe.kind,
                unit: probe.unit,
                values: probe.values
            ))
        }

        return WaveformDocument(
            sourceURL: sourceURL,
            format: .listing(outputFormat: listing.outputFormat),
            title: listing.title,
            analysisKind: block.analysisKind ?? .transient,
            hierarchySeparator: separator,
            timeValues: block.timeValues.map(Double.init),
            signals: signals
        )
    }

    private static func signalKindFromTR0(typeCode: Int, name: String) -> SignalKind {
        let lower = name.lowercased()
        if lower.hasPrefix("v(") { return .voltage }
        if lower.hasPrefix("i(") { return .current }
        if lower.hasPrefix("p(") { return .power }
        switch typeCode {
        case 1: return .voltage
        case 8: return .current
        default: return .unknown("type\(typeCode)")
        }
    }

    private static func defaultUnit(for kind: SignalKind) -> String {
        switch kind {
        case .voltage, .logicVoltage: return "V"
        case .current:                return "A"
        case .power:                  return "W"
        case .unknown(let raw):       return raw
        }
    }
}
