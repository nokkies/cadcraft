//! ATTEDIT / -ATTEDIT typed at the command line, and attribute tags matched in any case.

use cadcraft_doc::{EntityKind, Handle};
use cadcraft_engine::Session;
use serde_json::{Value, json};

/// Block B: a line from 0,0 to 10,0 with attributes T (default "one") and U (default "u").
fn with_block() -> Session {
    let mut s = Session::new();
    s.execute("attdef", &json!({"tag": "T", "default": "one", "at": [0, 1]})).unwrap();
    s.execute("attdef", &json!({"tag": "U", "default": "u", "at": [0, 2]})).unwrap();
    s.execute("line", &json!({"points": [[0, 0], [10, 0]]})).unwrap();
    let hs: Vec<String> = s.doc().unwrap().model.iter().map(|e| e.handle.hex()).collect();
    s.execute("block", &json!({"name": "B", "base": [0, 0], "handles": hs, "keep": "delete"})).unwrap();
    s
}

fn insert(s: &mut Session, x: f64, attribs: Value) -> Value {
    s.execute("insert", &json!({"name": "B", "at": [x, 0], "attribs": attribs})).unwrap()
}

fn handle(r: &Value) -> Handle {
    Handle::parse_hex(r["handle"].as_str().unwrap()).unwrap()
}

fn value(s: &Session, h: Handle, tag: &str) -> String {
    let EntityKind::Insert(i) = &s.doc().unwrap().entity(h).unwrap().kind else { panic!("not an insert") };
    i.attribs.iter().find(|a| a.tag == tag).unwrap().text.value.clone()
}

fn type_lines(s: &mut Session, lines: &[&str]) {
    for l in lines {
        s.cmdline(l).unwrap();
    }
}

#[test]
fn attedit_asks_for_a_block_then_each_value() {
    let mut s = with_block();
    let h = handle(&insert(&mut s, 100.0, json!({})));
    s.cmdline("attedit").unwrap();
    assert!(s.prompt_text().contains("Select block reference"), "{}", s.prompt_text());
    s.cmdline("105,0").unwrap();
    assert!(s.prompt_text().contains("Enter value for T <one>"), "{}", s.prompt_text());
    // A value with spaces; Enter keeps U as it was.
    type_lines(&mut s, &["new value", ""]);
    assert!(s.running.is_none(), "{}", s.prompt_text());
    assert_eq!(value(&s, h, "T"), "new value");
    assert_eq!(value(&s, h, "U"), "u");
    // One undo step.
    s.undo().unwrap();
    assert_eq!(value(&s, h, "T"), "one");

    // EATTEDIT is the same command; a pick on nothing editable re-prompts.
    s.execute("line", &json!({"points": [[0, 50], [10, 50]]})).unwrap();
    type_lines(&mut s, &["eattedit", "5,50"]);
    assert!(s.log.iter().any(|l| l.contains("Select a block reference.")), "{:?}", s.log);
    type_lines(&mut s, &["105,0", "x", "y"]);
    assert!(s.running.is_none());
    assert_eq!((value(&s, h, "T"), value(&s, h, "U")), ("x".into(), "y".into()));
}

#[test]
fn dash_attedit_global_replaces_a_string_in_matching_attributes() {
    let mut s = with_block();
    let a = handle(&insert(&mut s, 100.0, json!({"T": "A-1", "U": "A-9"})));
    let b = handle(&insert(&mut s, 200.0, json!({"T": "A-2"})));
    // Not one at a time, not only visible ones: every reference of B, tag T, any value.
    s.script("-attedit\nn\nn\nb\nt\n\nA-\nX-\n").unwrap();
    assert!(s.running.is_none(), "{}", s.prompt_text());
    assert_eq!((value(&s, a, "T"), value(&s, b, "T")), ("X-1".into(), "X-2".into()));
    assert_eq!(value(&s, a, "U"), "A-9", "tag specification filters");
    assert!(s.log.iter().any(|l| l == "2 attributes changed."), "{:?}", s.log);

    // The JSON form does the same.
    let r = s.execute("-attedit", &json!({"tag": "u", "find": "9", "replace": "8"})).unwrap();
    assert_eq!(r["changed"], 1);
    assert_eq!(value(&s, a, "U"), "A-8");
}

