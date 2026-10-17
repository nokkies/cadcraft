# -RENAME: rename a viewport configuration

## Summary

`-RENAME` (and the JSON `rename` command) could rename blocks, layers, linetypes, text styles, dimension
styles, multileader styles, table styles, named views and named UCSes — but **not a viewport configuration**:
choosing the `VPort` type printed `Renaming a viewport configuration is not available yet.` This PR makes
`VPort` rename a saved model-space viewport configuration, matching the other named tables. Materials and
plot styles remain "not available yet" (gaps.md F1).

## Where it comes from in the code

`crates/engine/src/cmd/props/rename.rs`. The `TYPES` table drives the `-RENAME` type prompt; each row carries
an optional `rename` table name (`None` = "not available yet"). A viewport configuration is a `VportConfig`
(`{ name, tiles }`) in `Drawing::vports` (`crates/doc/src/tables.rs:832`) — a standalone named set of tiles,
not referenced by any entity, so renaming one is simpler than renaming a view or UCS (no `repoint` pass). The
`*Active` configuration is the one currently shown and must not be renamed.

## The change

- `simple()` (the shared rename path for the standalone named tables) gains a `"vport"` arm over
  `d.vports` excluding `*Active`. The existing guards apply: `valid_name` rejects a `*`-prefixed new name
  (so `*Active` can't be a target), the duplicate-name check and the "no such name" error already work.
- `exists()` gains a `"vport"` arm (so `-RENAME` re-prompts on an unknown old name, and `*Active` is not
  offered as an old name).
- `TYPES`: the `VPort` row's table goes from `None` to `Some("vport")`.
- `run_rename` (`crates/engine/src/cmd/props.rs`) routes `table: "vport"` to `rename::simple`.

## Test

`crates/engine/tests/rename_cmdline.rs::rename_viewport_configuration` saves a two-tile configuration "Two",
renames it (JSON `table: "vport"`) to "Pair", asserts `*Active` is untouched, that `*Active`/unknown/duplicate
targets are refused, and that typed `-RENAME VP Pair Trio` works. It fails before the change ("unsupported
table" / "not available yet") and passes after. The existing `rename_prompts_type_old_and_new_name` test now
uses `Material` (still unavailable) for its "not available yet" check instead of `VPort`.

Reproduction and synthetic setup: `psa/repro/rename-viewport-config.scr`.

## Never-crash notes

- No `unwrap`/`expect`/`panic`; the change is a few match arms over existing iterators.
- `cargo xtask ci` passes (fmt, clippy -D warnings, tests, assets, layers, wasm).

## Also in this PR (docs only)

`docs/gaps.md` F15 was stale: it claimed "MVIEW Restore prints 'not available yet'", but MVIEW Restore and
-VPORTS Save/Restore/Delete/List are implemented and tested (`followups_626.rs`). The F15 row is corrected to
cover only the real remaining gap (a clipped viewport and its clip boundary move/scale separately).

## Not included

- **Material** and **Plotstyle** rename — still "not available yet" (the last two F1 `-RENAME` types).
