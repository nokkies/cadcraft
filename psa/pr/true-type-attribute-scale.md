# GAD-001's balloon text is oversized in the SOURCE, not a cadcraft rendering defect

Status: **withdrawn as a cadcraft bug, and now fully resolved.** Re-measured at build 0.123; the earlier
version of this note (and the "~8% ink" line it carried) attributed the effect to a TrueType-vs-stroke
rendering difference. That attribution was wrong. Then, at the review of build 0.125, Claude found the source
generator (C#) that made the source sheets stored an inserted attribute at the block's raw height instead of
the scaled height, fixed it, and regenerated the sources — so the source now carries 15.0 like the generated
sheet (psa/REVIEW-0.125.md section 3). The 2.0087 ink ratio was separately shown to be the general
arrangement's viewport framed too tight, fixed at build 0.127 (M4-G2). GAD-001 now passes both
`check-sheetink` and `check-textheights` at 1.0000 with no exception. What follows is the record of how the
"renderer defect" conclusion was reached, tested, and withdrawn.

## The observation that started it

`check-sheetink` (M4-C23) plots each generated sheet against its source with `CADCRAFT_FONTALT` pinned for
both sides. Eleven of twelve sheets come out at exactly 1.0000; **GAD-001 comes out at 2.0087** — the
generated sheet plots more than twice its source's ink. The extra ink is the balloon tag text.

## What the data actually says

The `_TagCircle` balloon block is inserted 25 times at scale 6.0 on GAD-001, in both sheets. The attribute
text uses style `ISOCP` → `tahoma.ttf`.

| | balloon circle (rendered) | tag text (rendered) | stored attrib height |
|---|---|---|---|
| source | **30.0 mm** | **2.5 mm** | 2.5 |
| generated | 30.0 mm | 15.0 mm | 15.0 |

The source draws a **30 mm circle with 2.5 mm text inside it** — the tag is one twelfth the circle. That is
the source's own data: it stores the attribute at the attdef height (2.5) and the reference at scale 6.0, and
cadcraft renders the block *geometry* through the scaled transform while the *attribute* draws at its stored
height. The generated sheet stores the attribute already multiplied by the scale (15.0), so its text fills
its circle the way a balloon should.

## Why this is not a cadcraft renderer bug

cadcraft's `insert` renderer draws block entities through the scaled sub-context and attributes through the
outer context. That looks like an asymmetry, and a fix to make attributes scale with the reference was built
and tested. It **made the generated sheet worse, not better**: the generated attributes already carry the
scale, so applying the reference transform again rendered them at scale-squared — balloons at **90 mm**, not
15. The fix was reverted; the reasoning is now a comment at the attribute draw path in
`crates/render/src/lib.rs`.

The reason the double-scale is wrong is the DXF contract: an `ATTRIB`'s stored height is the **effective**
height, already including the insert scale. cadcraft's `insert_with` (engine) folds the scale in when it
creates the attribute, which is correct. A freshly inserted `_TagCircle` at scale 1 stores 2.5 and renders
2.5; at scale 6 stores 15.0 and renders 15.0 — always internally consistent with its circle.

## The real difference, and why only GAD-001 shows it

The eleven other sheets store their balloon attributes **already scaled**, so source and generated agree and
the ink ratio is 1.0000. GAD-001's source stores the **raw attdef height** (2.5) instead. So the source and
the generated sheet genuinely differ — but the generated sheet is the one that is internally correct, and the
source is the one whose text is too small for its circle. The 2.0087 ratio is the generated sheet plotting
text at the size that matches its balloons, against a source that plots that text far too small.

## What is and is not being claimed

**Claimed:** GAD-001's source stores balloon tag text at the raw attdef height while its balloons are at scale
6, so the source's own plot has 2.5 mm text in 30 mm circles; the generated sheet's 15 mm text is the
internally consistent value. The 2.0087 ink ratio is this, not a renderer fault.

**Not claimed:** that the generated 15 mm is what AutoCAD would draw for the source. cadcraft cannot read SHX,
so the other sheets' `isocp2` balloons are rendered with cadcraft's stroke font and are not what AutoCAD would
draw either. The reference PDFs are a different project (different document prefix — see
`reference-pdfs-are-not-the-target.md`) and cannot settle the exact intended size.

## Where this leaves the gate

Resolved at build 0.129. `check-sheetink` and `check-textheights` no longer flag GAD-001 and its two named
exceptions are removed from `gen-all.ps1`. The source generator was fixed and the sources regenerated, so the
source's balloon tag now stores 15.0 (the scaled height) like the generated sheet, and the general
arrangement's viewport is framed on the source's own view (build 0.127), so the sheet plots at 1.0000. There
is no cadcraft bug here to file upstream — an earlier version of this note called it one; that call is
withdrawn.

## The lesson

A balloon whose circle scales 6× and whose text does not looks, from one angle, like a renderer that forgot to
scale text. It is more cheaply explained by the source storing the text unscaled — and that explanation was
available from the stored heights, which were readable the whole time. The renderer fix was built, measured on
the real sheets, and caught by the measurement (90 mm) before it could ship. The governing question, again:
*is this the renderer's behaviour, or the data's?* — and the data was checkable first.
