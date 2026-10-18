# Title-block fidelity: measured, source vs generated

Reinach's original complaint included "I dont see any borders". The border and title block were
subsequently confirmed present in the DWG and in the render. This note records the deeper check done
after that, because the first pass at it produced a wrong alarming number and the correction is the
useful part.

## What was compared

SCD-001, source sheet in `3. Working` against the generated sheet in `fusion/out`, both exported to PDF
by cadcraft with `CADCRAFT_FONTALT=arial.ttf`, then measured with pymupdf.

## The measurement that misled, and why

Extracted **word counts** differed hugely: source 228, generated 69, "159 missing". That looks like the
generated sheet is missing most of its title block. It is not. Three checks show the word count is not
a valid fidelity measure here:

1. **Export the same two DWGs without FONTALT and both yield 0 extractable words.** The words only
   appear because Arial substitution makes text extractable; with the stroke font neither file has any.
   So the comparison was measuring the substitution path, not the drawing.
2. **The two DWGs are entity-identical.** Same model-space text count (97), same single long note
   (670 characters, layer `1T`, same position), same paper-space composition (2 block references,
   2 texts, 4 viewports).
3. **The `A1 TITLE TEXT` block definition is identical**: 79 entities in both. Exploded, it holds 399
   entities (206 Line, 97 MText, 79 attribute definitions, 17 Circle) — the grid rules, the labels and
   the attribute slots. There is no separate thumbnail object; what looks like a small inset drawing in
   the "GENERAL ARRANGEMENT" cell is the block's own dense line work.

## What the geometry actually does

Separating paths by size (glyph-sized under 15 pt vs real geometry) gives the honest comparison:

| | geometry paths | geometry segments | glyph-sized paths |
|---|---:|---:|---:|
| source | 69 | 377 | 59 |
| generated | 52 | 357 | 15 |

**Geometry segments match to 95 %** (377 vs 357), so no drawing content is lost. The remaining
difference is concentrated in the title-block band, where SHX glyph strokes and thin table rules are
interleaved and get grouped differently by the exporter. All 14 title-block labels and field headers
are present in the generated sheet, and the rendered title blocks show the same 11 columns, the same
headers, the same filled data row and the same numbered column blocks.

## Conclusion

The title block is faithful. The word-count gap is an artifact of how cadcraft rasterises SHX text,
the same root cause already documented in `shx-font-width.md`. It affects whether a PDF viewer can
*select* the text, not whether the text is *on the sheet*.

## The lesson, for the next comparison

Word counts from an exported PDF are not a fidelity metric when one side renders SHX as glyph strokes.
Compare **geometry segments** and **entity counts in the DWG** instead, and only treat text as evidence
when both sides were exported through the same font path.
