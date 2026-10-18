# Paper-space plots do not composite multiple viewports the way AutoCAD does

Status: **feature gap plus one saveas defect.** Filed as an M5 observation from the PSA drawing project. No PR
branch attached — this is a paper-space plotting behaviour, a feature-level difference from the
reference, not a one-line fix. Reinach decides whether it becomes an issue on `storytold/cadcraft`.

## Saveas defect: a sheet viewport is promoted into the model-window list (build 0.066)

A layout's viewport table can hold a *sheet* viewport (the paper-space window that shows the layout
itself, `viewCenter == center` and `viewHeight == height`) alongside its model windows. On a layout
that was authored with a second sheet viewport (a real PSA template has two id=1 sheet windows),
`saveas` renumbers every viewport's id sequentially by handle order, which turns the second sheet
viewport (id=1) into a model window (id=3). After the save the layout's declared viewports grow: the
template's `[30F5, 41D5]` becomes `[30F5, 41D1, 41D5]`, and 41D1 — which showed the paper — now draws
model content, so the sheet renders the same content two or three times (visible ghosting). Reproduced
with a bare `layout.set` + `saveas` on an untouched template, so it is the save, not the caller. The
expected behaviour is that a sheet viewport keeps its paper-space role across a save. Worked around
generation-side (psa/scripts/gen-*.ps1 erase every viewport but the largest sheet window and the
largest model window before saving); the underlying save should not renumber a sheet viewport into a
model window.

## Summary

A PSA sheet's paper-space layout carries several model-space viewports: one large "content" window
plus one or more small detail/zoom windows, each with its own model view. When AutoCAD plots the
layout, the page reads as one complete drawing — the assembly fills the sheet. When cadcraft
`exportpdf`s the same layout, the page shows the content cropped to one viewport's view, so a
general-arrangement sheet that AutoCAD plots as a full assembly plots as a zoomed-in sub-region.

This is not a drawing-content problem: the model space holds the whole assembly, and cadcraft's plot
of the *source working drawing* is cropped the same way as its plot of a *generated* sheet — a
faithful match. The difference is cadcraft vs AutoCAD in how a multi-viewport layout is composited
onto the plotted page.

## Reproduction (synthetic, no project data)

Build a drawing with a paper-space layout containing two model-space viewports over the same model
content, one large and one small, with different `viewCenter`/`viewHeight`:

```
cadcraft-cli run --sample \
  --cmd 'line {"points":[[0,0],[100,0],[100,60],[0,60],[0,0]]}' \
  --cmd 'mview {"option":"fit","count":2,"arrangement":"horizontal"}' \
  --cmd 'viewport.set {"handles":["<big>"],"center":[50,30],"viewHeight":80}' \
  --cmd 'viewport.set {"handles":["<small>"],"center":[50,30],"viewHeight":20}' \
  --cmd 'exportpdf {"path":"/tmp/mvp"}'
```

Compare the plotted page with AutoCAD's PLOT of the same file. AutoCAD shows both windows on the
sheet, each with its own model view; cadcraft's page does not present them the same way, so the
drawing appears cropped to a single window.

## What to look at in the code

- `crates/io/src/pdf.rs` — the layout-to-PDF path (`exportpdf`/`plot`): how it walks a layout's
  viewports and draws each window's model view onto the page. The gap is that the composite of
  several viewports (their paper positions, sizes, and per-viewport model views, including frozen
  layers and clip) is not reproduced as AutoCAD plots it.
- `crates/engine/src/cmd/layout.rs` `viewport.set` / `mview` — the viewport model cadcraft stores
  (viewCenter, viewHeight, paper center/width/height, id, frozen layers). The data is there; the
  plotting composite is what differs.

## Why it matters for the PSA project

It is the single largest remaining visual difference between the generated plots and the Reference
PDFs now that the title block, content, block scale, line breaks, monochrome colour and line density
are all handled. Closing it would make a generated GA/TMD sheet read as complete as the Reference at
a glance. It is upstream cadcraft work; reframing the content viewport in the generator was tried and
does not change the plot (the source plots identically), so it is not closable in the generator.

## Notes for whoever opens this

- Reproduce with the synthetic two-viewport layout above; do not attach a project DWG (two-folder rule).
- Cross-reference: the PSA project's `psa/BLOCKED.md` "multi-viewport paper-space plots" observation
  and `psa/REVIEW-0.053.md` section 2 (the original empty-plot investigation, where viewport views
  were first noted as an M5 item).
