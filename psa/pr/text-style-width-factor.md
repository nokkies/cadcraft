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

## Impact on our drawings

None, as measured. The sheets carry their model-space text as **MTEXT** (SCD-001: 97 MText, 0 TEXT), and
MTEXT already honours the factor — including the source's `Romans` style at `widthFactor 0.9`, which is
why our generated text spacing is right. This is reported because it is a real parity bug that would bite
any drawing using single-line TEXT with a styled width factor, not because it affects these sheets.
