# Elethe priced quoteical drawing pack generation — architecture

How a set of panel shop drawings gets produced from project data, and why the pieces sit where they
do. Written against the an NNNN panel job (20 PLC panels, 262 termination sheets) but the design carries
to any panel job: nothing in the pipeline holds a project fact.

## The problem in one paragraph

A panel job's drawing set is 20 general arrangements, 35 schematics and 262 termination diagrams,
one per I/O card. Every termination diagram is the same table with different rows: the card's
channels, each with its tag, address, module pin, terminal, wire number, cable and field device. The
rows come from an I/O list someone else maintains; the card identity comes from an order schedule;
the sheet identity comes from a document register. Drawing 262 of these by hand is roughly 1,250
hours. The machine can draw the table; the work is getting the three sources into one place and
agreeing.

## Layers

```
  project data (xlsx, private, on the file share)
      |
      |  xlsx-dump.ps1            OOXML -> CSV, no Excel, no openpyxl
      v
  dumped sheets (CSV)
      |
      +-- io-normalise.ps1         the I/O list -> one tidy signal table
      +-- sheets-plan.ps1          the register -> one row per drawing to produce
      +-- (order schedule, spare capacity: read directly)
      v
  data model (CSV + JSON, all private)
      |
      |  hardware/modules.json     one definition per order number
      v
  the producers, one per discipline:
      gen-tmd-data.ps1             termination diagram  (table, from the I/O list)
      gen-gad-data.ps1             general arrangement  (placement, from the order schedule)
      gen-scd-power.ps1            power schematic      (radial tree, from the order schedule)
      gen-scd-earth.ps1            earthing schematic   (earth bar + ways, from the order schedule)
      |
  gen-pack.ps1                     the loop: pick generator by discipline (SCD by title), manifest, logs
      |
  check-pack.ps1                   P1..P10 over the whole pack (discipline-aware)
      v
  the pack (DWG + PDF) and a hand-back report
```

Two rules hold the layers apart:

- **The generators never read a spreadsheet.** They read CSV and JSON. Every hostile thing about the
  spreadsheets (merged headers, padding inside values, a title row under the header, quoted commas)
  is fixed once, in the dump and normalise step, where it can be tested against the real file.
- **No script in the repository holds a project fact.** The register number, the panel names, the
  drawing file names all arrive as arguments. This is the cadcraft fork's rule (`psa/PLAN.md`, "Two
  folders, two rules") and it is what makes the pipeline reusable on the next job.

## The two kinds of generator, and why both exist

There is a fork in the design that is easy to get wrong, so it is stated.

**Reproducers** (`gen-tmd.ps1`, `gen-scd.ps1`, `gen-bom.ps1`) read an existing hand-drawn DWG and
rebuild it with cadcraft commands. They answer "can our renderer reproduce a real PSA sheet
faithfully?" They are the fidelity harness: 37 checks compare the rebuild against the source on
entity counts, ink, text heights, viewports, blocks, linetypes. They cannot produce a drawing nobody
has drawn.

**Producers** (`gen-tmd-data.ps1`) take no source drawing. Sheet identity comes from the register,
rows from the I/O list, the module's pins from the hardware library. This is what NNNN needs, because
the designer issued no termination drawings — producing them *is* the deliverable.

A producer is checked differently. A reproducer's oracle is the source drawing; a producer has no
source, so its oracle is **the data it came from** (does every I/O row appear exactly once?) plus
**the standard** (is the text the right size, is the content inside the border, is the title block
filled?). That is what `check-pack.ps1` does.

## The sheet model

A generated sheet is:

- the **template's** `A1 BORDER` and `A1 TITLE TEXT`, untouched, in paper space, with attributes set
  by `attedit` on the template's own insert handle;
- **model space content** drawn in paper units on the A1 frame (841 × 594), a table of `line` and
  `text` commands on the convention's layers (`3C` rules, `2T` text, `1T` wire numbers, `3T`
  references, `5T` headings);
- the **template's own content viewport**, reframed on the drawn table;
- the **draft stamps** in paper space on `Preliminary Not For Construction`.

The table is drawn, not built from graphical terminal symbols. That matches how the RRRR TMDs are
actually constructed (a drawn table of lines and text) and it is what makes the sheet reviewable: a
reviewer reads rows, not symbols.

### Fitting the table to the sheet

Row pitch is the one layout number that decides whether a sheet looks right. The convention gives 25
to 27.5 for digital and 75 for analogue, but those are the pitches of a *hand-drawn* sheet where one
row carries a terminal symbol, a wire and a hop. A data row is one line of text.

The first attempt only ever shrank the pitch to fit, which left an 8-channel card with text sitting
in the bottom third of a 53-unit band. The second scaled up from a fixed base and produced 70 for an
8-row card and 13 for a 32-row card — two densities in one pack, and the dense one illegible.

