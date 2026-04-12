# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Mac-native SPICE waveform viewer for OmegaSim simulation output, replacing the user's GNUplot workflow. Swift Package targeting macOS 14+ with the Swift 6 toolchain. The circuit simulator whose outputs we read lives outside this repo at `/Users/jcroix/programs/nascentric`.

## Commands

```sh
swift build                          # compile
swift test                           # run all tests
swift test --filter <test-name>      # run a single Swift Testing @Test by name
./scripts/make-app.sh [debug|release] # build a proper .app bundle (debug by default)
open .build/debug/WaveformViewer.app  # launch the bundled app
```

### Always launch via the `.app` bundle, not `swift run`

`swift run WaveformViewer` *technically* works, but on macOS 14+ it launches an un-bundled Mach-O executable with no `Info.plist`. Without the bundle, macOS falls into degraded windowing behavior (no dock icon, no focus, `NSOpenPanel` loses focus on click, elevated WindowServer CPU because the process isn't registered as a regular application). `scripts/make-app.sh` wraps the compiled binary in an `.app` with the minimal `Info.plist` keys macOS actually wants (`NSHighResolutionCapable`, `NSPrincipalClass`, `CFBundleIdentifier`, `NSSupportsAutomaticGraphicsSwitching`). Prefer it.

`AppDelegate.applicationDidFinishLaunching` also calls `NSApp.setActivationPolicy(.regular)` + `NSApp.activate(ignoringOtherApps:)` as a safety net so the process still behaves like a foreground app even if someone does launch via `swift run`.

### Do NOT reintroduce `.toolbar` on the main window

On macOS 26.x (observed on Darwin 25.4 with Swift 6.3), attaching any `.toolbar { … }` to the main window — even a single `ToolbarItem { Button("Open") { … } }` with no SF Symbol and no placement override — pegs `WindowServer` at 30–50% CPU at idle, presumably because of continuous window-chrome compositing. The main window deliberately has **no toolbar**; the File → Open command is wired via `WaveformViewerApp.commands` (⌘O) and the empty-state `ContentUnavailableView` in `MainWindow.swift` carries an in-content "Open…" button so there is still a visible affordance. This was bisected by stripping `MainWindow` to a minimal view and progressively adding pieces back. If you find yourself wanting to add a toolbar, re-test WindowServer CPU with `top` first and revert if it spikes.

## Architecture

### Two parsers, one document

`.tr0` and `.out` files flow through independent parsers that both produce `WaveformDocument` — the source-agnostic in-memory model the UI consumes. Entry point: `WaveformDocument.load(from: URL)` dispatches on extension.

- **`TR0Parser`** (binary) — a direct Swift port of `ausim/new-src/waveform/wTrZeroReader.cpp` in the nascentric repo. That C++ reader and its writer counterpart `wTrZeroWriter.cpp` are the **ground truth** for the binary format. When the TR0 parser breaks or the format evolves, re-read those rather than guessing from hex dumps.
- **`ListingParser`** (text `.out`) — a full finite-state scanner, not just a columnar reader. It walks the listing top-to-bottom: banner → info → `Title:` → element counts → option settings → analysis-status messages → one or more `x`/`y`-framed waveform tables → footer. The `NASC_HIERID` option drives the hierarchy separator for this specific file, and `NASC_OUTFORMAT` indicates whether waveforms are embedded (`"TXT"`) or in a sibling `.tr0` (`"tr0"`, no embedded block).

### Byte-order auto-detection (defensive parsing principle)

Canonical HSPICE TR0 is **big-endian** (Sun workstation heritage). OmegaSim's current writer uses native `fwrite` which produces **little-endian** on Macs — technically non-conforming. The parser must read both, and any future nascentric-side fix to emit spec-compliant big-endian files must not require a viewer change.

`TR0Parser.detectByteOrder` probes the first 16 bytes and picks whichever interpretation makes both `mI0 == 4` and `mI1 == 4` validate. That `ByteOrder` is then stored on the `BinaryReader` instance and every `int32`/`float32` read flows through that one helper. **There is no stray native-endian read anywhere in the parser.** `TR0ParserTests.syntheticRoundTrip` builds a minimal TR0 from scratch in both byte orders and asserts they parse identically.

General rule for this project: when parsing formats produced by in-house tools, don't hardcode assumptions that happen to match the current writer's output. Probe fixed sentinels, treat the upstream spec as authoritative, and design for the case where the writer gets fixed later.

### Listing → TR0 auto-discovery

When `.out` has `NASC_OUTFORMAT = "tr0"` (listing-only, no embedded `x`/`y` blocks), `WaveformDocument.loadListing` auto-discovers the sibling `.tr0` with matching basename in the same directory, loads waveforms from it, keeps the `.out` as the user-visible `sourceURL`, and uses the listing's title (more authoritative than TR0's 64-char-truncated title field). If the sibling is missing, parsing fails cleanly with a message pointing at the expected filename.

