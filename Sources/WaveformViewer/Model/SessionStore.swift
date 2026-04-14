import Foundation

/// On-disk snapshot of everything we persist between app launches:
/// currently the set of loaded files (by absolute path), the ordered list
/// of checked signals, and any per-signal color overrides. The `version`
/// field lets us detect and migrate old snapshots later — right now we
/// just refuse to load anything written by a future version.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var openFiles: [String]
    public var selectedSignals: [SelectedSignalEntry]
    public var customColors: [ColorEntry]

    public init(
        version: Int = 1,
        openFiles: [String] = [],
        selectedSignals: [SelectedSignalEntry] = [],
        customColors: [ColorEntry] = []
    ) {
        self.version = version
        self.openFiles = openFiles
        self.selectedSignals = selectedSignals
        self.customColors = customColors
    }
}

/// A single checked signal in the serialized snapshot. Stored by
/// `(filePath, displayName)` rather than `SignalRef` because DocumentIDs
/// are ephemeral (a fresh one is minted every open) and SignalIDs can in
/// principle drift if the parser changes. Display names are stable text
/// straight out of the source file and survive re-parsing.
public struct SelectedSignalEntry: Codable, Equatable, Sendable {
    public var filePath: String
    public var displayName: String

    public init(filePath: String, displayName: String) {
        self.filePath = filePath
        self.displayName = displayName
    }
}

/// A single per-signal color override in the serialized snapshot. Same
/// file-path + display-name addressing as `SelectedSignalEntry`, plus the
/// sRGB components of the chosen color.
public struct ColorEntry: Codable, Equatable, Sendable {
    public var filePath: String
    public var displayName: String
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(
        filePath: String,
        displayName: String,
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double
    ) {
        self.filePath = filePath
        self.displayName = displayName
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Reads and writes session snapshots to a dot-file in the user's home
/// directory. The file is `~/.waveform-viewer.json`, formatted with
/// sorted keys and pretty printing so it's safe to inspect or edit by
/// hand. Writes are atomic (via `Data.write(options: .atomic)`) so a
/// crash mid-save can't leave a half-written file.
public enum SessionStore {
    public static let currentSchemaVersion = 1

    /// Absolute path to the session dot-file in the user's home directory.
    public static var sessionFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".waveform-viewer.json")
    }

    /// Whether a session file currently exists on disk. Used by the View
    /// menu to disable "Restore Last Session" when there's nothing to
    /// restore.
    public static var sessionFileExists: Bool {
        FileManager.default.fileExists(atPath: sessionFileURL.path)
    }

    public static func save(_ snapshot: SessionSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: sessionFileURL, options: .atomic)
    }

    public static func load() throws -> SessionSnapshot {
        let data = try Data(contentsOf: sessionFileURL)
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(SessionSnapshot.self, from: data)
        if snapshot.version > currentSchemaVersion {
            throw SessionStoreError.unsupportedVersion(
                found: snapshot.version,
                max: currentSchemaVersion
            )
        }
        return snapshot
    }
}

public enum SessionStoreError: Error, LocalizedError {
    case unsupportedVersion(found: Int, max: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let found, let max):
            return "Session file is version \(found); this build understands up to version \(max)."
        }
    }
}