The rule that works: pitch = available height ÷ row count, **clamped** to [14, 26] digital and
[18, 40] analogue. Every sheet in a pack then sits inside one band, and a card that needs more rows
than fit at the floor is reported on the sheet rather than squeezed below it.

## Data decisions that carry weight

**The register is the master, and it is read, never edited.** Sheet numbers, titles, revisions and
budgeted hours all come from it. Titles are the only place the *card* a TMD belongs to is written
down ("... SM1221 DI16 (1 OF 3)"), so the card and the instance number are parsed out of the title
text — and that parse is what turns 262 titles into 262 sheets with the right rows on each.

**The I/O list's row count was wrong, not the I/O list.** The handover records that the I/O list
appears short against the priced I/O counts (P19 259 rows found vs 304 used; P22 327 vs 352).
Normalising properly recovers 304 and 352 exactly, and the total across all stations reproduces the
the priced quote's point counts. The gap was in how rows were being counted, not in the data. That is worth
knowing before anyone chases the client for missing sheets.

**A sheet shows every channel it owns.** An early version capped a sheet at 22 rows so the table
would fit inside the border, and silently dropped 10 of the 32 terminals on every DI32 card. A
termination diagram missing 10 terminals is not a tidy sheet, it is a wrong one. The cap is gone;
the pitch fits instead. `check-pack.ps1` P5 exists to keep it from coming back: every I/O row must
appear on exactly one sheet, and a dropped or duplicated channel fails the pack.

**Unverified is a state, not a failure.** A pinout not checked against the manual for that exact
order number still generates a sheet — the channel count, terminal numbering and strip layout come
from the order schedule, which is the hardware truth for the job — and the sheet prints
`PINOUT UNVERIFIED - CHECK AGAINST <manual>` in red. The drafter reviews a sheet that says what it
does not know.

**Spares are drawn, not deleted.** A channel the card has and the I/O list does not name is drawn as
`SPARE`. A row with no tag prints its address rather than a blank, so the reviewer sees what is
unknown instead of guessing whether the row is missing or empty. Nothing is invented to fill a gap.

## Verification strategy

| Question | Evidence |
|---|---|
| Does the renderer reproduce a real PSA sheet? | the RRRR regression: 12 sheets, 37 checks, worst ink drift 0.0% |
| Does a produced sheet match its data? | `check-pack.ps1` P5/P6: every I/O row placed exactly once, row counts match the plan |
| Does it obey the standard? | P2/P3 title block, P4 inside the border, P8 text heights, P9 draft stamp |
| Is the pack complete? | P10 against the register's own sheet list |
| Does it look right? | render to PNG and look. Structural checks are supporting evidence; the plot is the check |

## What is produced, and what is not

Four producer disciplines now exist: **termination diagrams** (`gen-tmd-data.ps1`, a table from the I/O
list), **general arrangements** (`gen-gad-data.ps1`, a placement diagram from the order schedule),
**power-distribution schematics** (`gen-scd-power.ps1`, a radial AC/DC tree from the order schedule's
power devices), and **panel earthing schematics** (`gen-scd-earth.ps1`, an earth bar with a way per
earthed item). On the current job that is 262 + 23 + 35 = 320 of the register's 367 sheets, and every
CAD discipline the register lists is produced.

What is not:

- **The AC final circuits on the power schematic.** The breakers and what each feeds are electrical-
  distribution data, not in the automation order schedule (which lists modules, PSUs and switches). The
  power schematic draws the AC bus and states that the branch count and ratings come from the electrical
  BOM, rather than inventing them.
- **Pinout verification.** The S7-1200 G2 and S7-1500 manuals are not on the machine. The channel counts
  are right (they come from the order schedule); the terminal-to-pin assignment is provisional and says
  so on the sheet.
- **The S7-300-to-S7-1500 adapter pin map.** The manufacturer publishes which adapter suits which module
  and no pin map. For the retrofit-into-existing-racks panel this is the one thing that genuinely needs
  the vendor or the physical adapter before the sheets can be issued.
- **I/O rows with no tag.** Some rows carry an address and no tag. They are drawn untagged and counted in
  a note. The FDS cross-reference tables and the SCADA data tables are the next source and are not yet in
  hand.
- **Non-CAD disciplines.** The register also lists reports, manuals, procedures, lists and schedules
  (REP, MAN, PRO, LST, and a few one-off types). Those are documents, not drawings; the list-type ones
  are already produced as CSV by the extract step and would render through the branding skills, not the
  CAD producers.

A note on a wrong assumption corrected: the 15 sheets first labelled "I/O signal schematic, needs a
routing engine" were not that. The register's "PANEL SCHEMATIC DIAGRAM" rows are earthing schematics, a
regular bar-and-ways structure that produces cleanly. The lesson is recorded in the skill: check what the
reference sheet actually contains before declaring a discipline unproducible.


