# Blocked cards

A card goes here after failing its check three builds in a row. Entry form:

```
## <card id>  blocked at build <n>
Command: <the exact command>
Error:   <the full error text>
Tried:   <one line per attempt>
```

Blocked cards are revisited after each 100-build summary.

## M5 observations (not blocked cards)

Things found while working the PSA drawings that belong upstream in cadcraft, recorded here so
they can be measured and fixed upstream. None of these blocks a card.

### D10 — SHX fonts substitute, so text widths differ (build 0.016)

The PSA template text styles use SHX fonts (`isocp.shx`, `isocp2.shx`, `Romans`). cadcraft does
not parse SHX, so its renderer substitutes its own stroke font (`crates/fonts/src/stroke.rs`).
The glyphs are legible and the right size in height, but the **advance widths differ from
AutoCAD's**, so a run of text is wider or narrower than it is in the Reference PDFs. This shows
up as text that overruns or falls short of its cell (title-block fields, wire labels) when a
cadcraft PNG is compared with the Reference PDF of the same sheet.

Synthetic example to measure upstream: a single-line `TEXT` "AAAAAAAAAA" at height 10, style
`Standard`, insertion (0,0), in a fresh drawing. Render it with cadcraft and measure the drawn
right edge; compare with the width AutoCAD's `txt.shx`/`isocp.shx` produces for the same string
at the same height. The difference is the substitution width error, and it scales with the
number of characters, so long title-block captions drift more than short wire labels.

Nothing to fix in the drawings themselves — this is a cadcraft rendering limitation, an M5 item.
Written up for upstream as `psa/pr/shx-font-width.md` (build 0.030), with the code references and a
measured advance-width number.

**Status correction (build 0.113).** Two numbers in this entry are stale and were superseded by later
measurements, and the entry survived only because nothing re-read it after the fixes landed.

* The substitution is now **controlled**: `TextFont::resolve` consults `FONTALT` and renders an unfound SHX
  in a findable face, driven by `CADCRAFT_FONTALT`. The scripts set `CADCRAFT_FONTALT=arial.ttf`, so
  substituted text is Arial, not the raw stroke font.
* The advance-width claim in `psa/pr/shx-font-width.md` (a "~0.6 em" figure) was **withdrawn at build
  0.099** after measuring it: every `.shx` style renders identically because they all fall through to the
  same stroke font, and 10 A's at height 10 measure **90.667** units, i.e. an advance of 0.9333 em, not 0.6.

What remains true, and is the actual reason this entry exists: cadcraft still cannot parse SHX, so glyph
*shapes* and advance widths are cadcraft's own and differ from AutoCAD's. The height is right; the widths
drift. The entry stays open on that basis, not on the withdrawn number.

**Measured confirmation (build 0.074).** Reinach reported the regenerated sheets "look worse than the
originals" (round terminals, no border change). Measured the DWG data against the source working
drawing on SCD-001: the 15 terminal circles on layer 3C are identical in count, radius (2.5) and
position (0 mismatches over all 15 centers), and the 15 terminal-number texts on layer 3T are
identical in content and position (0 differences). The A1 BORDER insert is identical (insert 0,0,
scale 1, rot 0). So the terminals are round because the *source* draws them as round circles, and the
border is present and unchanged because it is the template's border faithfully used -- both render in
cadcraft's own paper-space preview and exportpdf plot (full frame, zone markers, title block). The
"worse" is the renderer: cadcraft substitutes its own stroke font for the SHX fonts (above) and draws
circles as polygon approximations, so identical DWG data reads less crisply than AutoCAD's render of
the same data. This is the same M5 render-fidelity gap, not a generation defect -- the data is
byte-faithful to the source.

### M5 — multi-viewport paper-space plots composite unreliably (build 0.061, corrected 0.065, WITHDRAWN 0.101)

**This entry is withdrawn.** It claimed cadcraft's `exportpdf` "does not reproduce that composite
reliably", so a correct DWG "may still show a sheet empty or cropped". Measured at build 0.101, that is
not what cadcraft does: it composites multiple paper-space viewports correctly.

The test. GAD-001's source sheet has four paper-space viewports. Two are sheet-level (their `viewCenter`
equals their paper-space centre, so they frame the sheet), and one is a genuine detail viewport: handle
41D5, paper rect centred (128, 98) mm measuring 206×156, with `viewCenter` (875, 1629) and `viewHeight`
3188 — pointing into model space, which is what a detail/zoom window is. Exporting the source sheet with
`exportpdf {layouts, paper A3, fit}` and counting the vector items whose centre falls inside 41D5's rect:

