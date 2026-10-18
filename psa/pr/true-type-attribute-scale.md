# TrueType text inside a scaled block renders larger than the same text at scale 1

Found while chasing why the generated GAD-001 plot carries ~8% more ink than its source. The cause is not
missing or extra content: it is that balloon tag text renders at a different size depending on the font, and
GAD-001 is the one sheet whose balloons use a TrueType style.

## The measurement

The `_TagCircle` balloon block is inserted **25 times at scale 6.0** on GAD-001, in both the source and the
generated sheet, with identical block definitions (base 0,0, 2 entities, not dynamic) and identical
reference scales. The attribute text uses style `ISOCP` → `tahoma.ttf`, `trueType: true`.

Measured on the plotted PDFs, the balloon circles:

| | balloon size | count |
|---|---|---|
| source | **9.98 mm** | 25 |
| generated | **12.51 mm** | 25 |

Ratio **1.253 ≈ 1 / 0.7986**. Same drawing data, one rendering difference, and it is uniform across all 25.

Extracted text sizes tell the same story: the source's balloons do not appear as extractable text at all,
while the generated sheet reports **4 spans at 8.62 mm** where the source has none above 1.15 mm. The
reference plots (the issued PDFs) have **no text above 4 mm** anywhere, so 8.62 mm is out of family.

## It is specific to the TrueType path

Across all twelve sheets, exactly one mismatches:

| sheet | balloon style | font | source height | generated height |
|---|---|---|---|---|
| **GAD-001** | `ISOCP` | **tahoma.ttf** | **2.5** | **15.0** |
| GAD-002 | `isocp2` | isocp2.shx | 5.0 | 5.0 |
| SCD-001..005 | `isocp2` | isocp2.shx | 2.0 | 2.0 |
| TMD-001..005 | `isocp2` | isocp2.shx | 3.0 | 3.0 |

Eleven sheets use the SHX style and reproduce the source height exactly. GAD-001 uses the TrueType style and
its height comes back as `2.5 × 6 = 15` — the block scale multiplied into the attribute height.

A synthetic test on the template's empty model space confirms the mechanism: text at height 2.5 rendered
directly measures 2.50, and the same text inside `_TagCircle` inserted at scale 6 measures **15.00**.

## What is and is not being claimed

**Claimed:** the same drawing data produces balloons 1.25× larger in the generated plot than in the source
plot, and the effect tracks the TrueType style rather than the geometry.

**Not claimed:** that AutoCAD's own output is the reference for which size is right. cadcraft cannot read
SHX, so the source's `isocp2` balloons are rendered with cadcraft's stroke font and are *not* what AutoCAD
would draw either. What is solid is the internal inconsistency — the TrueType path scales attribute text
where the stroke path does not, so two sheets that should agree do not.

## Where to look

`crates/fonts/src/ttf.rs` is where TrueType faces are resolved and measured; the stroke path in
`crates/fonts/src/stroke.rs` is the one that agrees with the source. The difference is in how an attribute's
height is combined with the enclosing `INSERT` scale on the TrueType path.

## Related, and previously corrected

`colour-stroke-fidelity.md` already noticed these same balloon glyphs and wrongly attributed them to SHX
substitution; that note corrects the attribution and records that `ISOCP` → `tahoma.ttf` is rendered
natively and never substituted. This note goes one step further and identifies the scale interaction.
