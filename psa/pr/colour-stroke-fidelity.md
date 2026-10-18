# Colour and stroke fidelity: measured against the source, sheet geometry is exact

Reinach's goal is that the generated sheets *look like* the originals, and colour is a large part of
that. Earlier checks measured ink coverage as a single percentage, which cannot tell a correct drawing
from one where every line is the wrong colour. This compares the actual strokes.

## Method

`cadcraft-cli convert` to SVG keeps each stroke's colour, width and coordinates as text, so the two
sheets can be diffed without a vision model. SCD-001, source in `3. Working` against generated in
`fusion/out`.

## What matches exactly

| colour | source paths | generated paths |
|---|---:|---:|
| `#000000` black | 24 | 24 |
| `#ff0000` red | 67 | 67 |
| `#ff00ff` magenta | 1,860 | 1,860 |
| `#ffff00` yellow | 59 | 59 |
| **total** | **2,010** | **2,010** |

Every polyline carries the same stroke width (`0.518891`). The points-per-polyline distribution is
identical across all fourteen sizes present (960 two-point, 201 three-point, … 15 with 113 points, 2
with 200 points), so nothing is split or merged. Total point count is identical at **10,550**, and both
sheets fill exactly the same bounding box, `x 14.9680..763.3680, y 14.9680..482.3013`. Nothing is
added, removed, or shifted.

## What differs, and why it is the known font issue

1,495 of 2,010 polylines match exactly. The remaining 515 do not, and the difference is not a rounding
artefact — nearest-neighbour distance between same-colour unmatched polylines has median 3.3 units and
maximum 24.8.

Sorting the mismatches answers it:

- **by colour:** magenta 489 of 1,860 (26 %) and yellow 26 of 59 (44 %). Black and red match 100 %.
- **by size:** every single unmatched polyline has a bounding span **under 5 units**. None is between 5
  and 15, none above 15.

Magenta and yellow are the text layers; black and red are the border and title block. Sub-5-unit
polylines are glyph strokes. So the differing objects are exactly the SHX characters, tessellated
slightly differently between the two files, while **every piece of real drawing geometry matches to the
coordinate**.

That is the same root cause already documented in `shx-font-width.md`: cadcraft substitutes a stroke
font for SHX. It changes how glyphs are built, not where the drawing sits.

## Conclusion

Sheet geometry and colour are exact. The only stroke-level differences are glyph strokes, which is the
documented SHX substitution.

## The lesson, for the next comparison

Counting polylines, or comparing colour histograms, is not enough — 515 differences looked alarming
until they were sorted by size and colour. **Sort mismatches by bounding size first**: if every
difference is glyph-sized, it is the font; if any is large, it is real geometry and worth chasing.
