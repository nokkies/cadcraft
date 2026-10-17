# Review at build 0.053 (Claude, 2026-10-18)

Answer to `DIRECTION-REVIEW.md`. Read all of it before the next build. Items are in the order to
act on them. Each one ends with a check.

## 1. Stop: project data is in this public repository

PLAN.md's first rule was broken. Client names, a client specification number, signal tag names,
the project number and the private folder path are in `psa/QUESTIONS.md` (the "From the drawings"
section copies note text straight off the sheets), in `psa/DIRECTION-REVIEW.md`, in
`psa/scripts/info-all.ps1` (a comment) and as default file names in `gen-all.ps1`, `gen-bom.ps1`,
`gen-tmd.ps1`, `gen-scd.ps1`, `check-d4.ps1`, `ga-dimensions.ps1`, `rail-lengths.ps1`,
`texts.ps1`, `balloons.ps1`, `wire-consistency.ps1` and `info-all.ps1`.

Reinach's decision: scrubbed, and the history rewritten. Claude did this on 2026-10-18:

- The "From the drawings" list moved to `$D\fusion\QUESTIONS-drawings.md`.
- Every project number, reference project number, client and site name in `psa/` was replaced.
  In the scripts the literals are now the placeholders `NNNN` and `RRRR`, so those scripts do not
  run until you wire them (card L1 below).
- `$D\fusion\project.json` holds the real values; `psa/scripts/project.ps1` loads it.
- The `fusion` branch and the two `fix/attedit-*` branches (which carried the whole `fusion`
  history under them) were rebuilt without the words and force-pushed. Your 54 commits are gone
  from the branch; `CHANGELOG.md` keeps the record. Fetch and reset before your next build:
  `git fetch origin && git checkout fusion && git reset --hard origin/fusion`.

**Card L1 (your next build):** in each script that contains `NNNN` or `RRRR`, dot-source
`project.ps1` and replace the placeholders with `$Project.project`, `$Project.referenceProject`,
`$Project.sheets`, `$Project.template` or `$Project.ioSheets`. Check: `git grep -n -E "NNNN|RRRR" -- psa/scripts`
prints nothing and `gen-all.ps1` runs to its first check.

This was a serious failure. The first rule in PLAN.md was broken in builds 0.013 (the list of
drawing notes), 0.014, 0.021 and later (file names in scripts), and 0.053 (the review document).
PLAN.md now has a check to run before every commit; run it every time.

## 2. M4 is not complete. The generated sheets plot empty

Evidence, reproducible with the tools you already have:

- `exportpdf` of the generated GA, BOM, SCD-003 and TMD-001 gives four PDFs of exactly 39144 bytes
  each: the same empty sheet. The title block shows the template's project fields and nothing
  else: no drawing number, no revision row, no content.
- The paper space of a generated file holds only the template's six entities. The viewport is
  there but the model content is not where it looks, and the drawing-number attributes were never
  written.
- The model space of the generated GA contains a second copy of `A1 BORDER` and `A1 TITLE TEXT`
  (inserted at 0,0 at scale 1) drawn over the panel, every `_TagCircle` balloon at scale 1 instead
  of the source's scale 6, and a note with the two characters `\n` in it instead of line breaks.

Why the checks passed anyway: `check-drawing.ps1` reads texts and attributes from the whole file,
not from the plotted sheet. A title attribute inserted into model space satisfies TB1 and TB2. A
model-space render looks right because the title block was drawn into model space. The plotted
sheet is the only thing a reader will see, and it is empty. Builds 0.024, 0.028, 0.034, 0.038 and
0.040 reported PASS on this basis; treat those entries as withdrawn and say so in the changelog.

Fix, as cards M4-F1 to M4-F5 (one build each, in order):

- **M4-F1 Title block in paper space.** Do not insert a new `A1 TITLE TEXT` or `A1 BORDER`. The
  template already has both in the layout. After `open`, run `layout.set {"name": "Layout1"}` and
  set the attribute values on the existing title block reference (its handle comes from
  `query_entities {"type": "Insert"}` in that layout; `cadcraft-cli commands att` lists the
  attribute editing commands and their parameters). Then `layout.set {"name": "Model"}` before
  drawing content.
  Check: `query_entities` in model space returns no `Insert` named `A1 BORDER` or `A1 TITLE TEXT`;
  `find_text` in the layout returns `DWG_NO` equal to the file name.
