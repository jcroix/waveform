import AppKit
import Foundation
import Testing
@testable import WaveformViewer

// MARK: - Test helpers

@MainActor
private func makeState() -> WaveformAppState {
    let state = WaveformAppState(sharedState: SharedPlotState())
    // Tests must NEVER write to the user's real `~/.waveform-viewer.json`.
    state.autoSaveEnabled = false
    return state
}

/// Build a small synthetic `WaveformDocument` without going through the
/// parsers. The exact sample values aren't important — these tests verify
/// the multi-file state model, not the plot output.
private func makeDocument(
    title: String,
    signals: [(name: String, kind: SignalKind, values: [Float])],
    startTime: Double = 0,
    endTime: Double = 100
) -> WaveformDocument {
    var built: [Signal] = []
    for (index, entry) in signals.enumerated() {
        let (path, bare) = parseSignalName(displayName: entry.name, separator: ".")
        built.append(Signal(
            id: index,
            displayName: entry.name,
            path: path,
            bareName: bare,
            kind: entry.kind,
            unit: defaultUnitString(for: entry.kind),
            values: entry.values
        ))
    }
    let sampleCount = max(2, built.first?.values.count ?? 2)
    let step = (endTime - startTime) / Double(sampleCount - 1)
    let times = (0..<sampleCount).map { startTime + Double($0) * step }
    return WaveformDocument(
        sourceURL: URL(fileURLWithPath: "/tmp/\(title).tr0"),
        format: .tr0(.little),
        title: title,
        analysisKind: .transient,
        hierarchySeparator: ".",
        timeValues: times,
        signals: built
    )
}

private func defaultUnitString(for kind: SignalKind) -> String {
    switch kind {
    case .voltage, .logicVoltage: return "V"
    case .current:                return "A"
    case .power:                  return "W"
    case .unknown(let raw):       return raw
    }
}

private func sampleValues(count: Int, seed: Float) -> [Float] {
    (0..<count).map { Float($0) * 0.01 + seed }
}

// MARK: - Loading multiple documents

@MainActor
@Test func loadTwoCopiesProducesDistinctDocumentIDs() {
    let state = makeState()

    let doc = makeDocument(
        title: "variantA",
        signals: [
            ("v(clk)",  .voltage, sampleValues(count: 10, seed: 0.0)),
            ("i(vdd)",  .current, sampleValues(count: 10, seed: 1.0)),
        ]
    )
    let a = LoadedDocument(document: doc)
    let b = LoadedDocument(document: doc)
    state.injectForTests(documents: [a, b])

    #expect(state.documents.count == 2)
    #expect(state.fileNodes.count == 2)
    #expect(a.id != b.id)

    let refA = SignalRef(document: a.id, local: 0)
    let refB = SignalRef(document: b.id, local: 0)
    #expect(refA != refB)
    // Distinct refs still resolve to the same underlying probe, just in
    // different loaded documents.
    #expect(state.resolve(refA)?.displayName == "v(clk)")
    #expect(state.resolve(refB)?.displayName == "v(clk)")
}

@MainActor
@Test func overallTimeRangeIsUnionAcrossDocuments() {
    let state = makeState()

    let a = LoadedDocument(document: makeDocument(
        title: "A",
        signals: [("v(a)", .voltage, sampleValues(count: 5, seed: 0.0))],
        startTime: 0,
        endTime: 50
    ))
    let b = LoadedDocument(document: makeDocument(
        title: "B",
        signals: [("v(b)", .voltage, sampleValues(count: 5, seed: 0.0))],
        startTime: 30,
        endTime: 120
    ))
    state.injectForTests(documents: [a, b])

    #expect(state.overallTimeRange == 0.0...120.0)
}

// MARK: - Visibility gating

