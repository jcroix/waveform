# Waveform

A Mac-native SPICE waveform viewer for [OmegaSim](https://github.com/nascentric/omegasim)
simulation output. Built as a replacement for viewing OmegaSim results in
GNUplot — interactive, polished, and native to macOS.

## Status

Early development. The full implementation plan lives in
`.claude/plans/agile-discovering-bentley.md` (not checked in). Day-one targets:

- `.tr0` — HSPICE-compatible binary transient output from OmegaSim
- `.out` — the OmegaSim output listing (run log with embedded waveform tables)

Everything beyond loading, browsing, and interactive plot/pan/zoom is deferred
to v2: trace arithmetic, measurements, run comparison, FFT, AC/DC views, dual
cursors, `.fsdb`, and VCD.

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 6.0 toolchain (ships with Xcode 16)

## Build

```sh
swift build
swift test
swift run WaveformViewer
```

A proper `.app` bundle with code signing and notarization will be produced via
an Xcode project added later; for now the package runs directly from the
command line.

## Supported input formats

### `.tr0` — HSPICE-compatible binary

OmegaSim's `wTrZeroWriter` emits a binary transient-output format that follows
the HSPICE TR0 layout (16-byte block headers, ASCII run-info record, waveform
ID and name records, `$&%#    ` trailer, data blocks of
`(time, v0, v1, …)` tuples with 2048-sample sub-blocks).

**Endianness note.** Canonical HSPICE TR0 is big-endian (the format originated
on Sun workstations). OmegaSim's current writer uses native `fwrite`, which on
Apple Silicon and Intel Macs produces little-endian output — technically
non-conforming. This viewer auto-detects byte order from the fixed header
sentinels (`mI0 == 4`, `mI1 == 4`) so it will read both the current
little-endian OmegaSim output and any future spec-compliant big-endian output
without a user-visible switch.

A follow-up on the nascentric side should update `wTrZeroWriter.cpp` to emit
big-endian fields explicitly; this viewer will continue to read both.

### `.out` — OmegaSim output listing

The complete human-readable simulation listing: banner, info lines, `Title:`,
element counts, option settings (including `NASC_HIERID` for the hierarchy
separator), analysis-status messages, one or more `x`/`y`-framed columnar
waveform tables, and a footer with timing stats and success/failure lines.
The viewer parses this as a full listing (not just the columnar block), picks
up the declared hierarchy separator, and tags each waveform block with its
analysis type.

## GUI inspiration

Layout and interaction patterns are drawn from commercial waveform viewers
only — Cadence ViVA, Synopsys Custom WaveView, Mentor/Siemens EZwave, and
Keysight ADS Data Display. Freeware viewer patterns are out of scope as
design references.

## License

TBD.
