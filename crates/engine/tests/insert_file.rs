//! INSERT of exploded blocks (`*NAME`) and of drawing files (`-INSERT path`, `NAME=path`, JSON
//! `file`), read through the io hooks (#340).

use cadcraft_engine::Session;
use cadcraft_engine::cmd::file::{IoHooks, set_io};
use cadcraft_engine::doc::color::Color;
use cadcraft_engine::doc::geom::Vec3;
use cadcraft_engine::doc::{Block, Circle, Drawing, Entity, EntityKind, HVal, Handle, Insert, Layer, Line};
use serde_json::json;

/// A drawing file in a test format: its bytes are "x,y", the $INSBASE. Model space: a line from
/// 10,10 to 20,10 on layer PARTS (colour 1), and a reference to block NUT (a circle) at 10,10.
fn read(bytes: &[u8], _name: &str) -> Result<Drawing, String> {
    let text = String::from_utf8_lossy(bytes);
    let (x, y) = text.trim().split_once(',').ok_or("bad test file")?;
    let (x, y): (f64, f64) = (x.parse().map_err(|_| "x")?, y.parse().map_err(|_| "y")?);
    let mut d = Drawing::new_imperial();
    d.header.set("INSBASE", HVal::Point(Vec3::new(x, y, 0.0)));
    let mut parts = Layer::new("PARTS");
    parts.color = Color::Index(1);
    d.layers.push(parts);
    let mut nut = Block::new("NUT");
    nut.entities.push(Entity::new(Handle(0x50), EntityKind::Circle(Circle { center: Vec3::ZERO, radius: 1.0 })));
    d.blocks.insert("NUT".into(), std::sync::Arc::new(nut));
    let mut line = Entity::new(Handle(0x60), EntityKind::Line(Line { a: Vec3::new(10.0, 10.0, 0.0), b: Vec3::new(20.0, 10.0, 0.0) }));
    line.common.layer = "PARTS".into();
    d.model.push(line);
    let ins = Insert {
        block: "NUT".into(),
        insert: Vec3::new(10.0, 10.0, 0.0),
        scale: Vec3::new(1.0, 1.0, 1.0),
        rotation: 0.0,
        attribs: Vec::new(),
        cols: 1,
        rows: 1,
        col_spacing: 0.0,
        row_spacing: 0.0,
    };
    d.model.push(Entity::new(Handle(0x61), EntityKind::Insert(ins)));
    Ok(d)
}

fn hooks() {
    // One hook pair for the whole file, dispatching on the path. `set_io` is process-GLOBAL, so if each test
    // installs its own pair, whichever runs last wins for all of them and an earlier test reads its file
    // through the wrong codec. That is not theoretical: adding a second codec here broke the first test on
    // the very next run. A test whose file name carries ROUNDTRIP_MARKER gets the serialising codec below;
    // every other file gets the original one.
    set_io(IoHooks { read: dispatch_read, write: dispatch_write, plot: None });
}

/// Files handled by the WBLOCK round-trip codec rather than the simple one above.
const ROUNDTRIP_MARKER: &str = "border-extract";

fn dispatch_read(bytes: &[u8], name: &str) -> Result<Drawing, String> {
    if name.contains(ROUNDTRIP_MARKER) { rt_read(bytes, name) } else { read(bytes, name) }
}

fn dispatch_write(d: &Drawing, path: &str) -> Result<Vec<u8>, String> {
    if path.contains(ROUNDTRIP_MARKER) {
        rt_write(d, path)
    } else {
        Ok(format!("{},{}", d.header.point("INSBASE").map(|p| p.x).unwrap_or(0.0), d.header.point("INSBASE").map(|p| p.y).unwrap_or(0.0))
            .into_bytes())
    }
}

