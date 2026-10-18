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

## Localised to the DWG bridge (build 0.103)

The defect was narrowed by differential test, which changes where to look and how big the fix is.

Same template, same `layout.set` + `saveas`, two targets:

| save target | 41D1's id after the round-trip |
|---|---|
| `.dxf` | **1** — unchanged, correct |
| `.dwg` | **3** — promoted to a model window |

The DXF path is innocent at both ends: `dxf_write.rs:1059` writes `w.i(69, i64::from(v.id))` (the stored
id verbatim) and `dxf_read.rs:490` reads it back with `id: t.i(69).unwrap_or(0) as u32`. A DXF
round-trip preserves all four ids exactly (`1021`=1, `30F5`=2, `41D1`=1, `41D5`=2).

The DWG path loses them because **DWG has no viewport-id field to store**. Converting the saved DWG back
to DXF yields VIEWPORT records carrying group 69 = 1, 2, 3, 4 in record order — sequential numbering by
position, not the original ids. `crates/dwg/src/lib.rs` is a 456-line entity-type map with no viewport
case at all, and `dxf_write.rs:1436-1439` already documents the consequence: *"DWG does not store
viewport ids; readers number them in order."*

So this is **not a bug in a renumbering routine — there is no such routine.** It is that the sheet/model
distinction has nowhere to live across a DWG save. Two consequences for whoever fixes it:

1. The fix is not "stop renumbering". It is to *preserve the distinction* through DWG: either derive it on
   read (a viewport whose `viewCenter == center` and `viewHeight == height` is a sheet window, so give it
   id 1) or store it, as `paper_view` already does for the DXF path via CADCraft xdata
   (`dxf_write.rs:1459-1462`).
2. The DXF path already solves this correctly, so the DWG fix should reuse that idea rather than invent
   one. Deriving from geometry is attractive because it needs no format extension and also works on files
   written by other applications.

## The geometry derivation does NOT work — tried and reverted (build 0.104)

The suggestion in point 2 above was implemented, tested, and **reverted**. It is recorded here so the next
reader does not spend a build rediscovering why.

**What was tried.** In `dxf_read.rs`, derive the role instead of trusting group 69: a viewport whose
`viewCenter == center` and `viewHeight == height` is a sheet window, so give it id 1.

**What looked right.** On the untouched template it classified all four viewports correctly, and the DWG
round-trip then preserved the roles: `1021`=1, `30F5`=2, `41D1`=**1** (was 3), `41D5`=4. Model windows
drawing model content dropped from 3 to 2, which is the ghosting fix. `cargo xtask ci` passed all six
steps, including three new regression tests (`sheet_viewport_keeps_its_id_through_dwg`,
`model_viewport_is_not_mistaken_for_the_sheet`, `sheet_viewport_id_derivation_survives_float_noise`).

**Why it is wrong anyway.** The predicate is not a valid definition of "sheet window". A content viewport
framed at 1:1 with `viewCenter == center` and `viewHeight == height` satisfies exactly the same condition —
and that is not a hypothetical, it is what the generated sheets do: the generators reframe the content
window 30F5 to precisely that framing (the working drawings' own convention, measured as (420,322) vh 524).
So the derivation reclassifies the content window as a sheet window, gives it `id=1`, and the sheet is left
with **no model window at all**.

The PSA gate caught it immediately: `check-f2` FAIL (11 sheets plot empty), `check-f5` FAIL (11 sheets with
duplicate or empty plots), `check-f6` FAIL (11 sheets, content viewport does not frame its content). Reverted;
gate green again.

**The real lesson for whoever fixes this.** `viewCenter == center && viewHeight == height` distinguishes a
sheet window from a *zoomed* model window, but not from a **1:1 model window**, and 1:1 content windows are
normal on these sheets. A correct derivation needs something the geometry alone does not give — e.g. that the
viewport's view covers the whole sheet (`width`/`height` equal to the sheet's paper size), or the layout's
own first-viewport convention, or storing the role explicitly the way `paper_view` already does for DXF via
CADCraft xdata. The xdata route is the only one of the three that is known-correct, because it does not
guess.

**And the meta-lesson.** Three new unit tests passed, and `cargo xtask ci` passed all six steps, while the
change broke eleven sheets. The unit tests asserted the predicate's behaviour, not the drawing's. The gate
that caught it was the one that measures real plots. A change can be fully green in the crate's own test
suite and still be wrong; the end-to-end check is not optional decoration.



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
