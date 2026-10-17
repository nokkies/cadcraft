# PSA Fusion work plan for the cadcraft fork

You are PSA Fusion, a local agent with unlimited run time and a small model. This plan is written
for you. Work one task card at a time, in order. Every card ends with a check you can run; the
check decides whether the card is done, you do not.

This repository is a public fork of `storytold/cadcraft`. Read `AGENTS.md` at the repository root
first: its rules (never crash, clean-room, Rust only, everything is a command, `cargo xtask ci`
before every commit) apply to every change you make here.

## Two folders, two rules

| Folder | What lives there | Rule |
|---|---|---|
| This repository (`psa/` and the Rust crates) | Code, scripts, tests with **synthetic** data, this plan, `CHANGELOG.md` | Public. Nothing from a client, a project or a PSA controlled document goes in here: no drawings, no PDFs, no BOMs, no specifications, no SharePoint links, no project numbers in file names. |
| `%PSA_DRAWINGS%` (an environment variable set on this machine, pointing at a folder outside the repository) | Project DWGs, the PSA format notes, reference drawings, the C# generator output | Private. Read it, write new files into its `fusion\` subfolder, change nothing else in it. |

If `%PSA_DRAWINGS%` is not set, stop and ask Reinach for it. Everything below that says
`$D` means `%PSA_DRAWINGS%`.

Inside `$D` you will find:

- `PSA_FORMAT_NOTES.md`: the PSA drawing conventions (title block attributes, layer names, text styles, block names). This is the standard every drawing is checked against.
- `Template\*.dwg`: the blank sheet template.
- `3. Working\*.dwg`: the current draft drawings, numbered `NNNN-IC-GAD-001_A.dwg` and so on.
- `Reference\...\4. Issued\*.dwg`: real PSA issued drawings, the gold standard for appearance.
- `_tools\venv`: a Python virtual environment with `pillow`.

## Project settings come from one private file

Every project fact a script needs (project number, reference project number, sheet file names,
template file name, which sheet is DI, DO, AO) is read from `$D\fusion\project.json` through
`psa/scripts/project.ps1` (dot-source it at the top of every script). A script in this repository
never contains a project number, a client name, a site name, a signal tag or a drawing file name.
Placeholders `NNNN` (project) and `RRRR` (reference project) mark where a literal once stood and
must be replaced by `$Project.project` and `$Project.referenceProject`.

Check before every commit: `git grep -n -E "NNNN|RRRR" -- psa/scripts` prints nothing, and
`git grep -i -n -E "<client>|<site>|<project number>" -- psa` (run with the real words) prints nothing.

## The source drawings are read-only

`$D\3. Working\*.dwg` is the approved draft set. Scripts read it and never write into it. Generated
sheets go to `$D\fusion\out\`. A dated copy of the draft set is kept in `$D\Archive\`.

## Testing rule: the plot is the check

A drawing check passes only when the plotted sheet is right. For anything a person would see on
paper (title block fields, borders, symbols, scale, line breaks, placement) the evidence is the
`exportpdf` of the layout, looked at, with the yes/no answers written down. Text and attribute
counts from the file are supporting evidence, never the only evidence: a title attribute written
into model space passes a text check and still prints as an empty title block.

Every build that claims PASS names its evidence files (PDF, PNG, report) in the changelog entry's
`Check:` line, with their paths under `$D\fusion\`. A PASS without evidence files is not a PASS.
A verification build that finds nothing wrong says what it looked at and what it compared against.

## Build numbers and the changelog

Every change you make, to code or to a drawing, is one **build**. `psa/VERSION` holds the current
build number as a three digit decimal (`0.000`, `0.001`, ...). Each build:

1. Make one change (one task card, or one step of a card).
2. Run that card's check. If it fails, fix and run again; the build is not done until it passes.
3. Add one entry at the top of `psa/CHANGELOG.md` in this exact form:

   ```
   ## 0.017  2026-10-18  M1-C3
   Changed: <one sentence, what is different now>
   Check:   <the command you ran and its result, one line>
   Files:   <paths changed, comma separated>
   ```
4. Write the new number to `psa/VERSION`.
5. Commit with the message `build 0.017: <the Changed sentence>`. Commit to the branch `fusion`, never to `main`.

The **drawing revision** on the sheets stays `A` until the engineering manager reviews them. The build number
is yours; the revision letter is his.

Every 100 builds, add a section `## Summary at 0.100` (and 0.200, ...) to the top of the changelog:
five lines, what is now working that was not before, and what is still failing. At build **0.900**
also write `psa/REVIEW-REQUEST.md` (what you built, what you could not finish, the three questions
you most need answered) and stop adding features until Reinach or Claude has reviewed it.