### Signal tree

`HierarchyNode` is a recursive `final class` — reference semantics are required because `NSOutlineView` uses object identity for its items. Two static entry points:

- `HierarchyNode.build(signals:separator:)` — immutable tree. Siblings use `localizedStandardCompare` so `net2` sorts before `net10`. Interior nodes can also carry their own `signalID` when a probe exists on both a subcircuit instance and signals beneath it.
- `HierarchyNode.filter(_:matching:)` — subset tree keeping matching nodes plus all their ancestors. Empty needle returns the original tree **by reference identity** (preserving NSOutlineView state in the no-op case).

Signal display names like `v(x1.x2.net)` run through `parseSignalName(displayName:separator:)`, which strips the outer `v(` / `i(` / `p(` wrapper and splits the inner path on the hierarchy separator. Separator comes from the listing's `NASC_HIERID` when available, otherwise defaults to `.`.

Signal-kind classification looks at different signals in each parser: `ListingParser` uses the column's unit (`V`/`A`/`W`/`L`), while `TR0Parser` combines the `"  1     "` / `"  8     "` typeCode with the display-name prefix since type 1 covers both `VOLTAGE` and `LOGIC_VOLTAGE`.

### UI layer

- `ViewerState` (`@Observable @MainActor`) owns the current document, filter text, selected signal ID, and load error. One instance per window scene.
- `SignalSidebar` → `SignalOutlineView` wraps `NSOutlineView` via `NSViewRepresentable`. SwiftUI `OutlineGroup` is **intentionally not used** — it scales quadratically and SPICE circuits routinely have thousands of signals. Uses `NSTableView.style = .sourceList` (the non-deprecated form), not the older `selectionHighlightStyle = .sourceList`.
- GUI idioms in this project are drawn **only from commercial waveform viewers** — Cadence ViVA, Synopsys Custom WaveView, Mentor/Siemens EZwave, Keysight ADS. Freeware viewers (LTSpice, GTKWave, PulseView, Saleae) are explicitly out of scope as design references per the user's guidance.

### Plot panel

`PlotNSView` is a layer-backed `NSView` wrapped by `PlotView` (`NSViewRepresentable`). The layer stack, bottom → top:

1. **view root layer** — background fill, separator border
2. **`traceContainer`** — `frame = plotArea` (after margin insets), `masksToBounds = true`. Children are reused `CAShapeLayer`s, one per visible signal, with paths in plot-area-local coordinates.
3. **`axisLayer`** (zPosition = 1, delegate-drawn via `CALayerDelegate.draw(_:in:)`) — draws axis borders, tick marks, and engineering-notation tick labels via Core Text.

Placing the axis layer above the trace container via zPosition means tick marks and labels cannot be overdrawn by waveform data, which was an explicit user requirement.

**Critical performance invariants** (the view was observed pegging WindowServer at 100%+ CPU before these fixes landed):

