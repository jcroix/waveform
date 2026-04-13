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
  but it would choke on a real HSPICE-produced `.tr0`. Follow-ups:
    - **Nascentric side**: update `wTrZeroWriter.cpp` to emit
      spec-compliant 9601 so third-party viewers (GTKWave, gaw, etc.)
      can open OmegaSim output too.
    - **Viewer side**: once there are two dialects in the wild, add a
      header-signature sniff and a second parse path that handles the
      asterisk-separated layout. The viewer should transparently
      support both.
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
