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

## FIXED in build 0.105 — the sheet role is stored, not derived

The xdata route (point 2 above, "the only known-correct route because it does not guess") is implemented
and shipped. Summary of the change:

- `crates/io/src/dxf_ext.rs` — new `SHEET_VIEW` marker (`"SHEETVIEW"`) and `is_sheet_view()`. Deliberately
  a *separate* marker from `PAPER_VIEW`: that one marks a viewport the writer *added*, which the reader
  drops as implicit. Reusing it would have made the reader drop real sheet viewports.
- `crates/io/src/dxf_write.rs` — a VIEWPORT with `id == 1` is stamped with the marker, in the same CADCraft
  xdata run that already carries VPFROZEN/VPCOLORS.
- `crates/io/src/dxf_read.rs` — a marked viewport is read with `id` forced to 1, overriding the renumbered
  group 69. The marker is authoritative because it records intent, which the renumbered id does not.

Measured on the untouched template, saving with **no erase at all**: all four viewports survive and exactly
two draw model content (`30F5`, `41D5`), with `41D1` back at `id=1`. Before the fix it was three — the
promoted `41D1` was the ghosting. So the generator no longer needs to erase detail viewports.

Verified three ways, because round 43 showed that CI alone is not enough:
1. `cargo xtask ci` — all six steps.
2. Three regression tests that assert the **drawing's** behaviour, not the marker's:
   `sheet_viewport_keeps_its_id_through_dwg`, `a_saved_sheet_keeps_a_model_window`, and
   `a_1to1_content_window_is_not_reclassified_as_the_sheet` — the last one is the case that broke the
   round-43 attempt, pinned as a test so it cannot come back.
3. **The tests were proved to bite**: with the reader's marker check neutered,
   `sheet_viewport_keeps_its_id_through_dwg` failed with `got [1, 2, 3]` — the promotion bug, exactly.
4. The PSA gate: all 26 checks green on all twelve sheets.

The `1:1` content window keeps `id=2` because the role is stored, not inferred — which is the whole point.

## Correction (build 0.108): removing the erase was premature — the detail window has a second, separate problem

Builds 0.106/0.107 said "the generator no longer needs to erase detail viewports". **That was wrong**, and
the claim was made from the wrong evidence: the gate passing, and a viewport count matching the source.
Nobody plotted it and counted the ink.

Measured on the regenerated GAD plot, grid-diffed against the source (7×7 cells of path items): the
generated sheet carries roughly **twice** the source's ink almost everywhere, including cells that should be
empty — row 5 col 2: source 3,081 vs generated 4,850; row 5 col 3: 812 vs 2,405; row 4 col 3: 472 vs 1,868.
A vision read of the same plot independently reported a "dark, blurry rectangular artifact" beside the inset.

The cause, measured: **the template's detail window 41D5 is inherited verbatim and points at model
coordinates that have nothing to do with our drawing.** Its view rect is `viewCenter 875,1629`,
`viewHeight 3188` — i.e. model x −1225..2976, y 35..3223. Our generated content spans x −85..1360,
y −55..1085, and **202 of 218 positioned entities fall inside that rect.** So the inset shows the entire
main drawing at 1/20 scale. That is the "looks duplicated" report from build 0.065, and it is the *real*
reason the erase existed.

So there were **two independent defects**, and 0.105 fixed only one:

1. **The id renumbering** (fixed in 0.105, verified, still correct).
2. **The template's detail window is aimed at empty template space**, which our content happens to overlap.
   The erase masked this by deleting the window.

The correct end state is not "keep the window as inherited" and not "delete it". It is **keep it and aim it
at a real detail region of our own content** — which is what the source sheet does: its 41D5 shows a genuine
detail at 1/20, and its content window 30F5 sits at `viewCenter 780,520 vh 1572` (1/3), while ours is at
`638,515 vh 1254` (1/2). Until a generator chooses a detail region deliberately, the window must be erased,
and the erase is a legitimate choice rather than a workaround.

**The lesson, and it is the same one as round 43 in a different costume:** a viewport count matching the
source is a structural check, not a visual one. The gate verified *that the window exists*; nothing
verified *what it shows*. The fix is to add a check that measures the plotted ink of a detail window against
a control region of the same size, so an inset showing the whole drawing cannot pass.

## Correction (build 0.109): the 25% threshold was itself a false premise — the working drawings' detail windows DO show the whole drawing

The section above is right that nothing measured what a window shows, and check-detail was written to fix
that. But its threshold was invented in the script rather than measured, and it was wrong.

Measured on the SOURCE sheets, the ink inside their own detail windows as a share of the sheet total:

| sheet | source share |
|---|---|
| GAD-001 | 54% |
| GAD-002 | **96%** |
| SCD-001 | 71% |
| SCD-002 | 75% |
| SCD-003 | 53% |
| TMD-001 | 72% |
| TMD-005 | 65% |

The check shipped in 0.108 failed any window above **25%**. Against these numbers it would have failed
**every source sheet in the set**, and GAD-002 by a factor of nearly four. The premise that "a detail window
showing most of the drawing is echoing rather than detailing" is simply not what the working drawings do --
their small window is a reduced overall view, not a zoom on a corner.