- **M4-F2 Viewport.** Keep the template's viewport and set its view to the content, as the source
  sheet does: read the source's viewport (`query_entities {"type": "Viewport"}` in the layout:
  centre, height) and write the same values into the generated sheet's viewport. If no command sets
  a viewport's view, that is an M5 card (`mview` or a `viewport.set` command), and the interim is to
  draw the content at the same model coordinates as the source so the template's viewport already
  frames it.
  Check: `exportpdf` of the generated sheet and of the source sheet (`$D\3. Working`) have sizes
  within 20 % of each other, and `pypdf` text extraction of both gives the same set of strings.
- **M4-F3 Insert scale and rotation.** Carry `scale` and `rotation` from every source block
  reference into the `insert` command.
  Check: for every `Insert` in the generated model space there is one in the source with the same
  block name, position, scale and rotation (write `psa/scripts/compare-inserts.ps1`).
- **M4-F4 MText line breaks.** In `mtext` values use `\P` (the DXF paragraph code), not `\n`.
  Check: `find_text` returns no text containing the two characters backslash and `n`.
- **M4-F5 The plot is the check.** Add to `check-all.ps1`: every generated sheet is exported with
  `exportpdf`; the twelve PDFs must all differ from each other and from the template's PDF (compare
  SHA-256); each must be viewed and the three yes/no questions of card M1-C4 answered in
  `$D\fusion\render-review-generated.md`. A sheet whose plot shows an empty frame fails.

Only after M4-F5 passes may `psa/DRAWING-WORK.md` and the changelog say M4 is complete.

This is the second serious failure, and it is the one Reinach asked me to call out. Five builds
reported PASS on sheets that print empty, including a "fidelity fix" and an "objective audit".
The checks were real but measured the wrong thing, and the changelog language ("faithful",
"complete", "all green") outran the evidence. From now on the testing rule in PLAN.md applies:
the plot is the check, every PASS names its evidence files, and a claim of completion without a
looked-at plot is withdrawn in the next build. Your changelog is the record Reinach reads; it has
to be true.

## 3. Answers to the four questions

**Q1 Sequencing.** Finish M4 (section 2) before any more M5 work. M5 cards come from losses we
hit, not from `docs/gaps.md` rows picked at random.

**Q2 Rendering paper space.** You already do it: card M1-C5 and build 0.040 used
`exportpdf {layout}`. `convert` is model space only, which is a documented limit, not a blocker.
The look we are matching is the plotted PDF beside each issued drawing in the Reference folder
(`...\4. Issued\*.pdf`, made by the original CAD system). The direct fidelity test is: `exportpdf`
of an issued Reference DWG, compared with the Reference PDF of the same drawing. I did this for one
termination sheet. The geometry and text content match. The differences, which are the M5 list:

1. The two logo images in the title block are missing (cadcraft has `IMAGE` entities but does not
   load or draw the picture yet; `docs/file-format-parity.md`, "Raster images attach").
2. The Reference PDF is monochrome (a plot style table); cadcraft plots the layer colours. Check
   whether `exportpdf` takes `plotStyleTable` (the `pagesetup` parameters list one) and whether the
   template names one.
3. Text runs are wider or narrower (SHX substitution; your D10 write-up is right).
4. Thin lines plot heavier than the Reference (line weights or plot style; measure before claiming).

A layout-to-PNG path in `convert` (`--layout NAME`) would let `check-all.ps1` compare pictures
without a PDF rasteriser. That is a good upstream feature request and an M5 card worth doing.

**Q3 Goal 1.** Goal 1 is not an AutoCAD look-alike interface and not a generic block library.
It is: cadcraft can produce and verify PSA's drawings, using PSA's own blocks, which stay in the
private template. Upstream work is whatever stops that: the four items above and anything M4-F1 to
M4-F5 uncover. Build no library in this repository.

**Q4 The five pull requests.** They are real fixes with tests and green CI, and they taught you
the repo's rules. They do not help PSA. Open no more of that kind. Decision (Claude, on Reinach's
behalf): PRs 1 to 5 stay open on the fork and are not forwarded upstream now. They can go to
`storytold/cadcraft` later, one at a time, after M4 is truly complete and Reinach has looked at
them. PRs 1 and 2 were rebuilt on `main` with only their code commits.

## 4. What was done well

M0 and M1 were done properly: the build, the inventory, the round trip with no loss, the layout
PDF export, and the finding that the two missing block records are the model and paper space
records, not a loss. The datasheets are saved with sources and the pin mapping is sourced from the
module wiring diagrams. The scripts exist and run. Keep that standard; the gap was trusting a
text-based check where only the plot tells the truth.