If the same card fails its check three builds in a row, write the failure to `psa/BLOCKED.md`
(card id, the command, the full error) and move to the next card. Blocked cards are revisited
after the next 100-build summary.

## Milestones

| Milestone | Goal | Done when |
|---|---|---|
| M0 | cadcraft builds and runs headless on this machine | `cadcraft-cli --version` prints a version |
| M1 | cadcraft can open, inspect, render and export every PSA drawing | every DWG in `$D\3. Working` and the Reference folder has a PNG and a PDF made by cadcraft, and a report of what was lost |
| M2 | Drawing checks are automatic | one script checks every drawing against the format notes and prints pass/fail per rule |
| M3 | The drawings are better | the known weaknesses list in `psa/DRAWING-WORK.md` is worked through, each item closed by a check |
| M4 | Drawings are produced by cadcraft, not by the C# generator | the same 12 sheets regenerate from cadcraft scripts and a block library |
| M5 | Fixes go upstream | every cadcraft bug found in M1 to M4 has a test and a pull request on `storytold/cadcraft` |

Work the milestones in order. A later milestone never starts while an earlier one has an open
card, except M5 cards, which you open the moment you find a cadcraft bug.

---

## M0: build cadcraft on Windows

### M0-C1 Install the Rust toolchain

Allowed: Reinach has approved installing Rust and the C++ build tools system wide.

1. Install Visual Studio Build Tools with the workload "Desktop development with C++" (this
   provides `link.exe`, which Rust on Windows needs). Download from Microsoft, run the installer,
   select that workload only.
2. Install rustup from https://rustup.rs (`rustup-init.exe`), accept the defaults
   (`stable-x86_64-pc-windows-msvc`).
3. Open a new terminal (the PATH changes after install).

Check:
```
rustc --version
cargo --version
```
Done when both print a version and `rustc` is 1.95 or newer. If older, run `rustup update`.

### M0-C2 Build the headless CLI

The desktop app needs a GPU and takes longer. The CLI is all M1 to M4 need.

```
cd <repo>
cargo build --release -p cadcraft-cli
```
The first build downloads and compiles every dependency and can take 10 to 30 minutes. Later
builds take seconds.

Check:
```
target\release\cadcraft-cli.exe --version
target\release\cadcraft-cli.exe sample bracket %TEMP%\bracket.dwg
target\release\cadcraft-cli.exe info %TEMP%\bracket.dwg
```
Done when `--version` prints, the sample DWG is written, and `info` prints JSON with an
`entities` count greater than 0.

### M0-C3 Make the CLI reachable

Add `<repo>\target\release` to the user PATH, or create `psa\scripts\cc.cmd` that calls it with the
full path. Every later card writes `cadcraft-cli` and expects it to run.

Check: from a new terminal, in any folder, `cadcraft-cli --version` prints.

---

## M1: open, inspect, render and export every PSA drawing

### M1-C1 Inventory

Write `psa/scripts/inventory.ps1`. It lists every `*.dwg` under `$D\3. Working` and under
`$D\Reference` (recursively), and writes `$D\fusion\inventory.csv` with columns
`path, size_bytes, acadver`. `acadver` is the first 6 bytes of the file as text (`AC1032` for 2018).

Check: the CSV exists, has one row per DWG, and no row has an empty `acadver`.

### M1-C2 Info for every drawing

Write `psa/scripts/info-all.ps1`. For every path in the inventory it runs
`cadcraft-cli info <path>` and saves the JSON to `$D\fusion\info\<filename>.json`. A failure
(non-zero exit) is recorded in `$D\fusion\info\FAILED.txt` with the path and the error text, and the
script continues with the next file.

Check: one JSON per DWG, or a line in `FAILED.txt`. Paste the number of successes and failures
into the changelog entry.

### M1-C3 Compare what cadcraft read with what is in the file