So the rule became a COMPARISON rather than a threshold: plot the source and the generated sheet, measure
the same paper rectangle in both, require the generated share to sit within 35% of the source's. That is
"looks like the working drawings" expressed as a test, and it has no number in it that was guessed.

Two things this immediately bought:

1. **It discriminates, where the threshold could not.** With the erase in place the drifts are 3%, 4%, 5%,
   11%, 13%, 18%, 18%, 20%, 25%, 29% and two failures at 38% and 43%. The erase is not a gross error on
   these sheets -- the reduced overall view still lands in the same region -- so a check looking for gross
   duplication would never have seen it either way.
2. **It found two genuine content gaps nobody had seen.** SCD-003 (33% vs 53%) and SCD-004 (30% vs 53%)
   carry materially less content in the detail region than their sources. These are real differences against
   the working drawings, surfaced by a check that compares rather than asserts.

**The general lesson, which is the fourth instance of the same failure in this arc:** a threshold chosen
because it separates the case you are worried about is not a rule about the domain. Round 43 was a geometry
predicate that behaved like a definition on the tested case; this was a share threshold that behaved like a
specification while failing every reference example. The guard question is the same both times -- *what does
the reference actually do?* -- and the answer has to be measured before the number is written down.

## What the two failures are, and why they are not the erase

The check fails SCD-003 and SCD-004. Before calling that a false alarm the erase was ruled out, because the
erase removes the window whose rectangle is being measured and could plausibly do so on every sheet equally:

* paper space differs from the source by exactly the two erased viewports on **every** sheet, not just the
  failing two;
* model space differs only by +16 MText (the intentional annotations), and **the extents are identical**
  (SCD-003: x 40..625 y 130..560 on both sides);
* the content viewport 30F5 is byte-identical to the source's on both sheets (center 420,322, size 811x524,
  viewCenter 420,322, viewHeight 524).

The decisive measurement is the ratio *inside the detail region* against the ratio *for the whole sheet*:

| sheet | detail-region ink gen/src | whole-sheet ink gen/src |
|---|---|---|
| SCD-001 | 0.470 | 0.576 |
| SCD-003 | **0.383** | 0.620 |

SCD-001's two ratios are close, so its detail region is simply a fair sample of a sheet that plots lighter
overall. SCD-003's detail-region ratio is well below its sheet ratio, which is what a **local** shortfall
looks like: something in that region of the source is not being reproduced. That is a real fidelity gap, and
it is the first time this arc has measured one in the detail region rather than in the sheet as a whole.

Both sheets plot at roughly 0.6 of the source's total ink, which is a separate standing question -- why the
generated plot carries about 60% of the reference's stroke count at all -- and it is the obvious next thing
to chase, since it applies to all twelve.

## Answered (build 0.110): the 0.6 is the erase, and the two "gaps" were the erase too

The standing question above is closed, and the answer also corrects the section before it. The SCD-003 and
SCD-004 "local shortfalls" were **the erase**, not a generation bug -- and the whole-sheet 0.6 ratio is the
same thing.

Proven with a clean isolation rather than an argument. Take the SOURCE sheet, run it through cadcraft with
one command -- `erase {"handles":["41D5"]}` -- and save. Now two files exist whose content, layers, blocks,
text and viewport frames are identical by construction; the only difference is whether the detail window is
there. Plot both and measure the same paper rectangle:

| sheet | source as-is | source minus 41D5 |
|---|---|---|
| SCD-003 | share 0.527, total 11,376 | **share 0.221, total 6,887** |
| SCD-001 | share 0.713, total 15,300 | **share 0.502, total 8,817** |

SCD-003's share falls 0.527 -> 0.221, which brackets the 0.325 measured on the generated sheet; SCD-001's
falls 0.713 -> 0.502, bracketing its generated 0.581. And the totals: erasing one viewport removes 39% of
SCD-003's plotted ink and 42% of SCD-001's -- which is where the "generated plots at 0.6 of the source"
went. It is not that the generator draws less. It is that the generator deletes a window that displays a
third of the sheet.

So the erase is doing something worse than the defect it was written to avoid. It was added because a second
model window made the content appear two or three times; build 0.105 fixed that properly; and the window the
erase then removes is a **displayed** viewport (all four viewports on the source sheets have `on=True`)
showing a reduced overall view. Keeping it is right, and check-detail as rewritten in 0.109 is the guard
that says so.

Two things worth keeping from the investigation, because both were wrong before being measured:

* **The grid used to localise this was itself miscalculated.** It divided the page into square cells while
  the page is 420x297mm, so the reported coordinates were wrong and the column it flagged was flagged for a
  reason that did not hold. Scaling each axis by its own extent fixed it. A measurement that looks precise
  because it is a grid is not exempt from getting the geometry right.
* **The ink-share metric is weak evidence about a picture.** The detail window's share was measured at 54%
  while a look at the plot shows that region as mostly white space with a small schematic in one corner.
  Intersecting a path's bounding box with a rectangle counts a long stroke that merely crosses the region as
  belonging to it. The structural test -- is the window there or not -- is the one that holds up here.





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
