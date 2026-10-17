# Raster images (title-block logos) plot as a placeholder box, not the picture

Status: **feature gap, not a defect.** Filed as an M5 observation from the PSA drawing project so it
is measured and prioritised upstream. No PR branch is attached — the fix is a raster-image loader and
renderer, which is a feature, not a patch. This document is the reproduction and measurement; Reinach
decides whether it becomes an issue on `storytold/cadcraft`.

## Summary

The PSA title block carries two company logos as raster images. The Reference PDFs (made by the
original CAD system) show them; cadcraft's plots do not. cadcraft models an `IMAGE` entity but does
not load or draw the picture — it draws a placeholder (a rectangle with an X across it). So the
title block plots with an empty crossed box where each logo should be.

## Where it comes from in the code

- `crates/render/src/lib.rs:1190` `EntityKind::Image(i)` — the render path draws the image's
  boundary rectangle and two diagonals (`b.polyline(...)` three times), i.e. the classic "image
  frame" placeholder. It never decodes or blits the referenced bitmap.
- `crates/doc/src/entity.rs:845` `struct Image` — the entity stores a `path` (the IMAGEDEF's file
  path), placement (`insert`, `u`, `v`), pixel `size`, clip and display flags. It holds a *reference*
  to an image file, not embedded pixels, so drawing the picture needs a decoder and a file read.
- `crates/io/src/dxf_image.rs` — DXF reads/writes IMAGE, IMAGEDEF and the image dictionary, so a DXF
  round-trip keeps the reference. **The DWG reader has no IMAGE handling** (`crates/dwg/src/lib.rs`
  has no `IMAGE`/`AcDbRasterImage` case), so a DWG-sourced image is not read at all — the logos in a
  DWG template are invisible to cadcraft before rendering even starts.

So there are two gaps stacked: the DWG reader does not read IMAGE entities, and the renderer does not
draw a loaded image's pixels.

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

## The clean-room caveat for the PSA logos specifically

Even with the feature built, the two logos are the client's and a partner's **private artwork**. They
cannot be shipped in this open-source repository (AGENTS.md: no third-party artwork without an
ATTRIBUTION.md row and a redistributable licence). The feature would let cadcraft *draw* a logo the
user's own DWG references at plot time, but the logo files stay in the private project folder. So
this closes the gap for the user's own plots, not by adding the images to the repo.

## What would help the PSA project now

A raster-image render path (decode + blit with the u/v transform) would make the title block plot
with its logos when the DWG references them. The DWG IMAGE reader is the prerequisite. Both are
upstream cadcraft work; neither is closable in the PSA generator.

## Notes for whoever opens this

- Reproduce with a synthetic DXF IMAGE; do not attach a project DWG or the logo files (two-folder
  rule and the no-third-party-artwork rule).
- Cross-reference: `docs/file-format-parity.md` "Raster images attach", `docs/gaps.md`, and the PSA
  project's `psa/REVIEW-0.053.md` section 3 Q2 item 1, where this was first listed.
