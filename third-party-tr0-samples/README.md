# Third-party TR0 sample files

**Unknown provenance — do not mix with `Tests/WaveformViewerTests/Fixtures/`.**

These files were downloaded from third-party public repositories and are kept
segregated from the Nascentric-origin fixtures in the test target. They exist
so the waveform viewer can be manually exercised against files produced by
writers other than OmegaSim, to find out which ones the parser reads correctly
and which reveal real dialect differences.

None of these files are loaded by the unit tests. See the root
[`README.md`](../README.md) for how to build and launch the app, then open
each file manually via `File → Open…` (⌘O). The app does not yet register a
document type with Launch Services, so passing the file as an argument to
`open` will not work — you have to open it from inside the running app.

```sh
./scripts/make-app.sh
open .build/debug/WaveformViewer.app
# then ⌘O, navigate to third-party-tr0-samples/…
```

## Source repositories

- `gwave/` — from <https://github.com/l-chang/gwave>, GPL v2 or later.
  Specifically from `examples/` at the repo root.
- `hmc-ace/` — from <https://github.com/HMC-ACE/hspiceParser>, MIT license.
  Specifically from `test/` at the repo root.

Neither of these projects is a Nascentric product and there is no reason to
trust that their files match what OmegaSim writes. That's the point of keeping
them quarantined: when the viewer fails on one of them, that failure tells us
about dialect divergence, not about an OmegaSim bug.

## What's in each file

Header bytes inspected directly with `xxd`. All five binary files use a
fixed-byte count prefix (`nauto`/`nprobe`/`nsweepparam` as 4-digit ASCII ints at
file offsets 0–11) followed by a version tag at offset 16 of the ASCII data
area, which is the same family as Nascentric's layout. The dialect differences
show up in what comes *after* the version tag.

### `gwave/`

| File | Size | Format | Endian | `nauto`/`nprobe`/`nsweep` | Version | Notes |
|---|---|---|---|---|---|---|
| `quickINV.tr0` | 1.8K | binary | **big-endian** | 7/2/0 | `9601` | `"9601    inverter"` — 4 spaces then title, **no asterisk** |
| `quickTRAN.tr0` | 2.6K | binary | **big-endian** | 5/4/0 | `9601` | `"9601    a simple"` — same no-asterisk layout |
| `test1.tr0.binary` | 1.9K | binary | **big-endian** | 1/3/0 | `9601` | `"9601            "` — no title |
| `tlong.tr0.9601` | 3.6K | ASCII | n/a | — | `9601` | **ASCII post=2 output**, not binary — starts with `00010002...` |

All three gwave binary files are big-endian, which is the canonical HSPICE byte
order (Sun workstation heritage). This is the first time the viewer's byte-order
auto-detect code path will be exercised against real files — my parser should
decode these correctly by sniffing `mI0 == 4, mI1 == 4` in both interpretations
and picking big-endian.

`tlong.tr0.9601` is not a binary file — it's the HSPICE ASCII post=2 format,
which the current parser does not handle. It sits here for reference only, so
we have a real 9601-ASCII sample on hand if we ever decide to support that
format.

### `hmc-ace/`

| File | Size | Format | Endian | `nauto`/`nprobe`/`nsweep` | Version | Notes |
|---|---|---|---|---|---|---|
| `test_9601.tr0` | 51K | binary | little-endian | 5/0/0 | `9601` | `"9601    * rccirc"` — has **`* ` asterisk separator** before title |
| `test_2001.tr0` | 102K | binary | little-endian | 5/0/0 | `2001` | `"00002001* rccirc"` — 8-digit version, then **asterisk**, no spaces |

Both HMC-ACE files are little-endian, same as Nascentric/OmegaSim output. The
dialect difference is the **asterisk separator** — exactly what the HMC-ACE
`hSpice_output.md` documentation describes. This confirms HMC-ACE's doc was
accurate for its own files; it just happens to describe a different dialect
than the one Nascentric writes and gwave's binary samples use.

The `test_2001.tr0` file carries a `2001` version tag at the version offset,
with the 8-digit form `"00002001"` (no trailing spaces). That's a different
encoding from `9601`'s `"9601    "` (4 chars + 4 spaces). If we ever want to
handle 2001-format files, we'll need to accommodate both version-field widths.

## Dialect summary

Three distinct dialects are visible in this corpus at the title-region byte
layout:

1. **Nascentric dialect** — `"9601    "` + 64-byte fixed-width title + fixed
   16-byte date + 8-byte time + 72-byte copyright. No asterisk anywhere.
   Matches: our internal fixtures at `Tests/WaveformViewerTests/Fixtures/`.
2. **gwave-binary dialect** — `"9601    "` + variable-length whitespace-
   terminated title, no asterisk. Matches: `gwave/quickINV.tr0`,
   `gwave/quickTRAN.tr0`, `gwave/test1.tr0.binary`.
3. **HMC-ACE dialect** — `"9601    "` (or `"00002001"`) + `"* "` asterisk
   separator + variable-length filename/title. Matches:
   `hmc-ace/test_9601.tr0`, `hmc-ace/test_2001.tr0`. Also matches the
   HMC-ACE `hSpice_output.md` documentation.

Whether my parser correctly reads any given file will depend on which
assumptions about the title region it makes. The Nascentric-dialect path is
the one that's currently wired up; the other two will reveal whether it
generalizes or needs a second parse path.

## How to test

Open each file in the running app via `File → Open…` and check:

1. Does it load without error, or does it report a parse failure?
2. If it loads: are the signal names sensible (not full of garbage)?
3. Are the waveforms visually reasonable (right shape, right count, right
   time axis)?

A signal list full of garbage names but a correct sample count usually means
the title/date/copyright region has a different layout and the parser got
desynchronized from the real start of the waveform ID table. That's a
dialect-divergence signal, not a numerical bug.
