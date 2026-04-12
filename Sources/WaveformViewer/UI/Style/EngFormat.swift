import Foundation

/// Engineering-notation formatter and parser for axis labels and user input. Maps
/// a numeric value to a mantissa paired with the nearest SI prefix (f, p, n, µ, m,
/// k, M, G, T). Used by plot axis labels for time (`"s"`) and value (`"V"`, `"A"`,
/// `"W"`, …) readouts.
enum EngFormat {
    private static let prefixes: [(exponent: Int, symbol: String)] = [
        (-15, "f"), (-12, "p"), (-9, "n"), (-6, "µ"), (-3, "m"),
        (0, ""),   (3, "k"),   (6, "M"),  (9, "G"),  (12, "T"),
    ]

    /// Format `value` with the given base `unit`. Zero renders as `"0 <unit>"`;
    /// negatives get a leading sign; the mantissa has up to `significantDigits`
    /// significant digits with trailing zeros stripped. Default is 3 (what axis
    /// tick labels use); higher precision is useful for status-bar readouts where
    /// the user wants to see more of the underlying numeric value.
    static func format(
        _ value: Double,
        unit: String,
        significantDigits: Int = 3
    ) -> String {
        if value == 0 {
            return unit.isEmpty ? "0" : "0 \(unit)"
        }
        let sign = value < 0 ? "-" : ""
        let absValue = abs(value)

        // Pick the SI prefix whose exponent is the largest multiple of 3 ≤ log10(absValue).
        let rawExponent = Int(floor(log10(absValue) / 3.0)) * 3
        let exponent = max(-15, min(12, rawExponent))
        let symbol = prefixes.first(where: { $0.exponent == exponent })?.symbol ?? ""
        let mantissa = absValue / pow(10.0, Double(exponent))

        // Mantissa lives in [1, 1000). Decimals = significantDigits - (integer-part digits).
        let sig = max(1, significantDigits)
        let decimals: Int
        if mantissa >= 100 {
            decimals = max(0, sig - 3)
        } else if mantissa >= 10 {
            decimals = max(0, sig - 2)
        } else {
            decimals = max(0, sig - 1)
        }

        var mantissaString = String(format: "%.\(decimals)f", mantissa)
        // Strip trailing zeros and a dangling decimal point.
        if mantissaString.contains(".") {
            while mantissaString.hasSuffix("0") { mantissaString.removeLast() }
            if mantissaString.hasSuffix(".") { mantissaString.removeLast() }
        }

        if symbol.isEmpty && unit.isEmpty {
            return "\(sign)\(mantissaString)"
        }
        return "\(sign)\(mantissaString) \(symbol)\(unit)"
    }

    private static let prefixMultipliers: [Character: Double] = [
        "f": 1e-15,
        "p": 1e-12,
        "n": 1e-9,
        "µ": 1e-6,
        "u": 1e-6,
        "m": 1e-3,
        "k": 1e3,
        "M": 1e6,
        "G": 1e9,
        "T": 1e12,
    ]

    /// Parses a human-entered time string into seconds. Accepts:
    /// plain floats (`"1e-9"`, `"0.5"`, `"17"`), SI prefixes (`"17ns"`, `"1.5 us"`,
    /// `"300 ps"`, `"2M"`), trailing `"s"` / `"sec"` / `"seconds"` (case-insensitive),
    /// and arbitrary internal whitespace. Returns `nil` on unparseable input.
    static func parseTime(_ input: String) -> Double? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Drop trailing "seconds" / "sec" / "s" (case-insensitive).
        let lower = s.lowercased()
        if lower.hasSuffix("seconds") {
            s = String(s.dropLast(7)).trimmingCharacters(in: .whitespaces)
        } else if lower.hasSuffix("sec") {
            s = String(s.dropLast(3)).trimmingCharacters(in: .whitespaces)
        } else if lower.hasSuffix("s") {
            s = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        // Drop a single-character SI prefix off the tail.
        var multiplier: Double = 1
        if let last = s.last, let mult = prefixMultipliers[last] {
            multiplier = mult
            s = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        guard !s.isEmpty, let value = Double(s) else { return nil }
        return value * multiplier
    }
}
