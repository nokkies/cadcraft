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

### M5 — multi-viewport paper-space plots composite unreliably (build 0.061, corrected build 0.065)

Comparing a generated sheet's `exportpdf` with the Reference PDF, some sheets plot their content and
some plot empty even though the DWG data is correct. Build 0.062 first recorded this as "the source
plots the same way, so it is a cadcraft gap and not a generation bug" -- that conclusion was WRONG,
based on comparing two broken exportpdf plots. Build 0.065 found and fixed the real generation bug
(the template's content viewport pointed at empty space, so generated sheets plotted border + title
block with no content; now reframed on the content). What remains is genuinely upstream: cadcraft's
layout-to-PDF composites a layout's several paper-space viewports inconsistently, so `exportpdf` of a
correct DWG may still show a sheet empty or cropped even though AutoCAD (and cadcraft's own GUI/model
render) show it complete.

The sheets carry several paper-space viewports (a large content window plus small detail/zoom windows,
e.g. handles 30F5 content + 41D5 detail on the GA). AutoCAD composites them so the plotted PDF reads
as one complete drawing; cadcraft's `exportpdf` does not reproduce that composite reliably. check-f6
guards the DWG data (the content viewport must frame the content), which is now correct for all twelve
sheets; the exportpdf composite is the remaining upstream gap.

Synthetic repro for upstream: a drawing with a paper-space layout containing two model-space viewports
of different sizes over the same model content; `exportpdf` the layout and compare with what AutoCAD's
PLOT produces for the same file. The expected behaviour is that the plotted page shows each viewport's
window with its own model view composited onto the sheet, as AutoCAD does. Written up for upstream as
`psa/pr/multi-viewport-plot.md`.



