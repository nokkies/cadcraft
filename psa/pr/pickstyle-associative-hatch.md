# PICKSTYLE: make the associative-hatch bit work

## Summary

`PICKSTYLE` has always accepted values 0–3, where bit 1 is group selection and bit 2 is associative-hatch
selection — but **only bit 1 did anything**. With `PICKSTYLE` 2 or 3, picking a boundary object did not bring
the associative hatch made from it; the bit was stored and ignored. This PR implements bit 2: with it on,
picking (or windowing) an object that an associative hatch was made from also selects that hatch, matching
AutoCAD. This closes the last "stored but unused" note on gaps.md F16.

## Where it comes from in the code

`crates/engine/src/cmd/groups/pick.rs`, `expand()` — the pass that widens a picked handle set for selection.
It only checked `pickstyle & 1` (group selection) and returned early otherwise. An associative hatch
(`crates/doc/src/entity.rs:747`) has `associative: true` and, in each `HatchLoop`, a `sources: Vec<Handle>`
(the boundary objects the loop was made from, DXF group 330) — the data the bit needs was already there.

## The change

- `expand()` now treats the two bits independently: bit 1 widens to whole selectable groups (unchanged),
  bit 2 adds every associative hatch whose `loops[].sources` contains a picked handle. The early return now
  fires only when neither bit is on (or nothing was picked, or the running command picks single members).
- The `PICKSTYLE` result message reports both bits: `<Group selection on, associative hatch off>`.

## Test

`crates/engine/tests/group_selection.rs::associative_hatch_is_picked_with_its_boundary` makes a 10×10 square
of four lines, hatches it by picking inside (the hatch associates to the lines), sets `PICKSTYLE` 2, clicks a
boundary line and asserts the hatch is selected too; then sets `PICKSTYLE` 0 and asserts the line alone is
selected. It fails before the change (only the line is picked) and passes after. The existing group-selection
tests still pass (bit 1 behaviour unchanged).

Reproduction and synthetic setup: `psa/repro/pickstyle-associative-hatch.scr`.

## Never-crash notes

- No `unwrap`/`expect`/`panic`; the new loop iterates the store and uses `contains`/`insert` on collections.
- `cargo xtask ci` passes (fmt, clippy -D warnings, tests, assets, layers, wasm).

## Not included

- The other F16 items (group bounding box / single grip via GROUPDISPLAYMODE, copying a group making a new
  group, the Object Grouping dialog) are unchanged.