/// The round-trip codec: "x,y" for $INSBASE, then "|Bname=ax,ay,bx,by" per block line and "|M=ax,ay,bx,by"
/// per model-space line. Model space is where WBLOCK puts the extracted entities and what INSERT reads to
/// define the target's block -- derived from the Drawing handed to the writer, never assumed.
fn rt_write(d: &Drawing, _path: &str) -> Result<Vec<u8>, String> {
    let p = d.header.point("INSBASE").unwrap_or_default();
    let mut out = format!("{},{}", p.x, p.y);
    for (name, blk) in d.blocks.iter() {
        for e in blk.entities.iter() {
            if let EntityKind::Line(l) = &e.kind {
                out.push_str(&format!("|B{name}={},{},{},{}", l.a.x, l.a.y, l.b.x, l.b.y));
            }
        }
    }
    for e in d.model.iter() {
        if let EntityKind::Line(l) = &e.kind {
            out.push_str(&format!("|M={},{},{},{}", l.a.x, l.a.y, l.b.x, l.b.y));
        }
    }
    Ok(out.into_bytes())
}

fn rt_read(bytes: &[u8], _name: &str) -> Result<Drawing, String> {
    let text = String::from_utf8_lossy(bytes).to_string();
    let mut bits = text.split('|');
    let head = bits.next().ok_or("bad test file")?;
    let (x, y) = head.split_once(',').ok_or("bad test file")?;
    let (x, y): (f64, f64) = (x.parse().map_err(|_| "x")?, y.parse().map_err(|_| "y")?);
    let mut d = Drawing::new_imperial();
    d.header.set("INSBASE", HVal::Point(Vec3::new(x, y, 0.0)));
    let mut next_handle = 0x700u64;
    let mut block_ents: std::collections::BTreeMap<String, Vec<(f64, f64, f64, f64)>> = std::collections::BTreeMap::new();
    let mut model_ents: Vec<(f64, f64, f64, f64)> = Vec::new();
    for bit in bits.filter(|s| !s.is_empty()) {
        let (tag, geom) = bit.split_once('=').ok_or("bad line")?;
        let mut c = geom.split(',').map(|v| v.parse::<f64>().map_err(|_| "coord"));
        let g = (c.next().unwrap()?, c.next().unwrap()?, c.next().unwrap()?, c.next().unwrap()?);
        match tag.strip_prefix('B') {
            Some(name) => block_ents.entry(name.to_string()).or_default().push(g),
            None if tag == "M" => model_ents.push(g),
            _ => return Err("bad tag".into()),
        }
    }
    for (name, geoms) in block_ents {
        let mut nb = Block::new(&name);
        for (ax, ay, bx, by) in geoms {
            nb.entities.push(Entity::new(Handle(next_handle), EntityKind::Line(Line { a: Vec3::new(ax, ay, 0.0), b: Vec3::new(bx, by, 0.0) })));
            next_handle += 1;
        }
        d.blocks.insert(name.clone(), std::sync::Arc::new(nb));
    }
    for (ax, ay, bx, by) in model_ents {
        d.model.push(Entity::new(Handle(next_handle), EntityKind::Line(Line { a: Vec3::new(ax, ay, 0.0), b: Vec3::new(bx, by, 0.0) })));
        next_handle += 1;
    }
    Ok(d)
}

