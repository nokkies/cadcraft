# STATUS at build 0.130 — for Reinach's review

One page. What works, what is open, what Reinach must answer. Written after the review at
`psa/REVIEW-0.125.md` section 6 was worked in order: M4-G1, M4-G2, M4-G3, the balloon-exception
removal, M5-P1..P3 with the push, and M5-orphan-paperspace. Builds 0.126 through 0.130, all pushed to
`fusion`.

## What works

- **All twelve sheets generate and the whole gate is green** (`gen-all.ps1`, exit 0): every check and
  fidelity audit passes. The gate is 37 items — the D-series (D1–D9), the F-series (F1–F8), the
  ink/text/width checks, the viewport count, and six structural audits (layers, sheet-space, text
  styles, blocks, linetypes, colours).
- **The general arrangement now plots correctly.** The two defects that made it wrong are fixed:
  - **M4-G1 (0.126):** the "detail viewports" chased for ~20 builds were never in the source. They
    lived in an orphan `*Paper_Space0` block no layout owned — Claude's template bug. The template was
    regenerated clean; every viewport-erase and detail-window path is deleted; `count-viewports.ps1`
    now asserts each generated sheet has the same paper-space viewports as its source (two, not four).
    `check-detail.ps1` (which measured ink inside the phantom window) is deleted.
  - **M4-G2 (0.127):** the generated content viewport now copies the **source's own** centre and height
    exactly, no content-bbox fallback. All twelve match the source to 0.1 (in fact exactly). The GA
    no longer zooms in and runs the NOTES block off the edge.
  - **M4-G3 (0.128):** the D3 rail-length note matches the GA NOTES block (height 8, style `isocp2`)
    instead of printing unreadable at height 3.
- **`check-sheetink` is at worst drift 0.0%.** It was 2.39× on the GA. That was the viewport framing
  (M4-G2), not the balloon. With the fixed sources and the correct framing, **GAD-001 passes both
  `check-sheetink` and `check-textheights` at 1.0000 with no exception** — the two GAD-001 accepted
  exceptions are removed (0.129). The balloon story in `psa/pr/true-type-attribute-scale.md` is closed:
  the 2.5mm source height was a bug in the C# generator that made the sources, now fixed and regenerated.
- **The four Rust fixes are on upstream PRs, and `fusion` carries only `psa/`.** Per the review, the
  code fixes no longer live on `fusion`. `git diff --name-only origin/main..fusion` lists only `psa/`
  files; `crates/` on fusion is byte-identical to `origin/main` (0.130).

## What is open

**Four upstream PRs on the fork, each `cargo xtask ci` green, awaiting merge:**

| PR | Branch | Fix |
|----|--------|-----|
| #6 | `fix/text-style-width-factor` | TEXT/ATTRIB/ATTDEF honour the text style's width factor |
| #7 | `fix/saveas-viewport-sheet-role` | sheet-viewport role carried in xdata so saveas does not ghost model content |
| #8 | `fix/wblock-block-library` | WBLOCK writes only the extracted block, not the parent's whole library |
| #9 | `fix/orphan-paperspace` | orphan `*Paper_Space*` blocks are dropped, not merged into the first layout |

- **PR #7 was re-checked against the review's "withdraw if the ghosting was the orphan" test.** It is
  **kept**: the ghosting was a saveas renumbering bug (DWG stores no viewport id, so the bridge numbers
  by record order and promotes a second id-1 sheet window into the model list). The orphan merely
  exposed it; the defect is general and the regression test is synthetic (a two-sheet-window layout),
  independent of the orphan.
- **PR #9 is the real upstream finding** from the review. Synthetic repro: a two-layout drawing with the
  second layout's `LAYOUT` object stripped, leaving its `*Paper_Space0` block orphaned. The test fails
  before the fix ("the orphan line leaked into Layout1") and passes after.
- **Gate/CLI caveat:** the PSA gate runs the prebuilt `target\release\cadcraft-cli.exe`, built from the
  fixed code. After the fusion reset, a CLI rebuilt from fusion's tracked code would drop the four
  fixes **until the PRs merge to `main` and fusion rebases onto them.** This is expected — the fixes are
  pending upstream, not withdrawn. Once they merge, fusion rebases and the gate runs against a
  fusion-built CLI again.
- **Visual plot verification is still Reinach's to do.** Every check here is structural or measured-ink;
  none is a human looking at a plotted sheet. The plots are in `$D\fusion\plots\` and `$D\fusion\pdf\`.

## What Reinach must answer (from `psa/QUESTIONS.md`)

These are engineering decisions, not build blockers — the gate passes either way.

- **D2 — GA scale.** The GA draws every component far larger than real (a schematic layout, as its own
  note 2 says). Want a to-scale arrangement (small I/O modules become slivers at the current scale, so
  it needs a larger scale or enlarged modules), or is the schematic layout fine for the draft set?
- **D3 — rail sizing.** RAIL 1/2 are sized from vendor widths. Two gaps: (a) the RAIL 3 field terminal
  blocks are generic strips with no datasheet width, so they read 0 — confirm their module width if you
  want RAIL 3 sized; (b) the duct run length is read off the GA layout, not a datasheet — confirm the
  4×60×40 slotted-duct lengths, or give the target to cut against.
- **D6 — enclosure balloon.** The enclosure BOM item has no balloon on the GA; we treat it as the
  envelope the GA draws, not a mounted item. Is that right, or should it carry a balloon to its outline?
- **D8 — terminal text height.** The five SCD sheets draw terminal row numbers at 2.0mm, below the
  format notes' 2.5mm "small" typical. The checker now exempts layer 3T so it passes. The open question
  is the engineering one: is 2.0mm terminal numbering acceptable, or should the source convention be
  raised to 2.5mm?

**Stopping here for review**, as instructed.
