# TR0 binary format — as implemented by the Waveform viewer

This document describes the `.tr0` (HSPICE "post" binary) format as it is
actually parsed by `Sources/WaveformViewer/Parsers/TR0Parser.swift`. It is
not the canonical HSPICE specification — it is a reverse-engineered
description that reflects (a) what Nascentric's `wTrZeroWriter.cpp` writes,
(b) what real HSPICE-lineage files from `gwave` and `HMC-ACE/hspiceParser`
contain, and (c) what this viewer's parser successfully reads.

The target audience is whoever next has to modify the TR0 parser. Read this
before touching `TR0Parser.swift` or re-deriving the byte layout from a hex
dump.

## Sources

- `/Users/jcroix/programs/nascentric/ausim/new-src/waveform/wTrZeroWriter.cpp`
  — authoritative for what OmegaSim emits.
- `/Users/jcroix/programs/nascentric/ausim/new-src/waveform/wTrZeroReader.cpp`
  — the reference reader the Swift parser was originally ported from.
- `third-party-tr0-samples/gwave/` and `third-party-tr0-samples/hmc-ace/` —
  sample files from [l-chang/gwave](https://github.com/l-chang/gwave) and
  [HMC-ACE/hspiceParser](https://github.com/HMC-ACE/hspiceParser). These are
  the non-Nascentric dialect reference files. gwave's parser source
  (`spicefile/ss_hspice.c`) and its doc (`doc/hspice-output.txt`) document
  the older "post" format from a reader's perspective.

## High-level layout

A TR0 file is a sequence of **blocks**. Each block is a 16-byte header +
payload + 4-byte checksum, where the header encodes the payload's byte
count. The parser does not seek — it walks blocks in order.

```
┌─────────────────┐
│ Header block    │  block 0: ASCII run-info (title, counts, names, types)
├─────────────────┤
│ Data block 1    │  block 1..N: float32 waveform data, 8 KiB payloads
├─────────────────┤
│ Data block 2    │
├─────────────────┤
│ …               │
├─────────────────┤
│ Data block N    │  last block contains an end-of-table marker
└─────────────────┘
```

### Block framing

Every block has this structure:

| Offset | Size | Content |
|---|---|---|
| 0 | int32 | `mI0 = 4` (sentinel; always decimal 4) |
| 4 | int32 | redundant item count (unused by the parser) |
| 8 | int32 | `mI1 = 4` (sentinel; always decimal 4) |
| 12 | int32 | payload size in bytes |
| 16 | payloadSize | block payload |
| 16+payloadSize | int32 | block checksum = `payloadSize` (not a real hash) |

The `mI0`/`mI1` pair is what disambiguates byte order. In a correctly
formed file both must decode as decimal `4`; if `little-endian` gives
`mI0 = 0x04000000 ≠ 4` and `big-endian` gives `mI0 = 4`, the file is
big-endian. The parser tries little-endian first, then big-endian, and the
chosen `ByteOrder` is then used for every subsequent `int32`/`float32` read.

**There is no stray native-endian read anywhere in the parser.** Every
integer and float goes through `BinaryReader.readInt32` / `readFloat32`,
which apply the byte order.

### Endianness in the wild

| Source | Endianness of samples seen |
|---|---|
| OmegaSim `wTrZeroWriter.cpp` | **little-endian** (native `fwrite`, Apple Silicon + Intel) |
| gwave examples | **big-endian** (canonical HSPICE, Sun heritage) |
| HMC-ACE samples | **little-endian** |

Real HSPICE historically wrote big-endian because it originated on Sun
workstations; OmegaSim's native-fwrite output is technically non-conforming
but happens to be what third parties on little-endian hosts now emit too.
The auto-detect covers both. A future patch to `wTrZeroWriter.cpp` could
byte-swap to big-endian without breaking this viewer.

## Header block payload

The header block's payload (the bytes between its 16-byte block header and
its 4-byte block checksum) is an ASCII-framed region with fixed field
offsets. Every field in this section is printable ASCII padded with spaces.

The payload is structured as **fixed fields**, then a **variable region** of
waveform type codes and names, terminated by an 8-byte `"$&%#    "` trailer.

### Fixed fields

| Offset in payload | Size | Field | Semantics |
|---|---|---|---|
| 0 | 4 | `nauto` | ASCII int — count of "automatic" variables. Whose definition of this is which determines how the total slot count is computed; see below. |
| 4 | 4 | `nprobe` | ASCII int — count of user-added probes (`.probe` / `.print`). |
| 8 | 4 | `nsweep` | ASCII int — sweep parameter count (0 in most files). |
| 12 | 4 | reserved | writer-specific; parser ignores. |
| 16 | 8 | version | `"9601    "` (Nascentric, gwave) or `"00002001"` (HMC-ACE 2001) — ASCII; parser reads and discards. |
| 24 | 64 | title | ASCII space-padded title string. Nascentric uses a strict 64-byte slot; gwave extends with 8 bytes of trailing padding (effectively 72 bytes) but since Nascentric's date slot starts at byte 104 and gwave's date starts at byte 112, the 8-byte overlap lands cleanly in the date slot's leading-space region and parses correctly either way. |
| 88 | 16 | date | `"MM/DD/YYYY"` (Nascentric) or `"MM/DD/YY"` with extra leading spaces (gwave). Parser trims whitespace. |
| 104 | 8 | time | `"HH:MM:SS"`. |
| 112 | 72 | copyright | ASCII; parser ignores. |
| 184 | 80 | sweep-info | 4B sweep count + 76B padding; parser reads and discards as a raw blob. |

All offsets above are **within the header block's payload**, not within the
file. Add 16 to get absolute file offsets, since the file starts with the
header block's own 16-byte header.

### Count field semantics — the thing that caught us

The first two 4-byte ASCII ints (`nauto` and `nprobe`) use different
semantics in different dialects, but **the sum is universal**:

**Total waveform ID slots = `nauto + nprobe`.**

- **gwave / HMC-ACE / real HSPICE dialect:** `nauto` includes the
  independent variable (TIME). Example: 4 voltage probes + 1 current probe
  + TIME → `nauto = 6`, `nprobe = 0`, total slots = 6.
- **Nascentric dialect (OmegaSim):** `wTrZeroWriter.cpp` writes
  `nauto = probes.size()` (does **not** include TIME) and hardcodes
  `nprobe = 1` literally. Example: 4 voltage probes + 1 current probe + TIME
  → `nauto = 5`, `nprobe = 1`, total slots = 6.

Both produce the same total-slot count, and both are written/read
byte-identically. The parser does not need to know which dialect it's
reading — it just computes `totalIds = nauto + nprobe`.

A previous version of this parser hardcoded `totalIds = nauto + 1`, which
"worked" for Nascentric files because `nprobe` was always literal `1`, but
broke immediately on any gwave or HMC-ACE file with a non-`1` `nprobe`
field (e.g., `quickINV.tr0` has `nauto=7, nprobe=2, total=9`). Do not
reintroduce this bug.

### Variable region: type codes, names, trailer

Immediately after the fixed fields (payload byte offset 264 onward):

1. **Waveform type codes** — `totalIds × 8` bytes. Each slot is 8 ASCII
   bytes containing a decimal integer, space-padded. The first slot is
   always the independent variable (TIME, which has type `1` for transient
   analysis). Subsequent slots are the dependent variables' types.

   Observed type codes:

   | Code | Meaning |
   |---|---|
   | 1 | Voltage or TIME (analysis type for the independent var) |
   | 2 | Voltage in AC analysis |
   | 8 | Current |
   | 15 | Current (sometimes) |
   | 22 | Current (sometimes) |

   The parser keeps type codes 1 and 8 directly (mapping them to V/I); the
   others are carried through and classified downstream based on the name
   prefix (`v(`, `i(`, `p(`).

2. **Waveform names** — a variable-length region containing one padded name
   per waveform, in the same order as the type codes. Each name's byte
   allocation is the smallest multiple of 16 that strictly exceeds the raw
   name length, so the final byte of every name's allocation is guaranteed
   to be a space:

   ```
   rawLen = 4  → 16-byte slot ("time            ")
   rawLen = 15 → 16-byte slot
   rawLen = 16 → 32-byte slot
   rawLen = 17 → 32-byte slot
   ```

   The parser walks the region in 16-byte chunks; a chunk whose last byte
   is a space terminates the current name.

   First name is always the independent variable. Nascentric writes it as
   `"time"` (lowercase); gwave/HMC-ACE write it as `"TIME"` (uppercase).
   Parser is case-insensitive downstream. Nascentric lowercases all other
   names too; third-party files preserve case.

   **Closing-paren quirk.** Real HSPICE binary writers (gwave, HMC-ACE, and
   every third-party sample we've seen) consistently omit the trailing `)`
   from probe names — `v(out)` is stored as `v(out`, `i(r2)` as `i(r2`,
   and so on. The 16-byte name slot has plenty of room; this is a writer
   idiosyncrasy, not truncation. Nascentric's `wTrZeroWriter.cpp` writes
   the closing paren explicitly. `TR0Parser.normalizeProbeName` adds a `)`
   to any name that contains `(` but is missing `)`, so downstream code
   sees uniform `v(name)` / `i(name)` / `p(name)` strings regardless of
   source dialect. Names without any `(` (e.g. `TIME`, numeric node names
   like `0`, `1`, `2`) are passed through unchanged.

3. **Trailer** — exactly 8 bytes: `"$&%#    "` (four literal characters
   `$&%#` followed by four spaces). This sentinel terminates the header
   block payload. The parser checks for it and throws `invalidHeader` if
   absent.

The **size of the name region** is computed implicitly:

```
nameRegionSize = headerPayloadSize - 264 - (totalIds * 8) - 8
```

and must be nonnegative and divisible by 16. If it isn't, either the
`totalIds` computation is wrong or the file is a dialect this parser
doesn't handle. The alignment check is a useful structural sanity signal.

## Data blocks

Every block after the header block is a data block containing `float32`
waveform samples.

### Block framing (same as header block)

```
┌──────────────┐
│ 16B header   │  mI0=4, count, mI1=4, payloadSize
├──────────────┤
│ payload      │  float32 samples, row-interleaved
├──────────────┤
│ 4B checksum  │  = payloadSize
└──────────────┘
```

### Row interleaving

The data section is a flat stream of `float32`s in row-major order. Each
row has `totalIds` (=`nauto + nprobe`) floats:

```
[time₀, probe1₀, probe2₀, ..., probeN₀,
 time₁, probe1₁, probe2₁, ..., probeN₁,
 ...]
```

The parser keeps a running `tupleIndex` modulo `totalIds`. Index 0 is
the time column; indices 1..N fill the probe arrays in slot order. A row
can span a sub-block boundary because the block size is fixed at 8 KiB
regardless of row width; the parser's modulo state naturally stitches
partial rows across block boundaries.

### Sub-block payload size

Nascentric writes sub-blocks with a payload of up to 8192 bytes (2048
floats, `gSubblockSize = 8192` in `wTrZeroWriter.cpp`). gwave/HMC-ACE
files also use 8192-byte payloads in practice. The final data block is
short; it holds only as many rows as remain plus the end-of-table marker
(see below).

### End-of-data markers — TWO flavors, both supported

The parser recognizes **both** HSPICE-canonical and Nascentric-custom
end-of-data markers.

**1. HSPICE-canonical in-band marker** (used by gwave, HMC-ACE, real HSPICE)

The very first float of a row at the time-column position is set to a
large positive value (historically `1e31`, sometimes written as
`+infinity`). When the parser sees `tupleIndex == 0 && value >= 1e29`, it
treats that float and everything after it in the current block payload as
garbage, skips to the end of the block, and stops reading. This matches
what `gwave/spicefile/ss_hspice.c` does:

```c
if(*ivar >= 1.0e29) { /* "infinity" at end of data table */
    sf->read_tables++;
    if(sf->read_tables == sf->ntables)
        return 0; /* EOF */
```

**2. Nascentric tail sentinel**

Nascentric's writer appends the four-byte magic pattern `0xca 0xf2 0x49
0x71` as the last 4 bytes of the **final** sub-block's payload (written by
`gDataBlockTerminator` in `wTrZeroWriter.cpp`). To avoid false positives
on random float bit patterns that might look the same, the parser also
requires the file to end exactly 8 bytes past the sentinel (4-byte
checksum plus EOF).

Both markers share one outer loop; whichever fires first sets
`sawTerminator` and exits.

## Post-conditions the parser enforces

After reading all data blocks:

- `tupleIndex` must equal `0` — i.e., every row that was started was also
  completed (no partial trailing row).
- Every probe array must have the same length as `timeValues`.
- `probeNames.count == probeCount` and `typeCodes.count == probeCount`,
  where `probeCount = totalIds - 1` (non-time columns).

If any of these fail, the parser throws a specific error (see
`ParseError` cases `truncatedDataBlock`, `inconsistentProbeLength`,
`invalidHeader`).

## Compatibility notes

### Dialects this parser reads

| Writer | Endian | Nauto semantics | Marker |
|---|---|---|---|
| OmegaSim `wTrZeroWriter.cpp` | little | `probes.size()`, nprobe=1 literal | `0xca f2 49 71` tail |
| gwave examples (real HSPICE 9601) | big | includes TIME, real nprobe | time ≥ 1e29 |
| HMC-ACE 9601 samples | little | includes TIME, real nprobe | time ≥ 1e29 |
| HMC-ACE 2001 samples | little | includes TIME, real nprobe | time ≥ 1e29 |

All four decode to the same `TR0Document` shape.

### Things this parser does NOT handle

- **ASCII/post=2 TR0** — files written by HSPICE with `.options POST=2`.
  These are text files with fixed-width columns and use version `9007` or
  `9601` but no binary block framing. `gwave/examples/tlong.tr0.9601` is
  one such file; it fails the `mI0==4, mI1==4` sniff in `detectByteOrder`.
- **AC analysis (`.ac0`)** — format shares the header layout but data
  section has real+imag pairs per frequency point. Type codes 2, 9, 10, 11
  indicate AC components. This viewer is transient-only for v1.
- **Sweep parameters** — when `nsweep > 0`, the data section is preceded
  by sweep-parameter floats per sub-table. Parser skips `nsweep` as a raw
  byte blob and does not emit sweep info. Multi-table DC sweeps will
  decode incorrectly.
- **`$&%#` mid-block splits for long names** — if a name longer than 15
  bytes is split across a sub-block boundary in the header region, some
  writers handle this specially. Neither Nascentric nor the sample files
  exhibit this, so the parser does not try.

### The HMC-ACE doc disagrees with reality

HMC-ACE's `hSpice_output.md` describes a "variable-width header with an
asterisk separator after the version descriptor and whitespace-separated
date/time/copyright/variable names". **This description does not match
even HMC-ACE's own sample files**, which use the same fixed-byte-offset
layout as Nascentric and gwave (the asterisk, when it appears, is part of
the title content at offset 40, not a structural separator). Do not trust
that doc for field layout — trust this document, `wTrZeroWriter.cpp`, and
the sample files instead.

## When this document gets stale

Any time the parser is modified to accept a new dialect, update the
"Dialects this parser reads" table and the relevant section (header
fields, data blocks, or markers). Any time `wTrZeroWriter.cpp` changes,
re-verify the "Nascentric dialect" column and the offset table.

The five files in `third-party-tr0-samples/` plus the Nascentric fixture
at `Tests/WaveformViewerTests/Fixtures/lfsr9-flat.tr0` together exercise
every dialect path the parser supports; if a change to the parser breaks
any of them, it's a regression.
