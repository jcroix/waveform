import Foundation
import Testing
@testable import WaveformViewer

@Test func ticksOnFullRange() {
    let ticks = AxisTicks.niceTicks(min: 0, max: 10, target: 6)
    // 10 / 6 ≈ 1.67 → normalized 1.67 < 3 → step = 2
    #expect(ticks == [0, 2, 4, 6, 8, 10])
}

@Test func ticksOnSubnanoRange() {
    // 3.5e-10 .. 5e-8: range ≈ 5e-8, roughStep ≈ 8.3e-9 → magnitude 1e-9, normalized 8.3 → step 1e-8
    let ticks = AxisTicks.niceTicks(min: 3.5e-10, max: 5e-8, target: 6)
    #expect(ticks.first! > 0)
    #expect(ticks.last! <= 5e-8 + 1e-12)
    #expect(ticks.count >= 4 && ticks.count <= 7)
    // Each tick should be a round multiple of the chosen step (1e-8).
    for tick in ticks {
        let k = (tick / 1e-8).rounded()
        #expect(abs(tick - k * 1e-8) < 1e-18)
    }
}

@Test func ticksOnBipolarCurrent() {
    // -5 mA .. +5 mA, 6 ticks → step = 2 mA → {-4, -2, 0, 2, 4} (5 ticks after rounding)
    let ticks = AxisTicks.niceTicks(min: -5e-3, max: 5e-3, target: 6)
    #expect(ticks.contains(where: { abs($0) < 1e-12 }))      // includes zero
    #expect(ticks.contains(where: { abs($0 - 2e-3) < 1e-12 }))
    #expect(ticks.contains(where: { abs($0 + 2e-3) < 1e-12 }))
}

@Test func degenerateRangeReturnsSingleTick() {
    let ticks = AxisTicks.niceTicks(min: 3.14, max: 3.14)
    #expect(ticks == [3.14])
}

@Test func invertedRangeReturnsEmpty() {
    let ticks = AxisTicks.niceTicks(min: 10, max: 5)
    #expect(ticks.isEmpty)
}

@Test func ticksAreMonotonicallyIncreasing() {
    let ticks = AxisTicks.niceTicks(min: -1.234e-6, max: 2.345e-6, target: 8)
    for i in 1..<ticks.count {
        #expect(ticks[i] > ticks[i - 1])
    }
}
