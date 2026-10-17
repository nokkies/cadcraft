# -ATTEDIT: implement the Position option

## Summary

Completes the `-ATTEDIT` one-at-a-time option set. **Position** answered `Position is not available yet.`;
it now prompts `Enter new insertion point for attribute <tag>: <point>` and moves the attribute to the
picked point, matching AutoCAD. This builds on the Height/Angle/Style work (PR #1); together the four
previously-missing one-at-a-time options (Position, Height, Angle, Style) all work. Only the -ATTEDIT
**colour books** option remains "not available yet" (gaps.md F1).

## Where it comes from in the code

`crates/engine/src/cmd/blocks/attedit.rs`, the `DashAtteditM` one-at-a-time machine. The attribute's
placement is `Attrib.text.insert` (a `Vec3`, stored in drawing coordinates — the block's insert transform is
applied when the reference is made, `crates/engine/src/cmd/blocks.rs:190`). A justified attribute also carries
`Text.align_pt`; the point the text is actually placed by is `Text::justify_point()` (`crates/doc/src/entity.rs:240`).

## The change

- Added `Stage::NewPosition`, routed the `Position` keyword to it, and removed the old "not available yet"
  branch (and the `Input::Text` fallback that only existed to catch the typed option names).
- The prompt `Enter new insertion point for attribute` uses `Accept::POINT` and defaults (base point) to the
  attribute's current insertion point (new `current_insert` helper).
- On a picked point, `set_text` sets `text.insert` to the point and shifts `align_pt` by the same delta, so a
  justified attribute moves rigidly rather than re-justifying. Enter keeps the current point.

## Test

`crates/engine/tests/attedit_prompts.rs::dash_attedit_position_moves_the_attribute` builds a block reference
whose attribute T sits at world (100,1), drives `-ATTEDIT` Position to (50,60), and asserts the insert moved.
It fails before the change (Position answers "not available yet") and passes after. The existing
`dash_attedit_one_at_a_time_edits_the_selected_attributes` test now drives Position (move and back) instead of
asserting the old error.

Reproduction and synthetic setup: `psa/repro/attedit-position.scr`.

## Never-crash notes

- No `unwrap`/`expect`/`panic`; all fallible paths use `?` and `get()`.
- The point comes from the engine's own point parser (`Input::Point`), so it is always finite; no hostile
  string is parsed here.
- `cargo xtask ci` passes (fmt, clippy -D warnings, tests, assets, layers, wasm).

## Not included

- **Colour books** in -ATTEDIT Color — unchanged (still "not available yet", the last F1 prompt option).