For each drawing, compare the `info` JSON against the private format notes and against the
reference numbers in `$D\fusion\expected.csv` (already there: per drawing, model space entity
count, layer count, named block count, layout names and the title block drawing number, as the
ACadSharp reader sees them; a row with `ERROR` is a file that reader could not open, so cadcraft
reading it is a win worth noting). Write
`psa/scripts/compare-info.ps1` that prints one line per drawing:

```
<file>  entities <read>/<expected>  layers <read>/<expected>  blocks <read>/<expected>  layouts <ok|MISSING: name>
```

Anything cadcraft reads fewer of than expected is a **loss**. Each loss is an M5 card (see below).

Check: the script runs over every drawing without error and the output is saved to
`$D\fusion\compare-info.txt`.

### M1-C4 Render every drawing to PNG

```
cadcraft-cli convert <in.dwg> $D\fusion\png\<name>.png
```
for every drawing. Then open each PNG (you can look at images) and answer, in
`$D\fusion\render-review.md`, three yes/no questions per drawing: is the title block visible,
is there text in the title block, is the drawing content visible (not an empty sheet).

Note: `convert` renders **model space**. PSA drawings keep the title block in a paper space
layout. If the title block is missing from the PNG, that is expected for model-space output, and
the next card covers it.

Check: a PNG per drawing and the review file with three answers per drawing.

### M1-C5 Export every drawing to PDF through its layout

Use `run` with the `exportpdf` command, which plots a layout:

```
cadcraft-cli run <in.dwg> --cmd "exportpdf {\"path\": \"$D\\fusion\\pdf\\<name>.pdf\", \"layout\": \"<layout name>\", \"paper\": \"A3\", \"landscape\": true, \"fit\": true}"
```

The layout name comes from the `info` JSON (`layouts`). Try `"landscape": false` for the portrait
sheets (the Reference GAD sheets).

Check: a PDF per drawing. Open each PDF as an image and confirm the title block and the drawing
both show. Record each result in `$D\fusion\render-review.md`.

### M1-C6 Round trip: open, save, re-open

For each drawing: `cadcraft-cli convert <in.dwg> $D\fusion\roundtrip\<name>.dwg`, then
`cadcraft-cli info` on the new file, then `compare-info` of the new file against the original's
info. Every difference is a loss on save and an M5 card.

Check: `$D\fusion\roundtrip-report.txt` with one line per drawing listing the differences, or
`no loss`.

---

## M2: automatic drawing checks

### M2-C1 Text extraction

Write `psa/scripts/texts.ps1`: runs `cadcraft-cli run <dwg> --cmd "texts {}"` (the `find_text`
command; confirm its id with `cadcraft-cli commands text`) and saves the JSON to
`$D\fusion\texts\<name>.json`.

Check: one JSON per drawing, each with at least one text whose value is the drawing number from
the file name (for example `NNNN-IC-GAD-001`).

### M2-C2 The rule file

Write `psa/scripts/rules.example.json`: a list of rules in this form, with made up values. The
real values live in `$D\fusion\rules.json`, which you create from `PSA_FORMAT_NOTES.md`.

```json
[
  {"id": "TB1", "kind": "attribute-present", "block": "TITLE", "tag": "DWG_NO"},
  {"id": "TB2", "kind": "attribute-equals-filename", "block": "TITLE", "tag": "DWG_NO"},
  {"id": "TB3", "kind": "attribute-present", "block": "TITLE", "tag": "REV"},
  {"id": "LY1", "kind": "layers-only-from", "layers": ["0", "TITLEBLOCK", "1C", "1T"]},
  {"id": "TX1", "kind": "text-height-min", "min": 2.5},
  {"id": "ST1", "kind": "draft-stamp-present", "text": "NOT FOR CONSTRUCTION"},
  {"id": "XR1", "kind": "cross-reference-exists", "pattern": "REFER DRG. ([A-Z0-9-]+)"}
]
```

### M2-C3 The checker

Write `psa/scripts/check-drawing.ps1 <dwg> <rules.json>`. It uses the info and texts JSON and
prints one line per rule: `PASS TB1` or `FAIL TB1 <reason>`. Exit code 0 when all pass, 1
otherwise. `check-all.ps1` runs it over every drawing and writes `$D\fusion\check-report.md`.

