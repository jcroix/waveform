import Foundation
import Testing
@testable import WaveformViewer

@Test func zeroValue() {
    #expect(EngFormat.format(0, unit: "V") == "0 V")
    #expect(EngFormat.format(0, unit: "") == "0")
}

@Test func simpleUnitless() {
    #expect(EngFormat.format(1, unit: "V") == "1 V")
    #expect(EngFormat.format(3.3, unit: "V") == "3.3 V")
    #expect(EngFormat.format(5, unit: "V") == "5 V")
}

@Test func milliAndMicroAndNano() {
    #expect(EngFormat.format(1.5e-3, unit: "V") == "1.5 mV")
    #expect(EngFormat.format(2.5e-4, unit: "A") == "250 µA")
    #expect(EngFormat.format(3.5e-10, unit: "s") == "350 ps")
    #expect(EngFormat.format(50e-9, unit: "s") == "50 ns")
}

@Test func kiloAndMega() {
    #expect(EngFormat.format(1500, unit: "Hz") == "1.5 kHz")
    #expect(EngFormat.format(2.5e6, unit: "Hz") == "2.5 MHz")
}

@Test func negativeValues() {
    #expect(EngFormat.format(-1.3, unit: "V") == "-1.3 V")
    #expect(EngFormat.format(-2.5e-4, unit: "A") == "-250 µA")
}

@Test func trailingZeroStripping() {
    // 2.00 should render as "2", not "2.00".
    #expect(EngFormat.format(2.0, unit: "V") == "2 V")
    // 1.20 should render as "1.2".
    #expect(EngFormat.format(1.2, unit: "V") == "1.2 V")
}

@Test func threeSignificantDigits() {
    // Mantissa ≥ 100 uses 0 decimals, ≥ 10 uses 1, < 10 uses 2.
    #expect(EngFormat.format(123, unit: "V") == "123 V")
    #expect(EngFormat.format(12.5, unit: "V") == "12.5 V")
    #expect(EngFormat.format(1.25, unit: "V") == "1.25 V")
}

@Test func higherPrecisionFormat() {
    // Variable-precision format: status-bar readouts can use 6+ sig figs.
    #expect(EngFormat.format(17.3248e-9, unit: "s", significantDigits: 6) == "17.3248 ns")
    #expect(EngFormat.format(1.234567e-6, unit: "s", significantDigits: 6) == "1.23457 µs")
    // 9 sig figs shows the full Float32 precision, which is what the status bar uses.
    #expect(EngFormat.format(3.50000e-10, unit: "s", significantDigits: 9) == "350 ps")
    #expect(EngFormat.format(17.32481234e-9, unit: "s", significantDigits: 9) == "17.3248123 ns")
}

// MARK: - parseTime

@Test func parseTimePlainSeconds() {
    #expect(EngFormat.parseTime("1") == 1.0)
    #expect(EngFormat.parseTime("0.5") == 0.5)
    #expect(EngFormat.parseTime("1e-9") == 1e-9)
    #expect(EngFormat.parseTime("1 s") == 1.0)
}

@Test func parseTimeSIPrefixes() {
    #expect(EngFormat.parseTime("17ns")! == 17e-9)
    #expect(EngFormat.parseTime("1.5us")! == 1.5e-6)
    #expect(EngFormat.parseTime("500 ps")! == 500e-12)
    #expect(EngFormat.parseTime("2m")! == 2e-3)
}

@Test func parseTimeWithSuffix() {
    #expect(EngFormat.parseTime("1e-9 s")! == 1e-9)
    #expect(EngFormat.parseTime("17 nsec")! == 17e-9)
    #expect(EngFormat.parseTime("500 ps")! == 500e-12)
}

@Test func parseTimeInvalidInput() {
    #expect(EngFormat.parseTime("") == nil)
    #expect(EngFormat.parseTime("   ") == nil)
    #expect(EngFormat.parseTime("nonsense") == nil)
    // Bare SI prefix with no number.
    #expect(EngFormat.parseTime("n") == nil)
}
