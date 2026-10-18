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
2. **The detail viewports are now erased deliberately**, at build 0.066, to fix ghosting: cadcraft's
   `saveas` renumbers viewport ids and promotes one of them into the model-window list, which made
   content plot twice. So a *generated* sheet has two viewports where the source has four, and its plot
   legitimately lacks the detail window. That is a generation choice with a recorded reason, not a
   renderer failure.

**The real upstream defect, still open, is narrower and different:** `saveas` renumbers viewport ids and
promotes a paper-space viewport into the model-space window list. That is what forced the 0.066 erase.
It is recorded in `psa/pr/multi-viewport-plot.md`; that note should be read as the id-promotion defect,
not as evidence that compositing is broken.

**Also recorded here as a limitation hit while testing:** `mview` does not accept `handles` in
script-file JSON ("no viewport given"), and it cannot help here regardless — the detail viewports were
*erased*, not turned off, so there is nothing for `mview on` to restore. Restoring them would mean
re-creating the viewport entities, which is generation work, not a renderer gap.




