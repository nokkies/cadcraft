# Questions for Reinach and the engineering manager

Written by PSA Fusion when a card needs a fact nobody has given. One line per question:
`- [card id] [date] question`. Answered questions are moved to the bottom under `Answered`,
with the answer and who gave it.

## Open

- [M3-D6] [2026-10-18] BOM item 7 (the RAL7035 1000x800x300 IP66 enclosure) has no balloon on the GA. We assumed it is the envelope the GA draws, not a mounted item, and put it on the no-position list. Is that right, or should the enclosure carry a balloon pointing at its outline?
- [M3-D8] [2026-10-18] The five NNNN SCD sheets have terminal row-number text at height 2.0mm, below the format notes' "2.5 (small)" typical height. Is 2.0mm terminal numbering acceptable (and the checker's 2.5 floor too strict), or should those numbers be raised to 2.5mm? We left the checker flagging it rather than relax the rule. Update (build 0.031): moving terminal numbers into the TERMINAL block's TERM_NO attribute (5mm) resolved TX1 on SCD-001/003/004/005. Only SCD-002 still flags it — its 9 small texts are terminal-strip row numbers on layer 3T drawn *without* an adjacent terminal circle, so they stay as 2.0mm text. The question stands for those.
- [M3-D2] [2026-10-18] The manufacturer dimensions are now gathered (official Rockwell datasheets in `$D\fusion\datasheets\`, recorded in `$D\fusion\dimensions.csv`). `ga-dimensions.ps1` shows the GA draws every component 3-27x larger than real (a schematic layout, as its note 2 states). The open question: do you want a to-scale arrangement (the 12 mm Compact 5000 I/O modules become 4-unit slivers at 1:3, so it would need a larger scale or enlarged modules), or is the schematic layout acceptable for the draft set? The dimensions are recorded either way.
- [M3-D3] [2026-10-18] DIN rail cut lengths are now computed from the sourced component widths (`rail-lengths.ps1` -> `$D\fusion\rail-lengths.txt`): RAIL 1 427 mm, RAIL 2 299 mm with 20 % spare, total 726 mm against the BOM's 2 x 2000 mm — within quantity. Two open bits: (a) the field terminal blocks on RAIL 3 are generic strips with no datasheet width, so they read 0 — confirm their module width if you want RAIL 3 sized; (b) the duct run length is read off the GA layout, not a datasheet — confirm the 4x 60x40 slotted duct lengths shown, or the target to cut against.
- [M3-D4] [2026-10-18] RESOLVED (build 0.046): the RTB pin-to-channel mapping was sourced from the 5069-TD001 wiring diagrams into `$D\fusion\pins.csv`, and `gen-scd.ps1` now draws the terminal number (T0..T17) beside every I/O channel on SCD-003/004/005. `check-d4.ps1` confirms all 40 channels carry a sourced terminal number. No question outstanding.

## From the drawings

Drawing notes marked to be confirmed are listed in the private folder: `$Dusion\QUESTIONS-drawings.md`.

## Answered
