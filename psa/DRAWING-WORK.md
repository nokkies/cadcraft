# Drawing work list (M3)

Known weaknesses of the current draft drawing set, in the order to fix them. Each item is one or
more builds. Project facts (part numbers, signal names, client names) are in the private folder
`$D`; this list names only the kind of fact and where it comes from.

Legend: **Source** is where the correct value comes from. **Check** closes the item.

## D1 Terminal symbols

Now: schematic sheets draw each terminal as a circle with a number; termination sheets draw a
rectangle. PSA issued drawings use library blocks (the format notes list their names).

Source: the block names and the inserts in the Reference issued drawings
(`cadcraft-cli info` on them shows `blocks` and the `Insert` entities with block names).

Change: in the generator (until M4) insert the library terminal block instead of drawing a circle
or rectangle; in M4, `insert` it by script.

Check: `query_entities` on each schematic and termination sheet returns no `Circle` on the
terminal layer and at least one `Insert` whose block name is the terminal block.

**DONE (M4, build 0.022).** `psa\scripts\gen-scd.ps1` rebuilds each SCD sheet and replaces every
3C terminal circle with an `insert` of the library `TERMINAL` block. On the generated sheets the
3C circle count is 0 and the TERMINAL insert count is 15/1/18/17/12 for SCD-001..005, so the check
passes. (The TMD sheets are terminal *schedules* — tables, not symbols — so D1 does not apply to
them; see the build 0.020 note.)


## D2 Component outline sizes on the general arrangement

Now: every component is a nominal rectangle.

