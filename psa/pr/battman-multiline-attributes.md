# BATTMAN: switch an attribute to and from multiline

## Summary

Multiline attributes are read, drawn and saved, but **BATTMAN could not switch an attribute definition to
multiline or back** — the Block Attribute Manager edited tag, prompt, default, modes, height and layer only.
This PR adds a **Multiline** property to BATTMAN: switching an attribute to multiline makes its current text
the multiline text (so it wraps and edits like MTEXT), and switching it back drops the multiline text. This
narrows gaps.md F17.

## Where it comes from in the code

`crates/engine/src/cmd/blocks/battman.rs`, the `edit` action and its `Change` struct. An attribute
(`crates/doc/src/entity.rs:340`) carries `multiline: Option<MultilineAttrib>`; `MultilineAttrib` is an
`MText` plus the `read_as` plain text it was read as, and `Attrib::multiline_text()` renders it (replacing the
contents with the value when the value was edited). A definition (`EntityKind::AttDef`) uses the same `Attrib`,
so the toggle lives on the definition and flows to references through the existing ATTSYNC-style sync.

## The change

- `Change` gains `multiline: Option<bool>`; the JSON `battman` edit action reads a `multiline` param.
- In `edit`, `Some(true)` on a single-line attribute builds a `MultilineAttrib` from the attribute's own
  `text` (insert, height, rotation, style) with `contents = mtext_literal(value)` and `read_as = value`;
  `Some(false)` drops `multiline`. `None` leaves it.
- The interactive editor gains a **Multiline** property (`Multiline? <Yes/No>`, defaulting to whether the
  attribute is already multiline), matching the Invisible/Constant Yes/No properties.

## Test

`crates/engine/tests/multiline_attributes.rs::battman_switches_an_attribute_to_and_from_multiline` makes a
block with a single-line LABEL definition, switches it to multiline via `battman` (asserting the definition's
`multiline` is set, `read_as`/contents are the old text, and the height carried over), inserts a reference and
asserts it carries the multiline text, then switches back and asserts `multiline` is gone. It fails before the
change (the `multiline` param is ignored) and passes after.

Reproduction and synthetic setup: `psa/repro/battman-multiline-attributes.scr`.

## Never-crash notes

- No `unwrap`/`expect`/`panic`; the MText is built from already-validated attribute fields.
- `cargo xtask ci` passes (fmt, clippy -D warnings, tests, assets, layers, wasm).

## Not included

- Creating a brand-new multiline attribute from scratch in BATTMAN (AutoCAD does this via the MTEXT-in-attribute
  editor); here BATTMAN switches an existing attribute. A new multiline attribute is still created via
  ATTFILL/MTEXT. F17's other items (verify/preset/lock modes, the data-extraction wizard) are unchanged.
