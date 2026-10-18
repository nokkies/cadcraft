# Direction review — please check whether we are heading the right way

**For:** a Claude review of direction (not a code review of the PRs).
**Repo:** `nokkies/cadcraft` (public fork of `storytold/cadcraft`), branch `fusion`.
**Build:** `psa/VERSION` = `0.124`. Changelog entries `0.000`→`0.124` in `psa/CHANGELOG.md`.
**Date:** 2026-10-18. (This document was first written at build 0.053; the status sections below were
refreshed at build 0.124 — several claims in the original had been overtaken by later builds.)

## What to read first (in this order)

1. `psa/PLAN.md` — the two-goal framing, the build-number scheme, the M0–M5 milestones, and the
   "ask Reinach only via `psa/QUESTIONS.md`" rule.
2. `psa/DRAWING-WORK.md` — the goal-2 drawing work list (D1–D10), with what is DONE / PARTIAL / OPEN.
3. `psa/QUESTIONS.md` — the open questions parked for Reinach (D2 to-scale, D3 duct/RAIL 3, D8 text height).
4. `docs/gaps.md` — the cadcraft AutoCAD-parity gap list (goal 1). Rows F1, F15, F16, F17 were narrowed
   by the recent work; the top rows (F2 xref, F3 dynamic-block authoring) are the big ones.
5. The 5 open PRs on the fork (#1–#5) — small command-behaviour fixes, each test-first with `cargo xtask ci` green.

## The two goals as I understand them

- **Goal 1 — cadcraft looks/behaves like AutoCAD, has blocks, templates, borders, can do full drawings.**
- **Goal 2 — the generated project drawings look more like their template.**

## Where each goal actually stands (honest)

**Goal 2 — real and substantial; the border/title-block comparison the original draft said was impossible is now done.**
The drawing pipeline lives *outside the repo* (private folder `$D` = `PSA_DRAWINGS`, a client
project; not committed here — clean-room rule). It generates 12 sheets (GAD-001/002,
SCD-001..005, TMD-001..005) from `NNNN-TEMPLATE_A.dwg` via `psa/scripts/gen-*.ps1`, and `gen-all.ps1`
runs a check suite over them. D1 (terminal *blocks* not drawn circles), D3 (rail cut-lengths), D4 (terminal
pin numbers), D5 (wire-number consistency), D6 (balloons↔BOM), D7 (cross-refs), D9 (TBC notes) are DONE.
D2 (to-scale component outlines) and D8 (one 2.0 mm text) are open questions.
**The border/title-block gap the original draft flagged is closed.** Paper-space layouts *can* be rendered and
plotted: `exportpdf` of each sheet's layout is what `check-f5`, `check-sheetink` and `check-detail` run, and the
template's border round-trips through cadcraft **bit-identically** (1541 geometry items, matching hash, both
sides). The real remaining goal-2 question is not "can we render the border" but "does the plotted sheet match
the working drawing to Reinach's eye" — a visual check the user owns, plus the two open drawing questions D2/D8.
`cadcraft-cli convert` still renders model space only, but that is no longer the blocker it looked like: layout
plots go through `exportpdf`, not `convert`.

**Goal 1 — the recent PRs did NOT advance it; that was a framing error I corrected.**
The 5 PRs are small AutoCAD-parity command fixes (-ATTEDIT Height/Angle/Style/Position, -RENAME viewport
config, PICKSTYLE associative-hatch bit, BATTMAN multiline switch). They are genuine and test-first, but
they do **not** give cadcraft an AutoCAD-like UI feel or a built-in block/template/border library.
cadcraft can *use* blocks/templates (that's how goal 2's sheets are made) but ships **no** AutoCAD-like
library — and by the repo's clean-room rules it **cannot copy** AutoCAD's or PSA's proprietary ones; any
library must be original with an `ATTRIBUTION.md` row.
**What goal 1 actually needs, restated after the review:** not a generic library but cadcraft reliably
producing and verifying PSA's own drawings with PSA's own private blocks. That capability was confirmed
working end-to-end at build 0.124: create a drawing from the template, insert a real named template block
(`DIN Rail Front`) into model space, it arrives with its geometry and renders, and saves as DWG. The template
carries 26 blocks and its border/title block survive a round-trip unchanged. So "have the blocks, templates,
borders" is a working path, not a gap — the open goal-1 items are the cadcraft *engine* gaps in
`docs/gaps.md` (F2 xref, F3 dynamic-block authoring) and the upstream issues Reinach owns.

## The question for the reviewer

1. Is the **sequencing** right — keep closing goal-2 drawing items, or pivot to goal-1 (cadcraft's
   AutoCAD look + an original block/template/border library)?
2. For goal 2, rendering paper-space layouts is **done** (the border round-trips bit-identically and layout
   plots go through `exportpdf`), so the remaining goal-2 step is Reinach's visual confirmation that the
   plotted sheets match the working drawings, plus the open drawing questions D2 and D8. Note the `Reference`
   PDFs turned out to be a *different* project (different document prefix), so they are not the look to match —
   see `psa/pr/reference-pdfs-are-not-the-target.md`.
3. For goal 1, given clean-room rules, is "build our own original AutoCAD-like block/template/border
   library" the intended path, or is goal 1 really about cadcraft's *UI/behaviour* feel rather than a
   content library?
4. Anything in the recent 5 PRs that looks like the wrong kind of work to be spending effort on?

## How to reproduce the state

- Code: `git fetch && git checkout fusion` (or the `fix/*` branches). `cargo xtask ci` should be green.
- Drawings: set `PSA_DRAWINGS` to the project folder, run `pwsh psa/scripts/gen-all.ps1` (generates +
  checks the 12 sheets). Render a sheet: `cadcraft-cli convert <in.dwg> <out.png>` (model space only).
