# Direction review — please check whether we are heading the right way

**For:** a Claude review of direction (not a code review of the PRs).
**Repo:** `nokkies/cadcraft` (public fork of `storytold/cadcraft`), branch `fusion`.
**Build:** `psa/VERSION` = `0.053`. 54 changelog entries (`0.000`→`0.053`) in `psa/CHANGELOG.md`.
**Date:** 2026-10-18.

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

**Goal 2 — real, substantial, but the key comparison is not yet done.**
The drawing pipeline lives *outside the repo* (private folder `$D` = `PSA_DRAWINGS`, a client
Solar Farm project; not committed here — clean-room rule). It generates 12 sheets (GAD-001/002,
SCD-001..005, TMD-001..005) from `NNNN-TEMPLATE_A.dwg` via `psa/scripts/gen-*.ps1`, and `gen-all.ps1`
runs a check suite over them. D1 (terminal *blocks* not drawn circles), D3 (rail cut-lengths), D4 (terminal
pin numbers), D5 (wire-number consistency), D6 (balloons↔BOM), D7 (cross-refs), D9 (TBC notes) are DONE.
D2 (to-scale component outlines) and D8 (one 2.0 mm text) are open questions.
**The gap:** `cadcraft-cli convert` renders **model space only**, and the template's border/title block
live in a **paper-space layout**. So I can render the generated *content* (it looks populated and clean)
but I **cannot yet render the template's border/title block** to compare side-by-side. That layout-render
path is the real next step for goal 2 — until then "they look like the template" is unverified for the
border/title block specifically.

**Goal 1 — the recent PRs did NOT advance it; that was a framing error I corrected.**
The 5 PRs are small AutoCAD-parity command fixes (-ATTEDIT Height/Angle/Style/Position, -RENAME viewport
config, PICKSTYLE associative-hatch bit, BATTMAN multiline switch). They are genuine and test-first, but
they do **not** give cadcraft an AutoCAD-like UI feel or a built-in block/template/border library.
cadcraft can *use* blocks/templates (that's how goal 2's sheets are made) but ships **no** AutoCAD-like
library — and by the repo's clean-room rules it **cannot copy** AutoCAD's or PSA's proprietary ones; any
library must be original with an `ATTRIBUTION.md` row.

## The question for the reviewer

1. Is the **sequencing** right — keep closing goal-2 drawing items, or pivot to goal-1 (cadcraft's
   AutoCAD look + an original block/template/border library)?
2. For goal 2, is **rendering paper-space layouts** (to compare the generated border/title block against
   the template) the correct next step, and is there a **Reference issued drawing/PDF** that is the actual
   look we are matching?
3. For goal 1, given clean-room rules, is "build our own original AutoCAD-like block/template/border
   library" the intended path, or is goal 1 really about cadcraft's *UI/behaviour* feel rather than a
   content library?
4. Anything in the recent 5 PRs that looks like the wrong kind of work to be spending effort on?

## How to reproduce the state

- Code: `git fetch && git checkout fusion` (or the `fix/*` branches). `cargo xtask ci` should be green.
- Drawings: set `PSA_DRAWINGS` to the project folder, run `pwsh psa/scripts/gen-all.ps1` (generates +
  checks the 12 sheets). Render a sheet: `cadcraft-cli convert <in.dwg> <out.png>` (model space only).
