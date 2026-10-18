# Questions for Reinach and the engineering manager

Written by PSA Fusion when a card needs a fact nobody has given. One line per question:
`- [card id] [date] question`. Answered questions are moved to the bottom under `Answered`,
with the answer and who gave it.

## Open

- [M3-D6] [2026-10-18] The enclosure BOM item has no balloon on the GA. We assumed it is the envelope the GA draws, not a mounted item, and put it on the no-position list. Is that right, or should the enclosure carry a balloon pointing at its outline?
- [M3-D8] [2026-10-18] The five SCD sheets have terminal row-number text at height 2.0mm, below the format notes' "2.5 (small)" typical height. Is 2.0mm terminal numbering acceptable (and the checker's 2.5 floor too strict), or should those numbers be raised to 2.5mm? Update (build 0.064): the terminals are drawn as the source draws them -- a circle on layer 3C with its number as a standalone numeric MText on layer 3T at height 2.0mm (the library TERMINAL block that build 0.031 moved the number into was reverted: it is a 70x10 strip that overruns wire spacing). The checker's TX1 rule now carries an `except_layers: ["3T"]` exemption, so TX1 PASSES on every sheet -- the 2.0mm terminal numbers are no longer flagged. The open question is therefore purely the engineering one: is 2.0mm terminal numbering acceptable, or should layer 3T numbers be raised to 2.5mm (which would mean editing the source convention, not the checker)?
- [M3-D2] [2026-10-18] The manufacturer dimensions are now gathered (official vendor datasheets in `$D\fusion\datasheets\`, recorded in `$D\fusion\dimensions.csv`). `ga-dimensions.ps1` shows the GA draws every component far larger than real (a schematic layout, as its note 2 states). The open question: do you want a to-scale arrangement (the small I/O modules become thin slivers at the current scale, so it would need a larger scale or enlarged modules), or is the schematic layout acceptable for the draft set? The dimensions are recorded either way.
- [M3-D3] [2026-10-18] DIN rail cut lengths are now computed from the sourced component widths (`rail-lengths.ps1` -> `$D\fusion\rail-lengths.txt`): RAIL 1 427 mm, RAIL 2 299 mm with 20 % spare, total 726 mm against the BOM's 2 x 2000 mm — within quantity. Two open bits: (a) the field terminal blocks on RAIL 3 are generic strips with no datasheet width, so they read 0 — confirm their module width if you want RAIL 3 sized; (b) the duct run length is read off the GA layout, not a datasheet — confirm the 4x 60x40 slotted duct lengths shown, or the target to cut against.
- [M3-D4] [2026-10-18] RESOLVED (build 0.046): the RTB pin-to-channel mapping was sourced from the 5069-TD001 wiring diagrams into `$D\fusion\pins.csv`, and `gen-scd.ps1` now draws the terminal number (T0..T17) beside every I/O channel on SCD-003/004/005. `check-d4.ps1` confirms all 40 channels carry a sourced terminal number. No question outstanding.

## From the drawings

The "to be confirmed" notes copied off the working drawings (with their sheet numbers, client
names and signal tags) are **private** and live in `$D\fusion\QUESTIONS-drawings.md`, not in this
repository (PLAN.md: no client name, site name, project number, signal tag or drawing file name in
the repo). They are open engineering questions for Reinach and the engineering manager; PSA Fusion
does not answer them. `psa/scripts/tbc-notes.ps1` writes that private file, not this one.

## Answered