- Trace layers are **reused** across rebuilds via a pool; only `.path` and `.strokeColor` are updated in place. Recreating `CAShapeLayer`s every rebuild invalidates CA's rasterization cache and forces WindowServer to re-rasterize the full polyline on every composite.
- Each trace layer has **`shouldRasterize = true`** with `rasterizationScale = backingScaleFactor`. CA rasterizes the polyline once into an offscreen bitmap and composites the cached bitmap on subsequent frames.
- A `RebuildKey` (source URL + sample count + signal IDs + bounds size) guards `rebuildIfNeeded()`. Layout passes and SwiftUI `updateNSView` calls that don't change any input return immediately without touching any layer.
- Implicit CA animations are suppressed at every mutation point: `actions = ["path": NSNull(), "strokeColor": NSNull(), …]` on every shape layer, `CATransaction.setDisableActions(true)` around every rebuild.
- Dynamic system colors on the root layer and axis labels are re-resolved inside `effectiveAppearance.performAsCurrentDrawingAppearance { … }` on `viewDidChangeEffectiveAppearance`, and `lastRebuildKey` is cleared so the dedupe cache doesn't short-circuit that rebuild.

**Pure utilities used by the plot panel** (all unit-tested in isolation):

- `EngFormat.format(_:unit:)` — engineering-notation formatter (f, p, n, µ, m, k, M, G, T) with 3 significant digits and trailing-zero stripping. Used for both time (`"50 ns"`) and value (`"-2.5 mA"`) labels.
- `AxisTicks.niceTicks(min:max:target:)` — "nice number" tick generator via the 1-2-5 rounding rule (Heckbert). Returns a sorted list of tick positions covering the inclusive range.
- `ColorPalette.color(for: SignalKind)` — kind-based trace color for single-trace plots (voltage=yellow, current=blue, …) so the plot matches the sidebar icon tint. `ColorPalette.color(forTraceIndex:)` is a round-robin palette reserved for multi-trace layouts arriving in Phase 9+.

## Test fixtures

`Tests/WaveformViewerTests/Fixtures/` contains `lfsr9-flat.tr0` and `lfsr9-flat.out`, both from the same LFSR9 simulation run (3 voltages + `i(vdd)`). The `.out` is in `NASC_OUTFORMAT = "TXT"` mode with embedded waveforms. Both come from `/Users/jcroix/programs/nascentric/test/lfsr9/lfsr9-flat/`; regenerate by re-running OmegaSim there.

Tests cross-validate the two parsers against each other on this fixture: identical sample counts, probe names, and spot-checked values agree within 0.1% (listing has 4–5 significant figures, TR0 is full float32).

Fixtures are accessed via `Bundle.module.url(forResource:withExtension:subdirectory: "Fixtures")`. This works because `Package.swift` declares `.copy("Fixtures")` on the test target — if a new fixture subdirectory is added, that declaration may need updating.

## Testing framework

This project uses **Swift Testing** (`import Testing`), not XCTest. Tests are `@Test` functions with `#expect(...)` assertions, parameterized via `@Test(arguments: ...)`, and soft failures via `Issue.record(...)`. Don't add XCTest-style `XCTestCase` subclasses.

## Ground-truth references outside this repo

When working on parser correctness or format quirks, these are the authoritative sources:

- `/Users/jcroix/programs/nascentric/ausim/new-src/waveform/wTrZeroReader.{h,cpp}` — TR0 reader to port from
- `/Users/jcroix/programs/nascentric/ausim/new-src/waveform/wTrZeroWriter.{h,cpp}` — TR0 writer for byte-layout cross-checks
- `/Users/jcroix/programs/nascentric/ausim/new-src/waveform/wTextWriter.{h,cpp}` — `.out` text writer
- `/Users/jcroix/programs/nascentric/ausim/new-src/waveform/wWaveform.h` — `WaveformType` enum (`VOLTAGE` / `CURRENT` / `POWER` / `LOGIC_VOLTAGE`)
- `/Users/jcroix/programs/nascentric/test/lfsr9/lfsr9-flat/` — canonical test circuit
