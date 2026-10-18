//! WBLOCK writes the drawing with its base point at the origin (INSBASE 0,0,0), for selected
//! objects and for a block, where `base` overrides the block's own base point.
//!
//! The base-point assertions read a synthetic text format, which is fine for the offset but cannot say
//! anything about what the written drawing CONTAINS. The second test therefore inspects the Drawing handed
//! to the writer directly: the bug it guards is that WBLOCK used to clone the whole source block table into
//! the output, so every extracted file carried the parent's entire block library and a later
//! `insert {file: ...}` redefined those names in the target instead of adding the new block.
//!
//! WHY ONE TEST AND NOT TWO. `set_io` installs process-global hooks, so two tests in this file that install
//! different hooks race: `cargo test` runs them on parallel threads, and whichever installed last wins for
//! both. Splitting them produced a failure on four of six runs, with the base-point test reading the other
//! hook's output. Both cases therefore live in one test function, which installs one hook and asserts both
//! things. Do not split them again for tidiness.

use cadcraft_engine::Session;
use cadcraft_engine::cmd::file::{IoHooks, set_io};
use cadcraft_engine::doc::{Drawing, EntityKind};
use serde_json::json;
use std::sync::{LazyLock, Mutex};

/// The block names and model-entity count of the last Drawing handed to the writer.
static CAPTURED: LazyLock<Mutex<Option<(Vec<String>, usize)>>> = LazyLock::new(|| Mutex::new(None));

/// Writes "INSBASE x,y;line ax,ay" for each line, and records the block table and model count on the way
/// past so the assertions can reach them without a second hook.
fn write(d: &Drawing, _path: &str) -> Result<Vec<u8>, String> {
    let ins = d.header.point("INSBASE").ok_or("no INSBASE")?;
    let mut out = format!("{},{}", ins.x, ins.y);
    for e in d.model.iter() {
        if let EntityKind::Line(l) = &e.kind {
            out.push_str(&format!(";{},{}", l.a.x, l.a.y));
        }
    }
    let names: Vec<String> = d.blocks.iter().map(|(k, b)| k.clone().max(b.name.clone())).collect();
    if let Ok(mut g) = CAPTURED.lock() {
        *g = Some((names, d.model.len()));
    }
    Ok(out.into_bytes())
}

fn written(s: &mut Session, p: serde_json::Value) -> String {
    let path = std::env::temp_dir().join(format!("cadcraft-wblock-base-{}.dxf", std::process::id()));
    let mut p = p;
    p["path"] = json!(path.to_string_lossy());
    s.execute("wblock", &p).map_err(|e| format!("{e:?}")).unwrap();
    let text = std::fs::read_to_string(&path).unwrap();
    let _ = std::fs::remove_file(&path);
    text
}

#[test]
fn wblock_writes_the_base_point_and_not_the_block_table() {
    set_io(IoHooks { read: |_, _| Err("no reader in this test".into()), write, plot: None });
    let mut s = Session::new();
    let h = s.execute("line", &json!({ "points": [[10, 20], [15, 20]] })).unwrap()["handles"][0].as_str().unwrap().to_string();

    // Objects: the base point moves to the origin.
    assert_eq!(written(&mut s, json!({ "handles": [h], "base": [10, 5] })), "0,0;0,15");
    assert_eq!(written(&mut s, json!({ "handles": [h] })), "0,0;10,20");

    // A block: its base point by default, `base` (block coordinates) when given.
    s.execute("block", &json!({ "name": "Part", "base": [4, 4], "handles": [h], "keep": "delete" })).unwrap();
    assert_eq!(written(&mut s, json!({ "name": "Part" })), "0,0;6,16");
    assert_eq!(written(&mut s, json!({ "name": "Part", "base": [10, 20] })), "0,0;0,0");

    // Now the contents. Build a source whose block table has an entry that must NOT travel into the
    // written file, plus a line left in model space so the file has to contain something.
    let mut t = Session::new();
    let a = t.execute("line", &json!({ "points": [[10, 20], [15, 20]] })).unwrap()["handles"][0].as_str().unwrap().to_string();
    t.execute("block", &json!({ "name": "Part", "base": [4, 4], "handles": [a], "keep": "retain" })).unwrap();
    let b = t.execute("line", &json!({ "points": [[0, 0], [5, 0]] })).unwrap()["handles"][0].as_str().unwrap().to_string();
    t.execute("block", &json!({ "name": "Other", "base": [0, 0], "handles": [b], "keep": "retain" })).unwrap();
    t.execute("line", &json!({ "points": [[1, 1], [2, 2]] })).unwrap();

    if let Ok(mut g) = CAPTURED.lock() {
        *g = None;
    }
    let path = std::env::temp_dir().join(format!("cadcraft-wblock-table-{}.dxf", std::process::id()));
    t.execute("wblock", &json!({ "path": path.to_string_lossy(), "name": "Part" })).map_err(|e| format!("{e:?}")).unwrap();
    let _ = std::fs::remove_file(&path);

    let (names, model) = CAPTURED.lock().ok().and_then(|g| g.clone()).expect("the write hook never ran: WBLOCK did not call the writer");
    // The entities still have to be written, or the file would be empty.
    assert!(model > 0, "WBLOCK wrote no entities at all");
    // And the parent's library must not come with them.
    assert!(!names.iter().any(|n| n == "Other"), "WBLOCK carried the parent drawing's block table into the written file: {names:?}");
}