Source: manufacturer datasheets for each BOM item (dimensions H x W x D in mm). Save each datasheet
PDF under `$D\fusion\datasheets\` and record the page and the numbers in `$D\fusion\dimensions.csv`
with columns `item, part, width_mm, height_mm, depth_mm, source_file, page`. A number without a
source row is not used.

Check: every rectangle on the GA matches `dimensions.csv` to within 1 mm at the drawing scale.

**PARTIALLY DONE (build 0.043).** Reinach authorised internet searches, so the manufacturer
dimensions are now gathered: `$D\fusion\datasheets\` holds the official Rockwell PDFs and
`$D\fusion\dimensions.csv` records real H x W x D for items 1, 5, 6, 7 (fully sourced) and the
5069 I/O form factor for 2/3/4. `psa\scripts\ga-dimensions.ps1` measures each labelled GA box
against dimensions.csv at the 1:3 scale. It reports every component SCHEMATIC (drawn 3-27x real):
the GA is a schematic layout (note 2: "COMPONENT OUTLINES AND POSITIONS ARE NOMINAL"), so a 12 mm
I/O module is a 4-unit sliver at 1:3 and is correctly drawn as a placeholder box. The remaining
D2 question is whether a to-scale arrangement is wanted (it would need the modules enlarged or the
scale changed) -- raised in psa/QUESTIONS.md.

## D3 DIN rail and duct lengths

Now: rail and duct lengths are guesses. The BOM gives quantities in whole lengths.

Source: `dimensions.csv` (component widths, D2) plus 20 % spare rail per row; duct from the GA
layout itself.

Check: a note on the GA lists the rail and duct cut lengths and the total is at or below the BOM
quantity. If it is above, write the shortfall to `psa/QUESTIONS.md`.

**PARTIALLY DONE (build 0.044).** `psa\scripts\rail-lengths.ps1` groups the GA's balloons by rail
band, sums each rail's real component widths from `dimensions.csv`, adds 20 % spare, and compares to
the BOM DIN-rail quantity (item 13). Result (written to `$D\fusion\rail-lengths.txt`): RAIL 1 = 356 mm
(SPD + 25 A MCB + RCBO + 6 x 10 A MCBs + PSU) -> 427 mm with spare; RAIL 2 = 249 mm (PLC + IB16 +
OB16 + OF4 + switch) -> 299 mm; total 726 mm vs the BOM's 2 x 2000 mm = 4000 mm, so within quantity.
RAIL 3 (field terminals) has no widthed components, so it reads 0 -- the field terminal blocks are not
in `dimensions.csv` (they are generic terminal strips, not sized by a Rockwell datasheet). Duct length
still comes from the GA layout (open). The rail cut lengths are computed but not yet drawn as a GA note.

**DONE (build 0.047).** `gen-scd.ps1` now draws the rail cut-length note on the GA itself (RAIL 1 427 mm,
RAIL 2 299 mm, TOTAL 726 mm vs BOM 4000 mm), matching `rail-lengths.ps1`. The D3 check ("a note on the GA
lists the rail and duct cut lengths and the total is at or below the BOM quantity") is met for the rails.
Remaining: duct length is read off the GA layout (not a datasheet) and RAIL 3 field terminals have no
datasheet width -- both raised in psa/QUESTIONS.md, not blockers to the rail result.

## D4 Module terminal pin numbers

Now: I/O schematics show channel names (IN 0, OUT 0, CH0 I+) and no removable terminal block pin
numbers.

Source: the manufacturer's I/O module user manual for the module family in the BOM (find the
publication on the manufacturer's literature site; save it under `$D\fusion\datasheets\`). Record
`module, channel, pin, label` in `$D\fusion\pins.csv`.

Check: every channel on the schematic sheets has a pin number that matches `pins.csv`.

**PARTIALLY DONE (build 0.045).** The 5069-TD001 wiring diagrams (pages 8/14/33) were read with the
vision model and the RTB terminal-to-channel mapping recorded in `$D\fusion\pins.csv`: IB16 terminals
0-15 = IN 0-15 (shared common, return to SA(-)), OB16 terminals 0-15 = OUT 0-15 + LA+/LA- on 16/17,
OF4 terminals 0-7 = CH0-CH3 +/- + shield grounds on 16/17. `psa\scripts\check-d4.ps1` cross-references
each I/O schematic's channels against pins.csv: SCD-003 16/16, SCD-004 16/16, SCD-005 8/8 mapped, 0
unmapped.

**DONE (build 0.046).** `gen-scd.ps1` now annotates each I/O channel with its RTB terminal number
(a small "Tn" label to the left of the channel name), sourced from pins.csv: SCD-003 gets 16 T-numbers
(T0-T15), SCD-004 16, SCD-005 8. `check-d4.ps1` confirms all 40 channels now show a terminal number,
and a render of SCD-003 shows the T-numbers legible and clear of the channel names and lines. The full
`gen-all.ps1` pipeline stays green (12 sheets, all checks pass).

## D5 Wire numbers appear on both schematic and termination sheets

Now: wire numbers were typed on both sets by hand in the generator.

Source: the schematic sheets are the master.

Check: for every wire number text found on a termination sheet (`find_text` matching the wire
number pattern in the format notes), the same text exists on a schematic sheet. Write
`psa/scripts/wire-consistency.ps1` and run it in `check-all.ps1`.

**DONE (build 0.021, re-verified in gen-all).** `psa\scripts\wire-consistency.ps1` reports 0 orphan
wire numbers over the generated set (every termination-sheet wire number exists on a schematic); it
runs inside `gen-all.ps1`'s check suite and is green.

## D6 Item balloons match the bill of materials

Check: every balloon number on the GA (the tag-circle inserts' attribute) is an item number on the
BOM sheet, and every BOM item appears at least once on the GA or is on the list of items that have
no position (allowances, labels, cables). Write `psa/scripts/balloons.ps1`.

**DONE (build 0.023, re-verified in gen-all).** `psa\scripts\balloons.ps1` confirms every balloon is a
BOM item and every positioned BOM item is ballooned; the no-position items (7, 13, 14, 17) are listed.
Green in `gen-all.ps1`. (Item 7's enclosure balloon is the open M3-D6 question in psa/QUESTIONS.md.)

## D7 Cross references resolve

Check: rule `cross-reference-exists` (M2) passes on every sheet.

**DONE (build 0.019, re-verified in gen-all).** `check-drawing.ps1` rule `XR1` (cross-reference-exists)
passes on every generated sheet; green in `gen-all.ps1`'s check-all -Dir run.

## D8 Text heights

Check: rule `text-height-min` passes; the minimum comes from the format notes.

**OPEN (M3-D8 question).** `check-drawing.ps1` rule `TX1` (text-height-min, 2.5mm floor) passes on all
sheets except SCD-002, whose 9 terminal-strip row numbers are 2.0mm text drawn without an adjacent
terminal circle. Reinach answered "I don't know" (build 0.041 round), so the checker keeps flagging it
rather than relaxing the rule; the question stays open in psa/QUESTIONS.md.

## D9 Open engineering questions stay visible

Each sheet carries notes marked "to be confirmed". Collect them into `psa/QUESTIONS.md` under the
heading `From the drawings`, one line each with the sheet number. The list is for Reinach and the
engineering manager; you do not answer them.

Check: every "TBC" or "TO BE CONFIRMED" text found by `find_text` has a line in `QUESTIONS.md`.

**DONE (build 0.024, re-verified in gen-all).** `psa\scripts\tbc-notes.ps1` collects every TBC note
into psa/QUESTIONS.md (35 entries, idempotent, skips generated captures); green in `gen-all.ps1`.

## D10 Fonts

Now: text uses the styles the template defines (SHX fonts). cadcraft does not parse SHX, so its
render substitutes its own stroke font and the text widths differ from AutoCAD's.

Check: nothing to fix in the drawings. Record the width difference you observe between the
cadcraft PNG and the Reference PDFs in `psa/BLOCKED.md` as an M5 observation, with a synthetic
example, so it can be measured upstream.
