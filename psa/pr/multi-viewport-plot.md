# Saveas renumbers a sheet viewport into a model window (compositing claim withdrawn)

Status: **one real saveas defect. The compositing gap this note also claimed is WITHDRAWN — measured at
build 0.101, cadcraft composites multiple paper-space viewports correctly.** Filed as an M5 observation
from the PSA drawing project. No PR branch attached. Reinach decides which become issues on
`storytold/cadcraft`. Read the saveas section; treat everything below "Compositing claim withdrawn" as
historical.

## Saveas defect: a sheet viewport is promoted into the model-window list (build 0.066)

A layout's viewport table can hold a *sheet* viewport (the paper-space window that shows the layout
itself, `viewCenter == center` and `viewHeight == height`) alongside its model windows. On a layout
that was authored with a second sheet viewport (a real PSA template has two id=1 sheet windows),
`saveas` renumbers every viewport's id sequentially by handle order, which turns the second sheet
viewport (id=1) into a model window (id=3). After the save the layout's declared viewports grow: the
template's `[30F5, 41D5]` becomes `[30F5, 41D1, 41D5]`, and 41D1 — which showed the paper — now draws
model content, so the sheet renders the same content two or three times (visible ghosting). Reproduced
with a bare `layout.set` + `saveas` on an untouched template, so it is the save, not the caller. The
expected behaviour is that a sheet viewport keeps its paper-space role across a save. Worked around
generation-side (psa/scripts/gen-*.ps1 erase every viewport but the largest sheet window and the
largest model window before saving); the underlying save should not renumber a sheet viewport into a
model window.

Synthetic repro (no project DWG needed): create a drawing with one paper-space layout holding two
viewports whose `viewCenter == center` and `viewHeight == height` (two sheet windows, both id=1) plus
one model window (id=2, a smaller view of some model content). `saveas` the drawing, then `entities
{"type":"Viewport"}` and read the `id` of the second sheet window. Expected: it stays id=1 (a sheet
window). Observed: it becomes id=3 (a model window), so it now draws model content. The fix is in the
save-time id renumbering — it should preserve the sheet/model distinction (id=1 for sheet windows)
rather than renumbering purely by handle order.

## Compositing claim withdrawn (build 0.101)

This note previously said: *"When cadcraft `exportpdf`s the same layout, the page shows the content
cropped to one viewport's view, so a general-arrangement sheet that AutoCAD plots as a full assembly
plots as a zoomed-in sub-region."* **That is wrong, and the claim below is withdrawn rather than
softened.**

Measured on a sheet whose source layout carries four paper-space viewports — two sheet-level (their
`viewCenter` equals their paper-space centre) and one genuine detail window, whose `viewCenter` is
(875, 1629) with `viewHeight` 3188, i.e. pointing into model space. Exporting that layout with
`exportpdf {layouts, paper A3, fit}` and counting vector items whose centre falls inside the detail
window's paper rect:

| region | drawings | path items |
|---|---|---|
| detail viewport's paper rect | 122 | **5,402** |
| equal-size control region elsewhere on the page | 3 | 69 |

A 78× difference against a same-size control. The detail viewport's model content **is** composited onto
the plotted page, at its own paper position and size — exactly the behaviour this note said was missing.
The exported page's ink covers essentially the whole sheet, and exports of different sheets differ in
size and content rather than collapsing to one cropped sub-region.

**What the observation was actually seeing.** Two separate things, neither a compositing gap:

1. The empty plots were a **generation bug** — the template's content viewport pointed at empty space —
   found and fixed at build 0.065.
2. The detail viewports are now **erased deliberately** at build 0.066, because of the saveas defect
   above: leaving them in made content plot two or three times. So a generated sheet has two viewports
   where the source has four, and its plot legitimately lacks the detail window. That is a recorded
   generation choice, not a renderer failure.

The correct scope of this note is therefore the saveas id-promotion defect alone. Fixing *that* would
let the generator stop erasing the detail viewports, which is what actually removes the detail window
from generated plots — the renderer is not the blocker.

## What to look at in the code

- `crates/io/src/` — the save-time viewport id renumbering. It should preserve the sheet/model
  distinction (id=1 for sheet windows) instead of renumbering purely by handle order.
- `crates/engine/src/cmd/layout.rs` `viewport.set` / `mview` — the viewport model cadcraft stores
  (viewCenter, viewHeight, paper center/width/height, id, frozen layers). Confirmed sufficient: the
  composite renders correctly from this data.

## Why it matters for the PSA project

The saveas defect is what forces the generator to erase the detail viewports, and that erasure — not any
renderer limitation — is why a generated sheet's plot lacks the small zoom windows the source sheet has.
Fixing the renumbering lets the generator keep them.

## Notes for whoever opens this

- Reproduce with the synthetic two-sheet-window layout in the saveas section; do not attach a project DWG
  (two-folder rule).
- One tooling limitation met while testing: `mview` does not accept `handles` in script-file JSON
  ("no viewport given"), and cannot restore an *erased* viewport in any case.
- Cross-reference: `psa/BLOCKED.md` "multi-viewport" entry, withdrawn at build 0.101 with the measurement.


A layout's viewport table can hold a *sheet* viewport (the paper-space window that shows the layout
itself, `viewCenter == center` and `viewHeight == height`) alongside its model windows. On a layout
that was authored with a second sheet viewport (a real PSA template has two id=1 sheet windows),
`saveas` renumbers every viewport's id sequentially by handle order, which turns the second sheet
viewport (id=1) into a model window (id=3). After the save the layout's declared viewports grow: the
template's `[30F5, 41D5]` becomes `[30F5, 41D1, 41D5]`, and 41D1 — which showed the paper — now draws
model content, so the sheet renders the same content two or three times (visible ghosting). Reproduced
with a bare `layout.set` + `saveas` on an untouched template, so it is the save, not the caller. The
expected behaviour is that a sheet viewport keeps its paper-space role across a save. Worked around
generation-side (psa/scripts/gen-*.ps1 erase every viewport but the largest sheet window and the
largest model window before saving); the underlying save should not renumber a sheet viewport into a
model window.

Synthetic repro (no project DWG needed): create a drawing with one paper-space layout holding two
viewports whose `viewCenter == center` and `viewHeight == height` (two sheet windows, both id=1) plus
one model window (id=2, a smaller view of some model content). `saveas` the drawing, then `entities
{"type":"Viewport"}` and read the `id` of the second sheet window. Expected: it stays id=1 (a sheet
window). Observed: it becomes id=3 (a model window), so it now draws model content. The fix is in the
save-time id renumbering — it should preserve the sheet/model distinction (id=1 for sheet windows)
rather than renumbering purely by handle order.
