# Raster images (title-block logos) plot as a placeholder box, not the picture

Status: **feature gap, not a defect — and NOT the cause of the missing logos on the PSA sheets.** Filed
as an M5 observation from the PSA drawing project. Reinach decides whether it becomes an issue on
`storytold/cadcraft`. Read "Correction: the PSA sheets have no raster images" before applying this to
the PSA project — the three code claims below are all verified true, but the sheets do not contain an
IMAGE entity, so this gap is not what makes their title blocks look bare.

## Correction: the PSA sheets have no raster images (build 0.102)

This note was written on the assumption that the title block carries two logos as raster images. Checked
against the actual sheets at build 0.102, **it does not**:

- `cadcraft-cli info` on a source working drawing reports `entityCount=328` with counts of only
  `Line=206, MText=97, Circle=17` — **no `Image` type at all**.
- `skipped.count = 0`. The reader did not drop an IMAGE entity; there was none to drop.
- The template DWG likewise reports no IMAGE.
- `blocks.list` shows no block whose name suggests a logo, and the two title-block blocks carry
  `A1 BORDER` = 152 entities and `A1 TITLE TEXT` = 79 — **vector geometry**, not a raster reference.
- The plotted PDF of a source sheet contains **0 embedded images** (`page.get_images()` is empty); the
  title-block region is 691 stroked vector items.

So the logos on these sheets are **drawn as vector linework inside the border block**, and cadcraft reads
that geometry fine. Whatever makes the generated title block differ from the source is not this gap. The
code claims below remain accurate about cadcraft in general — an IMAGE entity really does plot as a
crossed box, and the DWG reader really has no IMAGE case — but they do not apply to these drawings.

## Summary

cadcraft models an `IMAGE` entity but does not load or draw the picture — it draws a placeholder (a
rectangle with an X across it). A drawing whose title block references raster logos therefore plots with
an empty crossed box where each logo should be.

## Where it comes from in the code

All three claims verified at build 0.102:

- `crates/render/src/lib.rs:1190-1197` `EntityKind::Image(i)` — confirmed by reading it: three `b.polyline`
  calls, one closed rectangle `[o, o+u, o+u+v, o+v, o]` and two diagonals `[o, o+u+v]` and `[o+u, o+v]`.
  The classic "image frame" placeholder; it never decodes or blits the referenced bitmap.
- `crates/doc/src/entity.rs` `struct Image` — stores a `path` (the IMAGEDEF's file path), placement
  (`insert`, `u`, `v`), pixel `size`, clip and display flags. It holds a *reference* to an image file, not
  embedded pixels, so drawing the picture needs a decoder and a file read.
- The DWG reader has no IMAGE handling — confirmed by `git grep` for `AcDbRasterImage`/`IMAGE` in
  `crates/dwg/src/lib.rs`, which returns nothing. A DWG-sourced image is not read at all.
- **There is no `image` create command.** `cadcraft-cli commands image` returns `[]`. The reproduction
  below therefore cannot use the `image` command this note originally proposed; a DXF with a hand-written
  IMAGE + IMAGEDEF pair is the only route.

So there are two gaps stacked: the DWG reader does not read IMAGE entities, and the renderer does not draw
a loaded image's pixels.


## Reproduction (synthetic, no project data)

Create a drawing with an IMAGE entity (a DXF so the reader path is exercised), then plot it and look:

```
cadcraft-cli run --sample \
  --cmd 'image {"path":"logo.png","at":[0,0],"size":[100,50]}' \
  --cmd 'exportpdf {"path":"/tmp/img"}'
```

(If `image` has no JSON create command, build the DXF by hand with one IMAGE + IMAGEDEF pair from
the DXF Reference and `cadcraft-cli info` it — `info` lists the IMAGE entity, confirming it is read.)
The plotted page shows a rectangle with an X, not the picture. A DWG carrying the same IMAGE shows
nothing at all (the DWG reader drops it).

## Why it is not a quick patch

Drawing the picture means: (1) a raster decoder (PNG/JPEG at least) reachable from the render crate
without pulling a GPL dependency, (2) resolving the IMAGEDEF path and loading bytes at render time,
(3) blitting with the entity's `u`/`v` transform, clip, brightness/contrast/fade, and (4) reading
IMAGE from DWG. Each is real work; together they are a rendering feature tracked in `docs/gaps.md`
("Raster images attach", `docs/file-format-parity.md`).

## The clean-room caveat

A raster render path would need to decode files the user's DWG references at plot time. Any logo itself
stays private artwork and cannot be shipped in this open-source repository (AGENTS.md: no third-party
artwork without an ATTRIBUTION.md row and a redistributable licence). The feature would draw a logo the
user's own DWG references; it would not add images to the repo.

## What would help the PSA project now

**Nothing, on current evidence.** The measured sheets carry no IMAGE entity and no embedded images, so
this gap does not affect them (see the correction at the top). If a future PSA drawing does reference
bitmaps, this becomes relevant again; until then it is a general cadcraft parity item, not a blocker on
these sheets. The real remaining difference between a generated plot and the source plot on these sheets
is the detail viewports erased at build 0.066 -- see `multi-viewport-plot.md` and the saveas defect there.

## Notes for whoever opens this

- Reproduce with a synthetic DXF IMAGE; do not attach a project DWG or any logo files (two-folder rule
  and the no-third-party-artwork rule).
- There is no `image` create command, so the DXF must be written by hand.
- Cross-reference: `docs/file-format-parity.md` "Raster images attach", `docs/gaps.md`.
