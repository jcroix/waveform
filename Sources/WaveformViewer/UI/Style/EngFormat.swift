import Foundation

/// Engineering-notation formatter for axis labels. Maps a numeric value to a mantissa
/// paired with the nearest SI prefix (f, p, n, µ, m, k, M, G, T) rounded to three
/// significant digits. Used by the plot axis labels for both time (`"s"`) and value
/// (`"V"`, `"A"`, `"W"`, …).
enum EngFormat {
    private static let prefixes: [(exponent: Int, symbol: String)] = [
        (-15, "f"), (-12, "p"), (-9, "n"), (-6, "µ"), (-3, "m"),
        (0, ""),   (3, "k"),   (6, "M"),  (9, "G"),  (12, "T"),
    ]

    /// Format `value` with the given base `unit`. Zero renders as `"0 <unit>"`; negatives
    /// get a leading sign; the mantissa has up to three significant digits with trailing
    /// zeros stripped.
    static func format(_ value: Double, unit: String) -> String {
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

        // Three significant digits on the mantissa (mantissa lives in [1, 1000)).
        let decimals: Int
        if mantissa >= 100 {
            decimals = 0
        } else if mantissa >= 10 {
            decimals = 1
        } else {
            decimals = 2
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
}