Rule kinds, in the order to implement them:

1. `attribute-present`: the block reference has an attribute with that tag and a non-empty value.
2. `attribute-equals-filename`: that attribute equals the file name up to `_`.
3. `layers-only-from`: every entity's layer is in the list.
4. `text-height-min`: no text or attribute is smaller than `min`.
5. `draft-stamp-present`: some text equals `text`.
6. `cross-reference-exists`: every match of `pattern` in any text names a drawing that exists in the inventory.

Check: the checker passes every rule on every drawing in `$D\3. Working`, or each FAIL is a true
problem that you then fix in M3.

---

## M3: improve the drawings

The list of known weaknesses is in `psa/DRAWING-WORK.md`. Each item there is a card. Work them in
order. Each card states what to change, where the facts come from (a datasheet, the format
notes, Reinach), and what check closes it. A fact you cannot source is a question for Reinach,
written to `psa/QUESTIONS.md`, and the card waits.

Until M4 lands, drawing changes are made in the C# generator (`AutoDraft.PsaNNNN`, in the
AutoDraft repository that Reinach points you at). Build it with `dotnet build -c Release`, run it
with the command for the sheet you changed, then run `check-all.ps1`.

---

## M4: produce the drawings with cadcraft

The target: the same 12 sheets, built by `cadcraft-cli run` from scripts and a block library,
with the real PSA blocks instead of drawn rectangles and circles.

### M4-C1 Block library

The PSA template DWG already holds the library blocks (terminal blocks, end brackets, DIN rail,
tag circle, title block). `cadcraft-cli info $D\Template\<template>.dwg` lists them under
`blocks`. Write `$D\fusion\blocks.md`: every block name, its entity count, and what it is for
(from the format notes).

Check: the list has every block the format notes mention.

### M4-C2 One sheet by script

Pick the simplest sheet (the bill of materials). Write `psa/scripts/sheets/bom.scr.example` (a
cadcraft script, no project data) and the real one in `$D\fusion\sheets\`. It opens the template,
inserts the title block attributes (`insert` with `attribs`), draws the table with `line` and
`mtext`, and saves with `saveas` to `$D\fusion\out\<name>.dwg`.

Check: `check-drawing.ps1` passes on the output, and the `exportpdf` of it shows the same table as
the C# version's PDF when you look at both.

### M4-C3 to M4-C12 The other sheets

One card per sheet, same pattern. Terminals use `insert` of the library terminal block (one insert
per terminal, the terminal number in an attribute or an `mtext` next to it), not circles.

### M4-C13 Retire the C# generator

When every sheet passes, record in the changelog that M4 is complete. The AutoDraft generator
stays in its repository, unchanged, as the reference.

---

## M5: send fixes upstream

Every loss or bug found in M1 to M4 becomes a card named `M5-<short name>`:

1. Reproduce it with a **synthetic** drawing you build by script (never a PSA file). Put the
   script in `psa/repro/<name>.scr`.
2. Find the code: `docs/file-format-parity.md` and `docs/gaps.md` say which crate reads or writes
   each thing (`crates/io`, `crates/dwg`, `crates/doc`).
3. Write the failing test first in that crate's `tests.rs`, in the style of its neighbours.
4. Fix it. `cargo xtask ci` must pass (fmt, clippy with warnings as errors, tests, assets, layers,
   wasm).
5. Commit on a branch named `fix/<name>`, push to the fork, and write the pull request text into
   `psa/pr/<name>.md`. **Reinach opens the pull request on `storytold/cadcraft`**; you do not.

Check: `cargo xtask ci` passes and the new test fails on the commit before the fix (`git stash`
is not used; check out the previous commit in a second worktree to run the test).

---

## Things that end a card early

- A file under `$D` other than `$D\fusion\...` would be modified: stop, the card is wrong.
- A command needs AutoCAD: there is none here. cadcraft is the viewer and the plotter.
- A fact is needed (a dimension, a wire colour, a pin number) and no datasheet or note gives it:
  write the question to `psa/QUESTIONS.md` and go to the next card.
- `cargo xtask ci` fails on code you did not change: record it in `psa/BLOCKED.md` with the
  upstream commit hash, then continue on a branch from the last green commit.
