# TODO

Items to look at after the current milestone.

## Hierarchical signal browser (sidebar)

The sidebar already uses `NSOutlineView` and builds a `HierarchyNode` tree
from dot-separated signal names (`v(x1.x2.net)` → `x1 → x2 → net`), so the
plumbing is mostly in place. The current LFSR9 test fixture is flat, so
this path hasn't been exercised with real hierarchical data yet. To-do:

- Verify the tree displays correctly for a document with genuine
  hierarchy (subcircuits, nested instances). Regenerate a fixture from
  a hierarchical OmegaSim netlist and spot-check the sidebar tree.
- Confirm that the standard `NSOutlineView` disclosure triangles expand
  and collapse one level at a time, and that ⌥-click expands all
  descendants. If either feels wrong, wire up explicit commands in the
  sidebar row's context menu or in the View menu (e.g., `Expand All`,
  `Collapse All`).
- Verify vertical scrolling behaves sanely when the number of visible
  signals exceeds the sidebar height. The `NSScrollView` wrapping the
  outline view should already handle this, but test with a large fixture
  (say ≥200 signals) and ensure scrollbar, keyboard scrolling, and
  two-finger scroll all work.
- When filtering, the text filter collapses the tree to matching leaves
  plus ancestors. Check that this still works in deeply-nested trees
  and that expanded state is preserved reasonably across filter changes.
- Consider a "remember expansion state per document" enhancement so
  reopening a file restores the previously-expanded nodes. Probably not
  needed in the first round, but worth noting.

## Overview / minimap strip (Phase 11)

Add a heavily-decimated mini-view of the full time range underneath each
plot pane. The user's original ask:

- Shows the entire sample span at very low resolution (maybe 200–400
  pixels wide, regardless of zoom level)
- Highlights the current viewport as a rectangle over the mini-view
- Dragging the rectangle pans the main plot's X viewport
- Dragging the rectangle's left or right edge resizes (= zooms) the
  main plot
- Click outside the rectangle jumps the viewport so that point becomes
  the new center

Implementation notes:

- Probably lives as a new `NSViewRepresentable` / `PlotNSView` subclass
  or a dedicated `OverviewStripNSView`, positioned below the existing
  plot area with a small fixed height (≈60 pt).