#[test]
fn dash_attedit_one_at_a_time_edits_the_selected_attributes() {
    let mut s = with_block();
    let h = handle(&insert(&mut s, 100.0, json!({"T": "abc"})));
    type_lines(&mut s, &["-attedit", "y", "", "T", "", "105,0", ""]);
    assert!(s.prompt_text().contains("[Value/Position/Height/Angle/Style/Layer/Color/Next] <N>"), "{}", s.prompt_text());
    // Position moves the attribute; here we move it and move it back so the value edits below
    // still apply to the same attribute.
    s.cmdline("p").unwrap();
    s.cmdline("105,0").unwrap();
    // Height, Angle and Style are supported: set them, then edit the value by replacing a string.
    type_lines(&mut s, &["h", "4", "a", "45", "s", "Standard"]);
    {
        let EntityKind::Insert(i) = &s.doc().unwrap().entity(h).unwrap().kind else { panic!("not an insert") };
        let t = &i.attribs.iter().find(|a| a.tag == "T").unwrap().text;
        assert!((t.height - 4.0).abs() < 1e-9, "height set to 4, got {}", t.height);
        assert!((t.rotation - 45f64.to_radians()).abs() < 1e-9, "angle set to 45deg, got {}", t.rotation);
        assert_eq!(t.style, "Standard");
    }
    type_lines(&mut s, &["v", "c", "b", "B", "v", "r", "replaced value", "n"]);
    assert!(s.running.is_none(), "{}", s.prompt_text());
    assert_eq!(value(&s, h, "T"), "replaced value");
    assert_eq!(value(&s, h, "U"), "u");
}

#[test]
fn dash_attedit_position_moves_the_attribute() {
    let mut s = with_block();
    let h = handle(&insert(&mut s, 100.0, json!({"T": "abc"})));
    // Attribute T's definition is at (0,1); the reference is at x=100, so its world insert is (100,1).
    {
        let EntityKind::Insert(i) = &s.doc().unwrap().entity(h).unwrap().kind else { panic!("not an insert") };
        let t = &i.attribs.iter().find(|a| a.tag == "T").unwrap().text;
        assert!((t.insert.x - 100.0).abs() < 1e-9 && (t.insert.y - 1.0).abs() < 1e-9, "start at {:?}", t.insert);
    }
    type_lines(&mut s, &["-attedit", "y", "", "T", "", "105,0", ""]);
    // Position: pick a new insertion point in drawing coordinates.
    s.cmdline("p").unwrap();
    assert!(s.prompt_text().contains("Enter new insertion point for attribute"), "{}", s.prompt_text());
    s.cmdline("50,60").unwrap();
    {
        let EntityKind::Insert(i) = &s.doc().unwrap().entity(h).unwrap().kind else { panic!("not an insert") };
        let t = &i.attribs.iter().find(|a| a.tag == "T").unwrap().text;
        assert!((t.insert.x - 50.0).abs() < 1e-9 && (t.insert.y - 60.0).abs() < 1e-9, "moved to {:?}", t.insert);
    }
    // Next finishes.
    s.cmdline("").unwrap();
    assert!(s.running.is_none(), "{}", s.prompt_text());
}

#[test]
fn attribute_tags_match_in_any_case_and_unknown_tags_are_reported() {
    let mut s = with_block();
    let r = insert(&mut s, 100.0, json!({"t": "two", "nope": "x"}));
    let h = handle(&r);
    assert_eq!(value(&s, h, "T"), "two");
    assert_eq!(r["unknownTags"], json!(["nope"]));

    let r = s.execute("attedit", &json!({"handle": h.hex(), "values": {"t": "three", "u": 4, "W": "w"}})).unwrap();
    assert_eq!(r["changed"], 2);
    assert_eq!(r["unknownTags"], json!(["W"]));
    assert_eq!((value(&s, h, "T"), value(&s, h, "U")), ("three".into(), "4".into()));

    let r = s.execute("attedit", &json!({"handle": h.hex(), "values": {"T": "four"}})).unwrap();
    assert_eq!(r, json!({"changed": 1}));
}
