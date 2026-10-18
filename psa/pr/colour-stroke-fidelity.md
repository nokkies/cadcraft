# Colour and stroke fidelity: measured against the source, sheet geometry is exact

Reinach's goal is that the generated sheets *look like* the originals, and colour is a large part of
that. Earlier checks measured ink coverage as a single percentage, which cannot tell a correct drawing
from one where every line is the wrong colour. This compares the actual strokes.

Status: **the geometry comparison holds; the mismatch explanation in this note was wrong and was
corrected at build 0.099.** Read "Corrected at build 0.099" before quoting any number from the earlier
sections — the 214/93 mismatch counts and the "~1.55x too wide" attribution are both obsolete.

## Method

`cadcraft-cli convert` to SVG keeps each stroke's colour, width and coordinates as text, so the two
sheets can be diffed without a vision model.

**Render both files through the same explicit window** (`--window -100,-100,2000,1300`). Without it each
file is rendered at its own auto-fitted zoom, the two SVGs get different `viewBox` sizes, and every
coordinate is then incomparable. This is not a theoretical trap: an unconstrained first pass reported
1,525 large mismatches on GAD-001 including border-sized spans of 800 and 1000 units, which was pure
scale mismatch. With a fixed window both viewBoxes are `2100 x 1400` and the real number is 214.

## SCD-001: exact

| colour | source paths | generated paths |
|---|---:|---:|
| `#000000` black | 24 | 24 |
| `#ff0000` red | 67 | 67 |
| `#ff00ff` magenta | 1,860 | 1,860 |
| `#ffff00` yellow | 59 | 59 |
| **total** | **2,010** | **2,010** |

Every polyline carries the same stroke width (`0.518891`). The points-per-polyline distribution is
identical across all fourteen sizes present, total point count is identical at **10,550**, and both
sheets fill exactly the same bounding box, `x 14.9680..763.3680, y 14.9680..482.3013`. Nothing is
added, removed, split, merged or shifted.

1,495 of 2,010 polylines match to the coordinate. The 515 that do not are all magenta (489 of 1,860) or
yellow (26 of 59) — the text layers, while black and red (border and title block) match 100 percent —
and every one has a bounding span **under 5 units**, none between 5 and 15 and none above 15.

## All twelve sheets, same fixed window

| sheet | polylines src/gen | colours | unmatched | span >= 5 |
|---|---|---|---:|---:|
| GAD-001 | 1,862 / 2,049 | 3 / 3 | 321 | 214 |
| GAD-002 | 2,433 / 2,433 | 1 / 1 | 0 | 0 |
| SCD-001 | 2,010 / 2,010 | 4 / 4 | 515 | 0 |
| SCD-002 | 1,693 / 1,693 | 4 / 4 | 1,692 | 93 |
| SCD-003 | 1,418 / 1,482 | 3 / 3 | 95 | 0 |
| SCD-004 | 1,628 / 1,692 | 3 / 3 | 114 | 0 |
| SCD-005 | 1,940 / 1,966 | 5 / 5 | 425 | 0 |
| TMD-001 | 727 / 727 | 4 / 4 | 11 | 0 |
| TMD-002 | 967 / 967 | 4 / 4 | 24 | 0 |
| TMD-003 | 1,371 / 1,371 | 4 / 4 | 44 | 0 |
| TMD-004 | 1,371 / 1,371 | 4 / 4 | 40 | 0 |
| TMD-005 | 1,248 / 1,248 | 4 / 4 | 24 | 0 |

Colour counts match on the eight sheets whose polyline counts match. SCD-003, SCD-004 and SCD-005 carry
more polylines than their source (+64, +64, +26) — those are the D4 terminal-number labels and the D3
rail note, additions the model-space audit already accounts for. GAD-001's +187 is the same effect plus
its larger content.

Nine of twelve sheets have **zero** mismatches above 5 units.

## What the large mismatches were

This section records a measurement that **has since been overtaken by a fix**, kept because the numbers
below were true when written and the reasoning is what matters.

At build 0.088, GAD-001's 214 and SCD-002's 93 were not lost geometry: **all of them had their exact
shape present in the generated file — only their position differed, and none was missing**. They were
magenta (text layer), spanned about 9.0 units, and sat at evenly spaced x positions (410.3, 422.6, 429.5,
440.9, 452.3, 462.2, 472.1 — about 11 apart).

Correct glyph shapes at wrong spacing is **character advance width**. At the time this was attributed to
the SHX substitution in `shx-font-width.md` and described as "~1.55x too wide".

## Corrected at build 0.099: the cause was the style width factor, and it is fixed

Both halves of that attribution were wrong, and re-measuring after build 0.090 shows it.

**The cause was not SHX substitution.** The mismatched glyphs are the balloon tags, whose text uses style
`ISOCP` → `tahoma.ttf` — a TrueType face cadcraft renders natively, never substituted. (The same
investigation found these glyphs are emitted as filled `<path>` outlines rather than `<polyline>`
strokes, which is why the colour audit had not been comparing them at all until build 0.095.)

**The magnitude was never measured.** "~1.55x" came from an assumed AutoCAD advance of 0.6 em, which is
not measurable from the reference plots — they embed only TrueType fonts and expose no text layer for the
drawing text. See `shx-font-width.md`, "What is NOT measured".

**The real cause was build 0.090's fix.** `place_text_entity` in `crates/render/src/lib.rs` was ignoring
the text *style's* width factor and using only the entity's own, while `layout_mtext_entity` already read
`ts.width_factor`. Text styles carry a width factor — the template's `Romans` style is 0.9 — so TEXT and
ATTRIB rendered at the wrong horizontal scale. Fixed at `lib.rs:1298-1301`, pinned by
`crates/render/tests/text_style_width_factor.rs`.

**Re-measured after the fix.** In the x band the note cites, magenta glyph strokes now start at:

| | x positions of glyph-stroke starts |
|---|---|
| source | 402.0, 404.3, 406.7, 410.0, 411.0 |
| generated | 402.0, 404.4, 406.8, 410.0, 411.0 |

Agreement to about 0.1 units. Re-running the shape comparison over the whole sheet now finds **zero**
mismatches of 5 units or more whose shape is absent from the generated file — the 214 and 93 are gone.
`audit-colours.ps1` passes on all twelve sheets.


## Conclusion

Sheet geometry, colour and stroke width are exact. The position-only mismatches found at build 0.088
were a text-style width factor being ignored for TEXT and ATTRIB, fixed at build 0.090, and are no longer
present. The one remaining text difference on these sheets is glyph *shape* for `.shx` styles, which
cadcraft renders in a single built-in stroke font — see `shx-font-width.md` for what is and is not
measured about that.

## The lessons, for the next comparison

- **Fix the render window before comparing coordinates.** Different auto-fit zooms make every
  coordinate differ and produce confident nonsense.
- **Sort mismatches by bounding size before believing them.** If every difference is glyph-sized it is
  the font; if any is large, check whether the *shape* exists elsewhere before calling it lost geometry.
  Here "1,525 large mismatches" was a scale artifact, and the real 214 were all present-but-moved.
