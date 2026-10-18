# The Reference PDFs are not a fidelity target for these sheets

Written at build 0.118, after a first attempt to use them that produced a number that looked like a
catastrophe and was not one.

## The tempting measurement, and why it is wrong

The Reference folder holds issued PDFs whose names line up with ours sheet for sheet. Comparing plotted
ink, generated against reference:

| sheet | reference ink | generated ink | ratio |
|---|---|---|---|
| GAD-001 | 70,297 | 2,774 | 0.039 |
| GAD-002 | 2,153 | 149 | 0.069 |
| TMD-001 | 11,185 | 153 | 0.014 |
| TMD-002 | 8,004 | 215 | 0.027 |
| TMD-003 | 10,324 | 289 | 0.028 |
| SCD-001 | 6,378 | 832 | 0.130 |
Read as a fidelity score that says our sheets contain one to thirteen percent of the drawing. It does not
say that, and the number is not evidence of anything, for a reason that is visible in the file names: every
reference sheet carries a **different document-number prefix** from ours. **They are different projects.** A
reference sheet from another job is not a specification for this one; it is a different drawing that happens
to share a suffix.

## What was checked before concluding that

The 42x gap between our own source working drawing (6,499 ink items plotted) and our generated sheet from it
(153) looked like a generation defect regardless of the reference question, so it was isolated rather than
assumed away:

- **Not the DWG round-trip.** The source plotted directly gives 6,499; the same source run through
  `saveas` and plotted again gives 6,499, byte-identical output.
- **Not the viewport ids.** The saveas renumbers the source's viewport ids to 1, 2, 1, 4 -- the same shape
  the generated sheets have -- and it still plots 6,499.
- **Not the layer table.** All 56 layers match on `on`, `frozen`, `plot` and `newVpFreeze`, including the
  three that are off and the two that do not plot.
- **Not the page setup.** Paper, margins, scale, plot area and device are identical; only the plot style
  table differs (`PSA.ctb` against `monochrome.ctb`) and the lineweights flag, neither of which removes
  geometry.
- **Not the model content.** Entity types and counts match on all three sheets checked: TMD-001 65 = 65,
  SCD-001 320 = 320, GAD-001 217 vs 218 (one MText added by the generator on purpose).

And the source working drawing, plotted, **looks the same as ours**: mostly empty white, a notes block, a
title block, a faint grid. Confirmed by looking at it, not inferred. So the 6,499-to-153 difference is not
missing content -- it is cadcraft counting different things for the same page. The source DWG's text renders
as zero extracted characters and 6,499 vector path items; the generated sheet's renders as 973 characters and
153 path items. Same page, two representations: one where text is stroke geometry counted as ink, one where
it is real font glyphs counted as text. `get_drawings()` counts the first and barely the second, which is the
same instrument weakness already recorded twice (build 0.110 on bounding-box ink share, build 0.116 on the
eighteen-fold FONTALT effect).

## What the references ARE good for

They are a legitimate target for **presentation** properties, where the comparison is between like things:

- page size: reference 420.2 x 297.0 mm, ours 420.0 x 297.0 mm -- matches to the rounding.
- monochrome plotting: `check-ink` (M4-C14) already asserts this against them.
- text size ceiling: no reference span exceeds 7.7pt, while our generated sheets carry spans up to 19.8 and
  24.4pt. That is worth a look, but it is a hint rather than a finding, because it is a different project's
  sheet and its title block is not our template's.

## The rule this leaves

**A comparison needs a counterpart, and a matching file name is not a counterpart.** Before measuring
against anything, establish that it is the same drawing. The cheap test is the document number prefix: if it
differs, the sheets are different drawings and every ratio computed between them is decoration.

The standing fidelity target remains the source working drawing in `3. Working`, which is the same project,
the same template and the same sheets -- which is what `audit-*` and `check-detail`/`check-sheetink` compare
against, and why those comparisons produce ratios near 1.0000 rather than near 0.03.