@MainActor
@Test func fileGateHidesEveryDescendantWithoutClearingChildChecks() {
    let state = makeState()
    let loaded = LoadedDocument(document: makeDocument(
        title: "A",
        signals: [
            ("v(a)",  .voltage, sampleValues(count: 10, seed: 0.0)),
            ("v(b)",  .voltage, sampleValues(count: 10, seed: 0.0)),
            ("i(vdd)", .current, sampleValues(count: 10, seed: 1.0)),
        ]
    ))
    state.injectForTests(documents: [loaded])

    let refA = SignalRef(document: loaded.id, local: 0)
    let refB = SignalRef(document: loaded.id, local: 1)
    let refC = SignalRef(document: loaded.id, local: 2)
    state.setSignalChecked(refA, checked: true)
    state.setSignalChecked(refB, checked: true)
    state.setSignalChecked(refC, checked: true)

    // Precondition: all three show up as effective-visible.
    #expect(state.effectiveVisibleSignals(unit: .voltage).count == 2)
    #expect(state.effectiveVisibleSignals(unit: .current).count == 1)

    // Close the file-level gate.
    let fileKey = HierarchyKey(document: loaded.id, fullPath: "")
    state.setGateOpen(fileKey, open: false)

    // Everything hidden, but the child checkbox state is intact.
    #expect(state.effectiveVisibleSignals(unit: .voltage).isEmpty)
    #expect(state.effectiveVisibleSignals(unit: .current).isEmpty)
    #expect(state.isChecked(refA))
    #expect(state.isChecked(refB))
    #expect(state.isChecked(refC))

    // Re-open the gate — the previously-checked set reappears instantly.
    state.setGateOpen(fileKey, open: true)
    #expect(state.effectiveVisibleSignals(unit: .voltage).count == 2)
    #expect(state.effectiveVisibleSignals(unit: .current).count == 1)
}

@MainActor
@Test func checkingChildUnderClosedGateAutoReopensAncestors() {
    let state = makeState()
    let loaded = LoadedDocument(document: makeDocument(
        title: "A",
        signals: [
            ("v(x1.clk)", .voltage, sampleValues(count: 10, seed: 0.0)),
            ("v(x1.out)", .voltage, sampleValues(count: 10, seed: 0.0)),
        ]
    ))
    state.injectForTests(documents: [loaded])

    let refClk = SignalRef(document: loaded.id, local: 0)
    let refOut = SignalRef(document: loaded.id, local: 1)

    // Close both the file-level gate AND the x1-subckt gate.
    let fileKey = HierarchyKey(document: loaded.id, fullPath: "")
    let x1Key = HierarchyKey(document: loaded.id, fullPath: "x1")
    state.setGateOpen(fileKey, open: false)
    state.setGateOpen(x1Key, open: false)
    #expect(!state.isGateOpen(fileKey))
    #expect(!state.isGateOpen(x1Key))

    // Checking a child should auto-reopen every ancestor gate along its path.
    state.setSignalChecked(refClk, checked: true)
    #expect(state.isGateOpen(fileKey))
    #expect(state.isGateOpen(x1Key))
    #expect(state.effectiveVisibleSignals(unit: .voltage) == [refClk])

    // The OTHER child's checkbox is still off and it does not auto-appear.
    #expect(!state.isChecked(refOut))
}

@MainActor
@Test func interiorGateHidesOnlyItsSubtree() {
    let state = makeState()
    let loaded = LoadedDocument(document: makeDocument(
        title: "A",
        signals: [
            ("v(x1.a)", .voltage, sampleValues(count: 10, seed: 0.0)),
            ("v(x2.b)", .voltage, sampleValues(count: 10, seed: 0.0)),
        ]
    ))
    state.injectForTests(documents: [loaded])

    let refA = SignalRef(document: loaded.id, local: 0)
    let refB = SignalRef(document: loaded.id, local: 1)
    state.setSignalChecked(refA, checked: true)
    state.setSignalChecked(refB, checked: true)

    let x1Key = HierarchyKey(document: loaded.id, fullPath: "x1")
    state.setGateOpen(x1Key, open: false)

    let visible = state.effectiveVisibleSignals(unit: .voltage)
    #expect(visible == [refB])
}

// MARK: - Hub title

