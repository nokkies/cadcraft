# Colour and stroke fidelity: measured against the source, sheet geometry is exact

Reinach's goal is that the generated sheets *look like* the originals, and colour is a large part of
that. Earlier checks measured ink coverage as a single percentage, which cannot tell a correct drawing
from one where every line is the wrong colour. This compares the actual strokes.

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

## What the large mismatches are

GAD-001's 214 and SCD-002's 93 are not lost geometry. For GAD-001, **all 214 have their exact shape
present in the generated file — only their position differs, and none is missing**. They are magenta
(text), span exactly 9.0 units, and sit at evenly spaced x positions (410.3, 422.6, 429.5, 440.9, 452.3,
462.2, 472.1 — about 11 apart).

Correct glyph shapes at slightly wrong spacing is **character advance width**: the defect documented in
`shx-font-width.md`, now confirmed geometrically rather than by counting words. cadcraft substitutes a
stroke font for SHX; the glyphs are right, the spacing between them is ~1.55x too wide.

## Conclusion

Sheet geometry, colour and stroke width are exact. Every difference is a text glyph, either tessellated
slightly differently or spaced by the wrong advance width — the one documented SHX substitution.

## The lessons, for the next comparison

- **Fix the render window before comparing coordinates.** Different auto-fit zooms make every
  coordinate differ and produce confident nonsense.
- **Sort mismatches by bounding size before believing them.** If every difference is glyph-sized it is
  the font; if any is large, check whether the *shape* exists elsewhere before calling it lost geometry.
  Here "1,525 large mismatches" was a scale artifact, and the real 214 were all present-but-moved.
