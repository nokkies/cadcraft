# Rule-engine verification: which rules were proven to bite

`check-drawing.ps1` implements six rule kinds over 13 rules in `rules.json`. A rule that cannot fail is
worthless, and last round showed how easily a guard passes without ever having been tested. So each kind
was violated on a throwaway copy, the bad state **read back** to confirm it landed, and the checker run.

| kind | rule(s) | violation injected | landed? | result |
|---|---|---|---|---|
| `attribute-present` | TB4 (`DWG_TITLE`) | blanked the attribute | read back `''` | `FAIL TB4 no attribute with tag DWG_TITLE`, exit 1 |
| `attribute-equals-filename` | TB2 (`DWG_NO`) | copy renamed `tiny.dwg` | n/a | `FAIL TB2 DWG_NO='<the sheet number>' != 'tiny'`, exit 1 |
| `text-height-min` | TX1 (min 2.5) | added a text at height 0.4 | read back `0.4` | `FAIL TX1 1 text(s) below 2.5`, exit 1 |
| `draft-stamp-present` | ST1 | erased the two stamp texts | read back 0 remaining | `FAIL ST1 no text equals the stamp`, exit 1 |
| `layers-only-from` | LY1 | created layer `ZZ-NOTALLOWED` | read back: present in the layer table | `FAIL LY1 layers not in list: ZZ-NOTALLOWED`, exit 1 |
| `cross-reference-exists` | XR1 | added `REFER DRG. <a number not in the inventory>` | read back: text present | `FAIL XR1 refs to unknown drawings: <that number>`, exit 1 |

**All six kinds proven.** Every bad state was read back before the checker was run, so no result below
rests on a violation that silently failed to land.

## XR1 also passes a valid reference

A rule that always fails is as useless as one that never fails, so XR1 got a positive control as well:
the same text with a drawing number taken from the inventory produced `PASS XR1`. It discriminates rather
than rejects everything. (The run still exited 1, correctly, on TB2 — the copy's file name no longer
matched its own number.)

## What each kind actually reads

- `attribute-present` / `attribute-equals-filename` / `text-height-min` / `draft-stamp-present` read the
  captured texts JSON, paper space first then model.
- `layers-only-from` reads the **layer table** from the info JSON, not the layers entities sit on. cadcraft's
  `info` lists the layer TABLE, and a layer used by an entity but missing from the table cannot exist.
- `cross-reference-exists` applies `pattern`'s capture group to every text and looks the result up in the
  inventory CSV.


## Two things this corrected in my own reading

**The captures are nested, not flat.** `fusion/texts/<name>.json` holds `{drawing, path, layout, model:
{count, texts}, paper: {count, texts}}`. Piping it into `Where-Object { $_.tag }` returns nothing, because
the entries are `model`/`paper` objects, not texts — which briefly looked like "the title-block rules see
no attributes and pass vacuously". They do not. The paper texts carry `tag=DWG_TITLE`, `DWG_NO`, `REV`,
`SCALE` and more, 18 entries on SCD-001. The rule was sound; my query was wrong.

**Rule ids do not map to tags in order.** Blanking `DWG_TITLE` fired **TB4**, not TB1, and TB1 stayed
PASS. TB1 checks `DWG_NO`. Reading the rule table before interpreting a report is not optional.

## Where the data comes from

`check-all.ps1` captures the info/texts JSON for each drawing itself (line 50, via `capture-json.ps1`)
before checking, so the captures are refreshed by the gate rather than left stale. Verified: all 12
generated-sheet captures were newer than the DWGs they describe.

## Wiring

`check-drawing.ps1` is not called by `gen-all.ps1` directly — it is invoked by `check-all.ps1` (line 37),
which `gen-all` calls as `check-all -Dir`. Not an orphan.
