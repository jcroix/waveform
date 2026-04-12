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
