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
