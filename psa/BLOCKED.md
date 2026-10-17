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

### M5 — multi-viewport paper-space plots show a sub-region, not the whole assembly (build 0.061)

Comparing a generated general-arrangement sheet's `exportpdf` with the Reference PDF of the same
sheet, the Reference shows the complete assembly (full enclosure, all DIN rails, components,
balloons 1–21, dimensions) while the cadcraft plot shows a zoomed-in sub-region. This is NOT a
generation bug: plotting the SOURCE working drawing through cadcraft shows the SAME sub-region,
and a side-by-side confirms the generated sheet's cadcraft plot is a faithful match to the source's
cadcraft plot (same content, same framing). The difference is cadcraft vs AutoCAD.

The sheets carry several paper-space viewports (a large content window plus small detail/zoom
windows, e.g. handles 30F5 content + 41D5 detail on the GA). AutoCAD composites them so the plotted
PDF reads as one complete drawing; cadcraft's `exportpdf` of the layout renders the viewport windows
differently, so the assembly appears cropped to one window's view. Reframing the content viewport
(viewport.set to the source's viewCenter/viewHeight, or fitting the content extents) was tried and
does not change the plot — the source plots identically — so it is not closable in the generator.

Synthetic repro for upstream: a drawing with a paper-space layout containing two model-space
viewports of different sizes over the same model content; `exportpdf` the layout and compare with
what AutoCAD's PLOT produces for the same file. The expected behaviour is that the plotted page
shows each viewport's window with its own model view composited onto the sheet, as AutoCAD does.
This is the remaining reason the generated plots do not yet read as complete as the Reference, and
it is a cadcraft paper-space plotting gap, not a drawing-content gap.