| region | drawings | path items |
|---|---|---|
| 41D5 detail viewport rect | 122 | **5,402** |
| equal-size control region elsewhere on the sheet | 3 | 69 |

A 78× difference against a same-size control. The detail viewport's model content is composited onto the
plotted page, which is the behaviour this entry said cadcraft could not do.

**What the observation was actually seeing.** Two real things, neither of them a compositing gap:

1. **The empty plots were a generation bug, and it was fixed at build 0.065** — the template's content
   viewport pointed at empty space, so sheets plotted border and title block with nothing in the drawing
   area. That is the part build 0.065 already corrected.
2. **The detail viewports were erased, at build 0.066, to fix ghosting** — cadcraft's `saveas` renumbered
   viewport ids and promoted one of them into the model-window list, which made content plot twice. So a
   *generated* sheet had two viewports where the source has four, and its plot lacked the detail window.
   **That generation choice was reversed at build 0.110 and the erase is gone.** It was not the right
   trade: measured by taking a source sheet and erasing only 41D5 through cadcraft — identical content,
   one entity deleted — plotted ink fell from 11,376 to 6,887 on SCD-003 and 15,300 to 8,817 on SCD-001.
   The erase was deleting a displayed viewport holding a third of the sheet, and it accounted for the whole
   "generated plots at 0.6 of the source" gap.

**The real upstream defect was the id-promotion one, and it is FIXED locally at build 0.105.** `saveas`
renumbered viewport ids and promoted a paper-space viewport into the model-space window list; that is what
forced the 0.066 erase. The fix carries the sheet role in CADCraft xdata across a DWG save, verified four
ways including a test that fails if the marker is dropped. It is a candidate upstream PR.
`psa/pr/multi-viewport-plot.md` is the full account, including the two corrections (0.108, 0.109) that this
entry's earlier revisions needed.

**Also recorded here as a limitation hit while testing:** `mview` does not accept `handles` in
script-file JSON ("no viewport given"), and it could not have helped regardless — the detail viewports were
*erased*, not turned off, so there was nothing for `mview on` to restore. Moot now that the erase is gone.

### M5 — WITHDRAWN: GAD-001's oversized balloon text is a source-data trait, not a cadcraft defect (build 0.111, withdrawn 0.123)

Discovered while explaining why generated sheets carried more ink than their sources. The `_TagCircle`
balloon block is inserted 25 times at scale 6.0 on GAD-001 with identical block definitions and identical
reference scales on both sides; its text uses style `ISOCP` → `tahoma.ttf`. The generated sheet's balloons
measure 15.0mm against a 2.5mm source, and the sheet plots 2.0087× its source's ink.

**This was recorded as a cadcraft renderer defect. It is not one.** Re-measured at build 0.123. cadcraft's
`insert` renderer draws block *geometry* through the scaled sub-context and *attributes* at their stored
height through the outer context — and that is correct, because a DXF `ATTRIB`'s height is the effective
height with the insert scale already folded in (which engine `insert_with` does). A fix that made attributes
scale with the reference was built and measured: it rendered the generated sheet's already-scaled attributes
at scale-squared — balloons at **90mm**, not 15 — so it was reverted. The reasoning is now a comment at the
attribute draw path in `crates/render/src/lib.rs`.

The real difference is in the source's own data: GAD-001 stores its balloon tag at the raw attdef height
(2.5) while its balloon is at scale 6, so the source's own plot has 2.5mm text inside a 30mm circle. The
generated sheet stores the attribute already scaled (15.0), which is internally consistent with its circle.
The eleven other sheets store their balloon attributes already scaled, so source and generated agree and
measure 1.0000. The 2.0087 ratio is the generated sheet plotting text at the size that matches its balloons,
against a source that plots that text far too small. **There is no cadcraft bug here to file upstream.**

The earlier version of this entry claimed the TrueType path scaled attribute text where the stroke path did
not; both paths render at the stored height identically, so that mechanism was wrong. The writeup
`psa/pr/true-type-attribute-scale.md` carries the corrected finding. `check-textheights.ps1` (M4-C22) and
`check-sheetink.ps1` (M4-C23) still flag GAD-001 — the difference is real and worth watching — and remain
named accepted exceptions in `gen-all.ps1`, now with the correct reason recorded.