@MainActor
@Test func hubTitleIsCorrectAcrossDocCounts() {
    let state = makeState()

    #expect(state.hubTitle == "Waveform Viewer")

    let a = LoadedDocument(document: makeDocument(
        title: "alpha",
        signals: [("v(a)", .voltage, sampleValues(count: 5, seed: 0.0))]
    ))
    state.injectForTests(documents: [a])
    #expect(state.hubTitle == "alpha")

    let b = LoadedDocument(document: makeDocument(
        title: "beta",
        signals: [("v(b)", .voltage, sampleValues(count: 5, seed: 0.0))]
    ))
    state.injectForTests(documents: [a, b])
    #expect(state.hubTitle == "alpha.tr0, beta.tr0")

    let c = LoadedDocument(document: makeDocument(
        title: "gamma",
        signals: [("v(c)", .voltage, sampleValues(count: 5, seed: 0.0))]
    ))
    let d = LoadedDocument(document: makeDocument(
        title: "delta",
        signals: [("v(d)", .voltage, sampleValues(count: 5, seed: 0.0))]
    ))
    state.injectForTests(documents: [a, b, c, d])
    #expect(state.hubTitle == "alpha.tr0, beta.tr0, +2 more")
}

// MARK: - Close document

@MainActor
@Test func closingDocumentPrunesReferencesToIt() {
    let state = makeState()
    let a = LoadedDocument(document: makeDocument(
        title: "A",
        signals: [("v(clk)", .voltage, sampleValues(count: 10, seed: 0.0))]
    ))
    let b = LoadedDocument(document: makeDocument(
        title: "B",
        signals: [("v(clk)", .voltage, sampleValues(count: 10, seed: 0.0))]
    ))
    state.injectForTests(documents: [a, b])

    let refA = SignalRef(document: a.id, local: 0)
    let refB = SignalRef(document: b.id, local: 0)
    state.setSignalChecked(refA, checked: true)
    state.setSignalChecked(refB, checked: true)
    state.focusedSignalRef = refA
    let gateA = HierarchyKey(document: a.id, fullPath: "")
    state.setGateOpen(gateA, open: false)

    state.closeDocument(a.id)

    #expect(state.documents.count == 1)
    #expect(state.documents[0].id == b.id)
    #expect(state.fileNodes.count == 1)
    #expect(state.checkedSignals == [refB])
    #expect(state.focusedSignalRef == nil)
    // The gate for the closed doc has been pruned.
    #expect(state.gateOff.contains(gateA) == false)
}

@MainActor
@Test func closingLastDocumentResetsViewportAndCursor() {
    let state = makeState()
    let only = LoadedDocument(document: makeDocument(
        title: "Only",
        signals: [("v(a)", .voltage, sampleValues(count: 10, seed: 0.0))]
    ))
    state.injectForTests(documents: [only])
    state.cursorTimeX = 42
    state.sharedState.viewportX = 10...80

    state.closeDocument(only.id)

    #expect(state.documents.isEmpty)
    #expect(state.fileNodes.isEmpty)
    #expect(state.cursorTimeX == nil)
    #expect(state.sharedState.viewportX == nil)
}

// MARK: - Unit routing

@MainActor
@Test func effectiveVisibleSignalsFiltersByUnitAndPreservesZOrder() {
    let state = makeState()
    let loaded = LoadedDocument(document: makeDocument(
        title: "A",
        signals: [
            ("v(first)",  .voltage, sampleValues(count: 10, seed: 0.0)),
            ("i(middle)", .current, sampleValues(count: 10, seed: 1.0)),
            ("v(second)", .voltage, sampleValues(count: 10, seed: 0.5)),
            ("p(pwr)",    .power,   sampleValues(count: 10, seed: 2.0)),
        ]
    ))
    state.injectForTests(documents: [loaded])

    let refV1 = SignalRef(document: loaded.id, local: 0)
    let refI  = SignalRef(document: loaded.id, local: 1)
    let refV2 = SignalRef(document: loaded.id, local: 2)
    let refP  = SignalRef(document: loaded.id, local: 3)
    state.setSignalChecked(refV1, checked: true)
    state.setSignalChecked(refI,  checked: true)
    state.setSignalChecked(refV2, checked: true)
    state.setSignalChecked(refP,  checked: true)

    #expect(state.effectiveVisibleSignals(unit: .voltage) == [refV1, refV2])
    #expect(state.effectiveVisibleSignals(unit: .current) == [refI])
    #expect(state.effectiveVisibleSignals(unit: .power)   == [refP])
    #expect(state.visibleUnits() == [.voltage, .current, .power])
}

