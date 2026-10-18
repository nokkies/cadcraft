# TEXT / ATTRIB ignore the text style's width factor; MTEXT honours it

## Symptom

A `TEXT` (or `ATTRIB`) entity is rendered at the style's font and height but at **width factor 1.0**, no
matter what the style says. `MTEXT` in the same style is rendered correctly.

Measured with `cadcraft-cli`, on the template's empty model space, two strings identical except for the
style's `widthFactor`:

| entity | style `widthFactor` 1.0 | style `widthFactor` 0.5 | ratio |
|---|---:|---:|---:|
| `TEXT` | 947 px | 947 px | **1.000** — ignored |
| `MTEXT` | 947 px | 474 px | **0.501** — honoured |

## Cause

`crates/render/src/lib.rs`, `place_text_entity`:

```rust
pub fn place_text_entity(d: &Drawing, t: &cadcraft_doc::Text, value: &str) -> (cadcraft_fonts::Shaped, Bounds2) {
    let ts = text_style(d, &t.style);
    let font = cadcraft_fonts::TextFont::resolve(&ts.font);
    …
    let p = cadcraft_fonts::TextParams {
        …
        width_factor: t.width_factor,      // <-- the ENTITY's field
        oblique: t.oblique,
        backwards: ts.backwards,           // <-- style, correct
        upside_down: ts.upside_down,       // <-- style, correct
    };
```

`backwards` and `upside_down` on the same struct are taken from `ts`, so the intent is clearly that
style-level generation flags come from the style. `width_factor` is the exception.

The MTEXT path just below does it right:

```rust
pub fn layout_mtext_entity(d: &Drawing, t: &cadcraft_doc::MText) -> cadcraft_fonts::MTextLayout {
    let ts = text_style(d, &t.style);
    let params = cadcraft_fonts::MTextParams {
        …
        width_factor: ts.width_factor,     // <-- the STYLE's factor
```

## Why the entity field is the wrong source here

In the DXF format a TEXT entity's group 41 is its *own* width factor, and it defaults to **1.0**. When a
drawing puts the factor on the style — which is how it is normally set — the entity still carries 1.0.
Reading `t.width_factor` therefore returns 1.0 for every such entity, and the style's value is dropped.

Note `crates/render/src/linetype_text.rs:88` already guards the style value the right way:

```rust
width_factor: if ts.width_factor.is_finite() && ts.width_factor > 0.0 { ts.width_factor } else { 1.0 },
```

## Reproduction

```
style {"name":"WF10","font":"isocp.shx","widthFactor":1.0,"current":true}
text  {"at":[0,20],"text":"WWWWWMMMMM","height":10}
style {"name":"WF50","font":"isocp.shx","widthFactor":0.5,"current":true}
text  {"at":[0,0], "text":"WWWWWMMMMM","height":10}
saveas {"path":"wf.dwg","version":2018}
```

Then `cadcraft-cli convert wf.dwf wf.png --window -10,-15,220,40` and measure the horizontal extent of
each text band. Both come out 947 px. Replacing `text` with `mtext` gives 947 and 474.

## Suggested fix

Take the style's factor, letting a non-default entity value win so an explicit per-entity factor still
works — matching how `backwards`/`upside_down` are already handled:

```rust
width_factor: if t.width_factor.is_finite() && t.width_factor.abs() > 1e-6 && (t.width_factor - 1.0).abs() > 1e-12 {
    t.width_factor
} else if ts.width_factor.is_finite() && ts.width_factor > 0.0 {
    ts.width_factor
} else {
    1.0
},
```

A simpler variant that matches MTEXT exactly is `width_factor: ts.width_factor`, which is correct for the
common case and is what `layout_mtext_entity` does.

`ATTRIB` and `ATTDEF` share `place_text_entity`, so they are fixed by the same change.

## This fix is implemented and verified

The block above is in `crates/render/src/lib.rs` in this fork, with tests in
`crates/render/tests/text_style_width_factor.rs`. Five tests:

| test | before | after |
|---|---|---|
| `text_honours_the_style_width_factor` | **FAIL** ratio 1 (90.67 vs 90.67) | pass |
| `attributes_honour_the_style_width_factor` | **FAIL** ratio 1 | pass |
| `mtext_already_honours_the_style_width_factor` | pass | pass |
| `an_explicit_entity_width_factor_still_wins` | pass | pass |
| `a_missing_or_bogus_style_factor_falls_back_to_one` | pass | pass |

The MTEXT test is deliberately included as the **reference**: it passed before the change, which is what
proves the two failures were the bug rather than a wrong expectation. The fallback test covers `0.0`,
`NaN` and an absent style, so the guard cannot collapse text to zero width.

`cargo xtask ci` passes all six steps (fmt, clippy, test, assets, layers, wasm).

Verified in the rebuilt release binary, not just the unit test — the same CLI measurement as above:

| entity | wf 1.0 | wf 0.5 | ratio |
|---|---:|---:|---:|
| `TEXT` before | 947 px | 947 px | 1.000 |
| `TEXT` after | 947 px | 474 px | **0.501** |
| `MTEXT` | 947 px | 474 px | 0.501 |

TEXT now matches MTEXT exactly.

## Impact on our drawings

None, as measured — before or after. The sheets carry their model-space text as **MTEXT** (SCD-001: 97
MText, 0 TEXT), and MTEXT already honoured the factor, which is why our generated text spacing was
already right. After the fix all twelve sheets still regenerate green and the text-style and colour
audits still pass. This is reported and fixed because it is a real parity bug that would bite any drawing
using single-line TEXT with a styled width factor, not because it affected these sheets.

