# SHX text advance widths differ from AutoCAD (stroke-font substitution)

Status: **feature gap, not a defect.** Filed as an M5 observation from the PSA drawing project so
it is measured and prioritised upstream. No PR branch is attached — the fix is an SHX reader, which
is a feature, not a patch. This document is the reproduction and measurement; Reinach decides
whether it becomes an issue on `storytold/cadcraft`.

## Summary

cadcraft does not parse `.shx` shape fonts. A text style that names one (the PSA template uses
`isocp.shx`, `isocp2.shx`, `Romans`) falls back to the built-in single-stroke font
(`crates/fonts/src/stroke.rs`) or, via `FONTALT`, a TrueType face. The glyphs are legible and the
**height** is right, but the **advance widths** are the stroke font's own, so a run of text is
wider or narrower than AutoCAD lays it out. Long captions in a fixed title-block cell then overrun
or fall short of the cell when a cadcraft render is compared with the reference PDF of the same
sheet.

## Where it comes from in the code

- `crates/fonts/src/ttf.rs:495` `is_stroke_name()` — a style name ending in `.shx` (or `txt`,
  `simplex`, `romans`) is never looked up as TrueType; it is treated as the stroke font.
- `crates/fonts/src/ttf.rs:9-11` — `FONTALT` is the substitute for a font we can't find; empty
  means the built-in stroke font.
- `crates/fonts/src/lib.rs:84` `char_advance()` — the advance is computed purely from the stroke
  font's glyph table: `(w + GAP) / CAP`, with `CAP = 6.0`, `GAP = 1.6`
  (`crates/fonts/src/stroke.rs:8-9`). There is no per-font SHX metric anywhere.

So the advance is a property of cadcraft's one stroke font, not of the SHX font the drawing asked
for. That is the whole gap.

## Reproduction (synthetic, no project data)

The script `psa/repro/shx-font-width.scr` builds the test texts; run it headless:

```
cadcraft-cli run --sample --script-file psa/repro/shx-font-width.scr
```

Create a single-line `TEXT` "AAAAAAAAAA", height 10, style `Standard`, insertion (0,0), in a fresh
drawing:

```
cadcraft-cli run --sample \
  --cmd 'text {"at":[0,0],"text":"AAAAAAAAAA","height":10}' \
  --cmd 'entities {"contains":"AAAA"}'
```

The entity is created (handle `12E`, `height:10.0`, `value:"AAAAAAAAAA"`, `widthFactor:1.0`).
`entities` does not report the advance (it is computed at render time), so measure it from the
font crate's own metric, which is authoritative:

- `char_advance('A')` = `(4.0 + 1.6) / 6.0` = **0.9333 em** (glyph `'A'` width is 4.0,
  `crates/fonts/src/stroke.rs:14`).
- 10 characters at height 10: total advance `10 × 0.9333 × 10` = **93.33 units**; the drawn right
  edge (the trailing gap is dropped on the last glyph, `crates/fonts/src/complex.rs:125`) is
  `93.33 − (1.6/6.0 × 10)` = **90.67 units**.

AutoCAD's `txt.shx`/`isocp.shx` 'A' advance is about 0.6 em (a narrower single-stroke shape font),
so the same string at the same height is roughly **1.55× wider** in cadcraft. The error is linear
in character count, which is why a short wire label is a few tenths off but a long title-block
caption drifts by a full cell width.

## Real-world impact on the PSA sheets (measured build 0.074)

This is not a corner case on these drawings: **every text on a generated sheet is affected.** On
SCD-001 the `texts` command reports 99 text entities, and the `style` command reports that both
styles in use (`Standard`, 97 texts; `Romans`, 2 texts) name `font:"isocp.shx"`, `trueType:false`.
So 99/99 texts fall back to cadcraft's stroke font — the whole sheet's text is the substituted
width, which is why the render reads "worse than the originals" end to end rather than in one spot.
The DWG data itself is byte-faithful to the source (text content, height, and insertion identical;
see `psa/BLOCKED.md` D10, build 0.074) — only the rendered advance widths differ. The generator
cannot close this: switching the style to a TrueType face would both alter the drawing away from the
source and require a font cadcraft is not permitted to ship (clean-room), so the fix is the SHX
reader described above.

**Mitigation shipped (build 0.076, generation side).** cadcraft's `TextFont::resolve` already
renders an unfindable font (an SHX file) in the `FONTALT` face when one is set. The PSA scripts now
set `CADCRAFT_FONTALT=arial.ttf` for the PDF export, so the review PDFs render SHX text in real
TrueType outlines instead of the stroke font -- crisper, professional-looking text. This is a
*quality* mitigation, not a width fix: Arial's advance widths are not isocp's, so the advance-width
error above is unchanged (it just now reads as Arial-vs-isocp rather than stroke-vs-isocp). The DWG
data is untouched and AutoCAD still opens the sheet with the real isocp.shx. The full fix remains
the SHX reader.

Measured source-vs-generated plot (SCD-001, both A3, build 0.077): the source PDF carries 15,168
vector line segments and 32 extractable words (its copyright note only); the generated PDF carries
595 segments and 88 extractable words (all schematic labels and title-block fields). The source's
segment count is ~25x ours purely because its SHX text is drawn as stroke geometry (~14,960 of those
segments are glyph strokes; only ~206 are real linework), while the Arial-substituted text is embedded
font glyphs (0 segments) and the generated 595 segments are the real linework. So the generated plot
is not missing linework -- and it is searchable and selectable, which the source plot is not. The
remaining difference is glyph shape and advance width, which only the SHX reader closes.

## Why it is not a quick patch

Closing it means reading the SHX shape/metric format (a public Autodesk format spec) and giving
each substituted style its own advance table — a font-engineering feature, tracked in
`docs/gaps.md`, not a one-line fix. The clean-room rule also forbids shipping Autodesk's own SHX
files, so any fix ships cadcraft's own metrics.

## What would help the PSA project now

An approximate per-style width multiplier (so a substituted SHX style can be nudged to AutoCAD's
advance) would remove most of the visible cell overrun without a full SHX reader. That is the
concrete ask if the full reader is not scheduled.

## Notes for whoever opens this

- Reproduce with the synthetic command above; do not attach a project DWG (two-folder rule).
- The measurement is from `char_advance`, so it is stable across machines and does not depend on
  installed fonts.
- Cross-reference: `docs/gaps.md` (font/rendering rows) and the PSA project's `psa/BLOCKED.md`
  "D10" observation, which is where this was first noticed.