// MARK: - Duplicate file detection

@MainActor
@Test func openingSameFileTwiceIsDedupedWithError() throws {
    // Use the bundled fixture so we're hitting the real WaveformDocument.load
    // code path instead of the test-only inject seam.
    let state = makeState()
    guard let fixture = Bundle.module.url(
        forResource: "lfsr9-flat",
        withExtension: "tr0",
        subdirectory: "Fixtures"
    ) else {
        Issue.record("missing lfsr9-flat.tr0 fixture")
        return
    }

    state.open(urls: [fixture])
    #expect(state.documents.count == 1)
    #expect(state.loadError == nil)

    // Second open of the same URL should be skipped and report the dupe
    // in loadError without touching the existing document.
    let firstID = state.documents[0].id
    state.open(urls: [fixture])
    #expect(state.documents.count == 1)
    #expect(state.documents[0].id == firstID)
    #expect(state.loadError != nil)
    #expect(state.loadError?.contains("already open") == true)

    // Closing the document should free its slot so a subsequent open of
    // the same URL succeeds again.
    state.closeDocument(firstID)
    #expect(state.documents.isEmpty)
    state.open(urls: [fixture])
    #expect(state.documents.count == 1)
    #expect(state.documents[0].id != firstID)  // freshly-minted DocumentID
    #expect(state.loadError == nil)
}

// MARK: - Session snapshot round-trip

@MainActor
@Test func snapshotRoundTripPreservesFilesSignalsAndColors() throws {
    let state = makeState()
    guard let fixture = Bundle.module.url(
        forResource: "lfsr9-flat",
        withExtension: "tr0",
        subdirectory: "Fixtures"
    ) else {
        Issue.record("missing lfsr9-flat.tr0 fixture")
        return
    }

    state.open(urls: [fixture])
    #expect(state.documents.count == 1)

    let firstSignal = state.documents[0].signals[0]
    let firstRef = SignalRef(document: state.documents[0].id, local: firstSignal.id)
    state.setSignalChecked(firstRef, checked: true)
    state.setCustomColor(
        NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1),
        for: firstRef
    )

    let snapshot = state.makeSnapshot()
    #expect(snapshot.openFiles.count == 1)
    #expect(snapshot.selectedSignals.count == 1)
    #expect(snapshot.selectedSignals[0].displayName == firstSignal.displayName)
    #expect(snapshot.customColors.count == 1)
    #expect(abs(snapshot.customColors[0].red - 0.25) < 1e-4)
    #expect(abs(snapshot.customColors[0].green - 0.5) < 1e-4)
    #expect(abs(snapshot.customColors[0].blue - 0.75) < 1e-4)

    // Round-trip via JSON to make sure SessionSnapshot is fully Codable.
    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: encoded)
    #expect(decoded == snapshot)

    // Wipe state, then apply the decoded snapshot. Files reload, the
    // checked signal comes back, and the color override is restored —
    // even though the freshly-minted DocumentID is different from the
    // first round.
    let originalDocID = state.documents[0].id
    state.applySnapshot(decoded)
    #expect(state.documents.count == 1)
    #expect(state.documents[0].id != originalDocID)
    #expect(state.checkedSignals.count == 1)
    let newRef = state.checkedSignals[0]
    #expect(state.resolve(newRef)?.displayName == firstSignal.displayName)
    let restoredColor = state.customColors[newRef]
    #expect(restoredColor != nil)
    #expect(abs((restoredColor?.red ?? 0) - 0.25) < 1e-4)
}

// MARK: - Test-only helper

@MainActor
extension WaveformAppState {
    /// Bypass `open(urls:)` so unit tests can seed documents without hitting
    /// the disk. Rebuilds the parallel `fileNodes` array so every visibility
    /// and gate helper works the same way as in production loads.
    fileprivate func injectForTests(documents: [LoadedDocument]) {
        // Mirror WaveformAppState.open(urls:) minus the parse step.
        // We need to splat to private(set) vars via a test hook; use
        // `withUnsafeMutablePointer` is overkill, prefer wrapping via
        // an internal setter. Instead, we hand-assemble the state by
        // delegating to the open() code path's post-parse work.
        self.testResetDocuments(documents)
    }
}