- Can reuse the existing `Decimator` with a large pixel width (the
  strip's width) and the full simulation span as the viewport. Cache
  the result since it doesn't change with zoom.
- Draw the viewport rectangle in `state.viewportX` (or the per-strip
  unit's X when unlinked) and drag it via standard NSView mouse
  handlers.
- In stacked strips mode, one strip per unit — each strip gets its own
  overview, matching the per-strip X viewport story introduced in
  Phase 14.1.
- In dual-axis mode, one overview for the pane.
- Link state: when linked, dragging in any strip's overview updates the
  shared X; when unlinked, it updates only that strip's per-unit X.
  Matches the main plot's behavior.

## Other follow-ups noted during development

- **OmegaSim's TR0 is a Nascentric dialect, not standard HSPICE 9601.**
  Cross-checked against the HMC-ACE hspiceParser documentation
  (`HMC-ACE/hspiceParser/hSpice_output.md`). The doc describes a
  variable-width header with an asterisk separator between the
  version descriptor and the filename, then whitespace-separated
  date / time / copyright / sweep count / variable names. OmegaSim's
  `wTrZeroWriter.cpp` instead writes fixed-width, space-padded
  fields with no asterisk, and uses bytes 4–15 of the descriptor as
  structured `probeCount` / `sweepCount` / reserved ASCII ints (where
  the doc says "reserved, 16 digits"). Waveform identifiers are also
  packed as 8-byte slots (`"  1     "` = V, `"  8     "` = I) rather
  than whitespace-separated numbers. My parser was reverse-engineered
  from the Nascentric reader so it decodes OmegaSim output correctly,
  but it would choke on a real HSPICE-produced `.tr0`.

  External references for TR0 format documentation and example files
  (both contain sample `.tr0` files — if downloaded, keep in a
  separate directory from the Nascentric fixtures since their
  provenance is unknown):
    - HMC-ACE hspiceParser: https://github.com/HMC-ACE/hspiceParser
      (format doc at `hSpice_output.md`)
    - l-chang/gwave: https://github.com/l-chang/gwave — a Gtk-based
      waveform viewer. Parser: `spicefile/ss_hspice.c`. Format notes:
      `doc/hspice-output.txt`.

  **gwave vs Nascentric vs HMC-ACE — compared.** I read gwave's
  `ss_hspice.c` and `doc/hspice-output.txt` and diffed against
  Nascentric and the HMC-ACE doc. Findings:

  1. **Fixed-byte count prefix at bytes 0–11.** gwave AGREES with
     Nascentric — both treat bytes 0–3 as `nauto`, 4–7 as `nprobe`,
     8–11 as `nsweepparam`, as 4-digit space-padded ASCII ints.
     gwave's `ss_hspice.c` does `strncpy(nbuf, &ahdr[0], 4); nauto =
     atoi(nbuf);` etc. The HMC-ACE doc DISAGREES — it says this
     region is "reserved 16 digits" after the version descriptor,
     not a structured prefix. gwave and Nascentric are in the same
     "fixed-offset count prefix" family; HMC-ACE is in its own
     world.

  2. **Version tag at bytes 16–19.** gwave AGREES with Nascentric —
     both expect a 4-char ASCII version string there, and gwave
     specifically checks for `"9007"` or `"9601"` via
     `strncmp(&ahdr[16], "9601", 4) != 0`. Nascentric writes exactly
     `"9601"` at byte 16 (padded out to 8 bytes with spaces, which
     gwave ignores). Compatible.

  3. **Post-header data (date / time / copyright / sweep count /
     types / names).** gwave and Nascentric DISAGREE on layout but
     may still interoperate thanks to gwave's permissive parser:
       - **Nascentric** writes strict fixed-width fields (64B title,
         16B date, 8B time, 72B copyright, then 4B table count +
         80B padding, then 8B waveform type slots, then 16B-aligned
         name blocks).
       - **gwave** doesn't care about fixed-width layout — from byte
         ~256 onward it `strtok`s everything on whitespace and
         consumes tokens in order: independent-var type, dependent
         type codes, independent-var name, dependent names,
         terminated by `$&%#`. Since Nascentric's fixed-width fields
         are all space-padded ASCII and don't contain embedded NUL
         bytes, gwave's tokenizer should, in theory, successfully
         scan type codes (`"1"`, `"8"`) and names out of them. Not
         yet verified on a real file.

  4. **Binary block framing.** gwave AGREES with Nascentric on the
     16-byte block header: `(h1=4, count, h3=4, block_nbytes)` plus
     a 4-byte trailer equal to `block_nbytes`. gwave detects endian
     swap by checking whether `h1 == 0x04000000` in the raw bytes
     (which only happens on big-endian-on-little-endian), which is
     the same strategy my parser uses. Fully compatible.

  5. **Version years (9007 vs 9601).** gwave's doc explicitly says
     `9007` is the July 1990 format and `9601` is the January 1996
     format — the latter has been the default since HSPICE 98.2.
     **Per the user's instruction we only care about 9601.** Both
     Nascentric and my parser write and read 9601 only. gwave's
     parser handles both but the 9007 path exists only for
     backward-compatibility with ~25-year-old tool output.

  6. **Endianness of real HSPICE files.** gwave's doc is candid: the
     author didn't know whether real HSPICE files are big-endian or
     native-endian and had no way to test. gwave handles both via
     runtime sniff, same as my parser. So my auto-detect strategy
     matches the one the other known TR0 reader uses.

  **Bottom line:** gwave's interpretation is MUCH closer to
  Nascentric's than HMC-ACE's is. gwave and Nascentric agree on the
  fixed-byte count prefix, the version tag at byte 16, the binary
  block framing, and endian detection. They disagree only on
  whether the post-header region is fixed-width (Nascentric) or
  whitespace-tokenized (gwave), and that disagreement is probably
  benign because Nascentric's fixed-width bytes happen to tokenize
  cleanly. HMC-ACE's "asterisk separator + variable-width" layout
  is the outlier; it may describe a different HSPICE dialect
  entirely, or it may be wrong.

  Follow-ups:
    - **Nascentric side**: the 9601 format we're writing today is
      already broadly compatible with the gwave lineage. Biggest
      practical issue is native-endian output — real HSPICE emitted
      big-endian. A single-patch fix in `wTrZeroWriter.cpp` to swap
      to big-endian would make OmegaSim output readable by any
      reader that assumes canonical HSPICE byte order. (gwave and my
      parser both auto-detect, so neither would care.)
    - **Viewer side**: actually test my parser against a gwave
      sample `.tr0` (when one is downloaded into a segregated
      fixture directory) and confirm whether the 8-byte type-slot
      vs. whitespace-token distinction matters. If it does, add a
      second parse path; if not, we're already compatible.
    - **HMC-ACE reconciliation**: lowest priority — if the HMC-ACE
      doc is describing a third dialect, add a header sniff later.
      Not worth doing until we actually see a real HMC-ACE-style
      file in the wild.
- **AArch64 vs x86-64 byte-compare**: `wTrZeroWriter.cpp` uses plain
  `fwrite(&value, 4, 1, fp)` on `int` and `float` locals — no
  platform-specific code. Both x86-64 and AArch64 are little-endian,
  IEEE-754, and have 32-bit `int`/`float`, so OmegaSim output should
  be byte-identical on both machines for the same netlist. If a
  diff shows up in anything other than the date/time fields, that's
  a real bug worth investigating: likely uninitialized padding,
  heap-derived data, or a non-deterministic timestamp.
- **Nascentric TR0 big-endian fix**: independent of the dialect
  question, OmegaSim's current writer produces native-endian output.
  The HSPICE canonical format allows either endianness (the block
  head encodes which), but real HSPICE tools historically emit
  big-endian. The viewer's byte-order auto-detect already handles
  both, so this is a nascentric-side cosmetic fix only.
- **Multi-table `.out` files**: flagged early but deferred. If OmegaSim
  starts emitting wide `.print` output as multiple column-split `x`/`y`
  blocks, `ListingParser` will currently emit each as an independent
  block. Add a post-processing pass that merges consecutive blocks that
  share an analysis context and a Time column.
- **User-customizable trace colors**: right now `ColorPalette.stableColor`
  assigns colors deterministically from the signal ID. A context-menu
  "Color…" picker per trace would let users override.
- **Dual cursors with delta readout**: currently one cursor. A second
  anchor cursor + delta display (Δt, Δv) would complete the cursor
  story.
- **`.app` packaging**: `scripts/make-app.sh` ships a working bundle but
  it's not code-signed or notarized. For distribution, add an Xcode
  project, sign with a Developer ID, and notarize.