/// Write a test drawing file with $INSBASE `base`; returns its path.
fn file(name: &str, base: &str) -> String {
    let dir = std::env::temp_dir().join(format!("cadcraft-insert-file-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join(name);
    std::fs::write(&p, base).unwrap();
    p.to_string_lossy().into_owned()
}

/// Lines in model space as (ax, ay, bx, by), rounded.
fn lines(s: &Session) -> Vec<(f64, f64, f64, f64)> {
    let r = |v: f64| (v * 1e6).round() / 1e6;
    s.doc()
        .unwrap()
        .model
        .iter()
        .filter_map(|e| match &e.kind {
            EntityKind::Line(l) => Some((r(l.a.x), r(l.a.y), r(l.b.x), r(l.b.y))),
            _ => None,
        })
        .collect()
}

/// Block references in model space as (block, x, y).
fn inserts(s: &Session) -> Vec<(String, f64, f64)> {
    s.doc()
        .unwrap()
        .model
        .iter()
        .filter_map(|e| match &e.kind {
            EntityKind::Insert(i) => Some((i.block.clone(), i.insert.x, i.insert.y)),
            _ => None,
        })
        .collect()
}

#[test]
fn star_name_inserts_the_blocks_objects_with_one_scale_factor() {
    let mut s = Session::new();
    s.execute("line", &json!({ "points": [[0, 0], [10, 0]] })).unwrap();
    s.execute("block", &json!({ "name": "B1", "base": [0, 0], "keep": "delete", "handles": ["100"] })).unwrap();

    // Insertion point, then one scale factor and the rotation; no block reference is left.
    s.script("-INSERT *B1 5,5 2 90\n").unwrap();
    assert!(s.running.is_none(), "INSERT finished: {}", s.prompt_text());
    assert!(inserts(&s).is_empty());
    assert_eq!(lines(&s), vec![(5.0, 5.0, 5.0, 25.0)]);

    // A plain name after an exploded one inserts a block reference again.
    s.script("-INSERT B1 0,0 1 1 0\n").unwrap();
    assert_eq!(inserts(&s).len(), 1);

    // JSON: "*NAME" explodes too.
    s.execute("insert", &json!({ "name": "*B1", "at": [0, 50] })).unwrap();
    assert_eq!(inserts(&s).len(), 1);
    assert_eq!(lines(&s).last(), Some(&(0.0, 50.0, 10.0, 50.0)));
}

#[test]
fn a_drawing_file_becomes_a_block_with_its_insbase_and_tables() {
    hooks();
    let bolt = file("bolt.dxf", "10,10");
    let mut s = Session::new();
    // This drawing's own layer PARTS keeps its colour.
    s.execute("layer.new", &json!({ "name": "PARTS", "color": 3 })).unwrap();

    s.script(&format!("-INSERT {bolt} 100,100 1 1 0\n")).unwrap();
    assert!(s.running.is_none(), "INSERT finished: {}", s.prompt_text());
    let d = s.doc().unwrap();
    let b = d.block("bolt").expect("block named after the file");
    assert_eq!(b.base, Vec3::new(10.0, 10.0, 0.0), "$INSBASE is the base point");
    assert_eq!(b.entities.len(), 2);
    assert!(d.block("NUT").is_some(), "nested blocks come along");
    assert_eq!(d.layer("PARTS").map(|l| l.color), Some(Color::Index(3)), "an existing layer keeps its definition");
    assert_eq!(inserts(&s), vec![("bolt".into(), 100.0, 100.0)]);

    // The file again: its block exists, so INSERT asks; No (the default) keeps the definition.
    s.cmdline(&format!("-INSERT {bolt}")).unwrap();
    assert!(s.prompt_text().contains("Redefine"), "{}", s.prompt_text());
    s.script("N 0,0 1 1 0\n").unwrap();
    assert!(s.running.is_none(), "INSERT finished: {}", s.prompt_text());
    assert_eq!(inserts(&s).len(), 2);

    // NAME=path defines the block under that name without asking; *path inserts the file's objects.
    let pin = file("pin.dxf", "10,10");
    s.script(&format!("-INSERT M8={bolt} 0,0 1 1 0\n-INSERT *{pin} 50,0 1 0\n")).unwrap();
    assert!(s.running.is_none(), "INSERT finished: {}", s.prompt_text());
    assert!(s.doc().unwrap().block("M8").is_some());
    assert_eq!(inserts(&s).iter().filter(|i| i.0 == "M8").count(), 1);
    // The exploded line, moved from the base point 10,10 to 50,0; the nested NUT stays a reference.
    assert_eq!(lines(&s), vec![(50.0, 0.0, 60.0, 0.0)]);
    assert!(inserts(&s).iter().any(|i| i.0 == "NUT" && i.1 == 50.0 && i.2 == 0.0));

    // JSON: `file` with an optional block name, never a dialog.
    let r = s.execute("insert", &json!({ "file": file("washer.dxf", "0,0"), "at": [5, 5] })).unwrap();
    assert!(r["handle"].is_string(), "{r}");
    assert!(inserts(&s).iter().any(|i| i.0 == "washer"));

    // A file that can't be read is reported; nothing is inserted.
    let n = inserts(&s).len();
    assert!(s.execute("insert", &json!({ "file": "/no/such/part.dxf", "at": [0, 0] })).is_err());
    s.cmdline("-INSERT /no/such/part.dxf").unwrap();
    assert!(s.log.iter().any(|m| m.contains("/no/such/part.dxf")), "{:?}", s.log.last());
    assert!(s.prompt_text().contains("block name"), "{}", s.prompt_text());
    assert_eq!(inserts(&s).len(), n);
}

#[test]
fn exploded_json_insert_is_one_undo_step() {
    for params in [json!({ "name": "*B", "at": [5, 5] }), json!({ "name": "B", "at": [5, 5], "explode": true })] {
        let mut s = Session::new();
        s.execute("line", &json!({ "points": [[0, 0], [10, 0]] })).unwrap();
        s.execute("block", &json!({ "name": "B", "base": [0, 0], "keep": "delete", "handles": ["100"] })).unwrap();
        let undo = s.state().unwrap().undo.len();
        s.execute("insert", &params).unwrap();
        assert_eq!(lines(&s), vec![(5.0, 5.0, 15.0, 5.0)], "{params}");
        assert_eq!(s.state().unwrap().undo.len(), undo + 1, "{params}");

        s.execute("undo", &json!({})).unwrap();
        assert!(lines(&s).is_empty(), "{params}");
        assert!(inserts(&s).is_empty(), "{params}");
        assert!(s.doc().unwrap().block("B").is_some(), "{params}");

        // The second undo reverts the block creation, not a leftover EXPLODE step.
        s.execute("undo", &json!({})).unwrap();
        assert!(inserts(&s).is_empty(), "{params}");
        assert!(s.doc().unwrap().block("B").is_none(), "{params}");
        assert_eq!(lines(&s), vec![(0.0, 0.0, 10.0, 0.0)], "{params}");
    }
}

/// WBLOCK then INSERT: the round trip a drafter uses to move a block between drawings.
///
/// This is the pairing the two commands' own tests each miss. `wblock_base.rs` asserts what WBLOCK writes;
/// this file asserts what INSERT reads. Neither looked at the two joined up, which is why build 0.121's
/// WBLOCK fix had no test that could see its consequence -- and why a wrong conclusion about INSERT
/// survived a build before being re-tested and withdrawn. Written as one test rather than split: `set_io`
/// is process-global, so a second hook installed by another test in this file would replace this one under
/// parallel execution.
///
/// The writer must SERIALISE, not summarise. An earlier version of this test wrote only "$INSBASE x,y",
/// the same bytes `read` above expects, which throws away the block table the test is about -- so it passed
/// against the buggy WBLOCK that leaked the parent's whole library. A test that cannot fail on the defect is
/// not testing the defect.
#[test]
fn a_block_extracted_by_wblock_inserts_into_another_drawing() {
    hooks();

    // Source drawing: a block named BORDER, plus a library block that must NOT travel with the extract.
    let mut src = Session::new();
    let a = src.execute("line", &json!({ "points": [[0, 0], [30, 0]] })).unwrap()["handles"][0].as_str().unwrap().to_string();
    src.execute("block", &json!({ "name": "BORDER", "base": [0, 0], "handles": [a], "keep": "retain" })).unwrap();
    let b = src.execute("line", &json!({ "points": [[0, 0], [1, 0]] })).unwrap()["handles"][0].as_str().unwrap().to_string();
    src.execute("block", &json!({ "name": "LIBRARY ONLY", "base": [0, 0], "handles": [b], "keep": "retain" })).unwrap();

    let path = file("border-extract.dxf", "0,0");
    src.execute("wblock", &json!({ "path": &path, "name": "BORDER" })).map_err(|e| format!("{e:?}")).unwrap();

    // A DIFFERENT drawing, which knows nothing about BORDER, reads that file back as a block.
    let mut dst = Session::new();
    let r = dst.execute("insert", &json!({ "name": "BORDER", "file": &path, "at": [100, 100] })).map_err(|e| format!("{e:?}")).unwrap();
    assert!(r["handle"].is_string(), "{r}");
    assert!(inserts(&dst).iter().any(|i| i.0 == "BORDER" && i.1 == 100.0 && i.2 == 100.0), "the extracted block did not insert: {:?}", inserts(&dst));
    let bl = dst.doc().unwrap().block("BORDER").cloned();
    let bl = bl.expect("WBLOCK's output did not define a usable block");
    assert!(!bl.entities.is_empty(), "the inserted block definition is empty");
    // The parent's unrelated library block must not have arrived through the file.
    assert!(dst.doc().unwrap().block("LIBRARY ONLY").is_none(), "WBLOCK leaked the parent's block table into the extract");
    let _ = std::fs::remove_file(&path);
}
