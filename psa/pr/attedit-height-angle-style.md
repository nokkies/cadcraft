# -ATTEDIT: implement the Height, Angle and Style options

## Summary

`-ATTEDIT` (the global, one-at-a-time attribute editor) prompts `Value/Position/Height/Angle/Style/Layer/Color/Next`
for each selected attribute. **Value**, **Layer** and **Color** worked; **Height**, **Angle** and **Style**
answered `<Option> is not available yet.` This PR implements Height, Angle and Style so an attribute's text
height, rotation and text style can be edited one at a time, matching AutoCAD. **Position** (moving an
attribute's insertion point) is left as "not available yet" — it needs coordinate entry plus justification
handling and is tracked separately.

This is gaps.md **F1** ("Prompt options that still print 'not available yet': -ATTEDIT ... Position, Height,
Angle and Style"). F1 is narrowed, not closed: Position and the -ATTEDIT colour-book options remain.

## Where it comes from in the code

`crates/engine/src/cmd/blocks/attedit.rs`, the `DashAtteditM` one-at-a-time machine:

- The `Stage::Option` handler matched only `Value`, `Layer`, `Color`; the other four options were caught by a
  `later = ["Position", "Height", "Angle", "Style"]` list that returned `"<Option> is not available yet."`
- Height/Angle/Style map onto the attribute's own `Text` geometry (`crates/doc/src/entity.rs`): `Text.height`,
  `Text.rotation` (radians) and `Text.style`. `AttribProps` carries only layer/colour/linetype/lineweight, so
  these are set on `Attrib.text`, not on `props`.

## The change

- Added `Stage::NewHeight`, `Stage::NewAngle`, `Stage::NewStyle` and routed the `Height`/`Angle`/`Style`
  keywords to them; `Position` still returns "not available yet".
- Added prompts (`Enter new height for attribute`, `Enter rotation for attribute`, `Enter new text style for
  attribute`) that default to the attribute's current value (new `current_height`/`current_angle`/`current_style`
  helpers, which fall back to the block's ATTDEF the way the existing `current_props` does for layer/colour).
- Added a `set_text` helper (mirrors `set_props`) that edits `Attrib.text`.
- Height and Angle take a number (Angle in degrees, stored in radians via `to_radians`, matching every other
  angle entry in the engine); a non-number or a non-positive height is rejected with a clear message. Style is
  validated against the drawing's text styles (`Doc::text_style`, case-insensitive) and rejected if unknown,
  matching how the Layer option validates its name.
- The `Option` prompt keyword list now shows the full `Value/Position/Height/Angle/Style/Layer/Color/Next` set.

## Test

`crates/engine/src/tests.rs::attedit_one_at_a_time_sets_height_angle_style` builds a block reference with one
attribute and drives the exact command-line sequence above, asserting `height == 5`, `rotation == 90°`
(`FRAC_PI_2`) and `style == "Standard"`, and that the attribute's *value* is untouched. It fails on the commit
before the fix (Height still answers "not available yet", height stays 2.5) and passes after.

Reproduction steps and the synthetic setup are in `psa/repro/attedit-height-angle-style.scr`.

## Never-crash notes

- No `unwrap`/`expect`/`panic` added; all fallible paths use `?` and `get()`.
- Height/Angle parse through a bounded `parse_number` (rejects non-finite and non-numeric text) and reject
  non-positive height, so hostile typed input returns an error, never a panic.
- `cargo xtask ci` passes (fmt, clippy -D warnings, tests, assets, layers, wasm).

## Not included

- **Position** (move an attribute) — needs point entry + justification; left as "not available yet".
- **Colour books** in -ATTEDIT Color — unchanged (still "not available yet", part of F1).
- No changes to `AttribProps` or the file format; nothing new is written to DXF/DWG that wasn't already
  round-tripped (height/rotation/style are ordinary ATTRIB text fields).
