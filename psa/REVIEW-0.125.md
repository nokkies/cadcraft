# Review at build 0.125 (Claude, 2026-10-18)

Second review. I read the changelog from 0.054 to 0.125, plotted all twelve generated sheets and
their sources myself with `exportpdf`, looked at four of them, and read the DWG files with an
independent reader (ACadSharp, not cadcraft). Items in the order to act on them.

## Verdict

The generated sheets are now real drawings. Eleven of twelve plot within one percent of their
source's PDF size and the three I looked at (power distribution, X3 terminations, general
arrangement) are complete, correctly titled, monochrome and legible. The scrub held: no project
data in the working tree or in any commit since the rebuild, and the placeholders are wired. The
withdrawal of the false PASS claims was done. That is the standard asked for at 0.053 and it was
met.

Three things need fixing, one of them mine.

## 1. The "detail viewports" were never in the source. They came from the template

Builds 0.061 to 0.117 (about twenty builds) chased a detail viewport "41D5" believed to be in the
source sheets. Read with ACadSharp, every source sheet has exactly **two** paper-space viewports:
the sheet view and the content window. The two extra ones (523x222 at 163,98 and 206x156 at
128,98, view height 3188) live in an orphan block `*Paper_Space0` that no layout owns. It is the
paper space of the Layout2 that was deleted when the template was cut from the reference drawing.
That was my template bug.

cadcraft reads that orphan block's entities into the live layout and writes them into it on save.
So every file that went through cadcraft, including the round-trip "no loss" test, gained two
viewports, and every measurement made through cadcraft saw four where the file had two. Read
nothing about the source through cadcraft alone from now on: ACadSharp counts are in
`$D\fusion\expected.csv` for a reason, and `compare-info.ps1` exists to use them.

What I did: the template and the twelve source sheets in `$D\3. Working` were regenerated with the
orphan block emptied (the previous files are in `$D\Archive\`). Nothing visible changed in them.
A cadcraft round trip of the fixed GA now keeps two viewports.

**Card M4-G1.** Regenerate from the fixed sources. Remove every viewport-erase, viewport-restore,
"detail window" exception and the 41D5 reasoning from the generators and checks: a generated sheet
has the same two viewports as its source, nothing else. `check-detail.ps1` goes. Check:
ACadSharp-style count, two paper-space viewports per generated sheet, via `inventory`/`expected.csv`
logic extended to viewports (write `psa/scripts/count-viewports.ps1` using `cadcraft-cli` only after
confirming on one file that it now agrees with `expected.csv`).

**Card M5-orphan-paperspace.** This is a real upstream finding, better than any of the five PRs: a
DWG whose `*Paper_Space0` block has entities but no layout gets those entities attached to the
active layout on open, and saved there. Synthetic repro: make a two-layout drawing, delete the
second layout with a tool that leaves the block behind (or hand-edit the DXF to drop the LAYOUT
object), open, count viewports. Write the failing test in `crates/io/src/tests.rs`, fix the reader
to ignore blocks no layout owns (or purge them), and package it as the next `fix/*` branch.

## 2. The general arrangement is framed differently from its source

Source content viewport: centre (780, 520), view height 1572, scale 1:3. Generated: centre
(637, 515), height 1254, scale 1:2.39 (build 0.067 called this an acceptable "content-centred
fallback"). It is not acceptable: the notes run off the right edge of the sheet, the plot is 10 %
larger than the source, and the rail-length note added by card D3 prints at an unreadable height.

**Card M4-G2.** The generated viewport copies the source viewport's centre and height exactly, for
every sheet, no fallback. Check: the two numbers match the source to 0.1 for all twelve, and the GA
plot shows the full NOTES block inside the border.

**Card M4-G3.** The D3 rail-length note uses the same height and style as the GA NOTES block (8
units, same style). Check: `find_text` reports the same height for both.

## 3. The balloon text size: your 0.123 conclusion was right, and the source was wrong

The source stored the balloon TAGNUMBER at the block's raw 2.5 height inside a scale-6 insert.
AutoCAD stores an inserted attribute's height with the scale applied, so the generated 15 was the
correct value and the source's 2.5 was a bug in the C# generator. I fixed the generator; the
regenerated sources now carry 15. Remove the GAD-001 exceptions from `check-sheetink` and
`check-textheights`: with the fixed sources they should pass without them.

## 4. Process

**Rust changes are on the `fusion` branch.** Three code fixes (TEXT style width factor, the
viewport id xdata marker, WBLOCK block library) are committed directly on `fusion` mixed with
`psa/` commits. PLAN.md M5 puts each fix on its own `fix/*` branch with its test and `psa/pr/*.md`.
**Card M5-P1 to P3:** cherry-pick each fix (code, test, docs/gaps.md row) onto a branch from
`origin/main`, run `cargo xtask ci`, push the branch, open the PR on the fork. Then reset
`fusion` so it carries only `psa/` on top of `origin/main` (ask Reinach before a force-push; a
plain revert of the code commits on `fusion` is fine without asking). Note on the viewport id
marker fix: re-check that it is still needed once the orphan block is gone; if the ghosting it
fixed was the orphan viewports, withdraw it.

**Push.** 72 commits are unpushed. The hold was for the scrub and is over. Push `fusion` after
every build from now on.

**Stop building audits of audits.** Builds 0.080 to 0.098 and 0.112 to 0.117 added eight audit
scripts and then audited the audits. The gate is large enough. From here, a new check is added
only when a card's own check needs it. Your time goes to the cards above, then to the M3 items
below, then to upstream fixes that came from our own losses.

**Reading the source only through cadcraft** caused the viewport saga, the "roundtrip no loss"
false comfort, and the "four viewports" claim. Any claim about what a source file contains is
checked against `expected.csv` or a second reader before it is written down.

**Good:** the FONTALT substitution, the monochrome plot style, the MText width and style fix
(0.119), the attachment fix (0.120), the WBLOCK library finding (0.121), finding that the
Reference PDFs are another project (0.118), and withdrawing your own wrong notes when measured
(0.099, 0.101, 0.123). That is the standard.

## 5. Open questions, with my recommendations for Reinach

These are his to answer; the recommendation is mine.

- **D2 GA to scale.** Recommend yes: PSA general arrangements are to scale with real component
  footprints. 1:3 on A3 is too small for 22 mm modules; draw the front view at 1:2 and let it fill
  the sheet, or split front and side views over two sheets. Wait for his answer.
- **D8 terminal number height 2.0 mm.** Recommend raising to 2.5 mm in the source convention (the
  format notes' minimum). Wait for his answer.
- **D6 enclosure balloon.** Recommend a balloon on the enclosure outline; a BOM item with no balloon
  is a question at the workshop. Wait for his answer.
- **D3 RAIL 3 width and duct lengths.** Terminal block width is unknown until item 11 is defined;
  leave as TBC.

## 6. Order of work

M4-G1, M4-G2, M4-G3, then the balloon exception removal, then M5-P1 to P3 and the push, then
M5-orphan-paperspace. Nothing else until those are green and pushed. Then write
`psa/STATUS-0.150.md` (one page: what works, what is open, what Reinach must answer) and stop for
review.
