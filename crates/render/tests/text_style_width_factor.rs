//! A TEXT / ATTRIB / ATTDEF must honour the WIDTH FACTOR of its text style.
//!
//! In DXF a TEXT entity's group 41 is the entity's own width factor and defaults to 1.0, while the
//! factor people actually set lives on the STYLE. Reading only the entity field therefore drops the
//! style's value for every entity that relies on the style, which is the normal case. The MTEXT path
//! already reads the style (`layout_mtext_entity`), and `backwards`/`upside_down` on the same
//! `TextParams` already come from the style, so TEXT was the odd one out.

use cadcraft_doc::{Drawing, HAlign, Text, TextStyle, VAlign};
use cadcraft_geom::Vec3;
use cadcraft_render::place_text_entity;

fn styled_drawing(factor: f64) -> Drawing {
    let mut d = Drawing::new_metric();
    d.text_styles.push(TextStyle { name: "NARROW".into(), width_factor: factor, ..TextStyle::default() });
    d
}

fn text_in(style: &str, entity_factor: f64) -> Text {
    Text {
        insert: Vec3::ZERO,
        align_pt: None,
        height: 10.0,
        value: "WWWWWMMMMM".into(),
        rotation: 0.0,
        width_factor: entity_factor,
        oblique: 0.0,
        style: style.into(),
        halign: HAlign::Left,
        valign: VAlign::Baseline,
    }
}

fn shaped_width(d: &Drawing, t: &Text) -> f64 {
    let (_, bounds) = place_text_entity(d, t, &t.value);
    bounds.max.x - bounds.min.x
}

/// The style's width factor must halve the rendered width of a TEXT entity.
#[test]
fn text_honours_the_style_width_factor() {
    let wide = styled_drawing(1.0);
    let narrow = styled_drawing(0.5);

    let w_wide = shaped_width(&wide, &text_in("NARROW", 1.0));
    let w_narrow = shaped_width(&narrow, &text_in("NARROW", 1.0));

    assert!(w_wide > 0.0, "expected a positive width, got {w_wide}");
    let ratio = w_narrow / w_wide;
    assert!((ratio - 0.5).abs() < 0.05, "style width factor 0.5 should halve the text: ratio was {ratio} ({w_narrow} vs {w_wide})");
}

/// The same factor applied to MTEXT is the reference behaviour this test asks TEXT to match.
#[test]
fn mtext_already_honours_the_style_width_factor() {
    let wide = styled_drawing(1.0);
    let narrow = styled_drawing(0.5);

    let measure = |d: &Drawing| {
        let mt = cadcraft_doc::MText {
            insert: Vec3::ZERO,
            height: 10.0,
            width: 0.0,
            attach: 1,
            rotation: 0.0,
            style: "NARROW".into(),
            contents: "WWWWWMMMMM".into(),
            line_spacing: 1.0,
            line_spacing_exact: false,
            columns: None,
        };
        let layout = cadcraft_render::layout_mtext_entity(d, &mt);
        layout.bounds.max.x - layout.bounds.min.x
    };

    let ratio = measure(&narrow) / measure(&wide);
    assert!((ratio - 0.5).abs() < 0.05, "MTEXT reference should be 0.5, was {ratio}");
}

/// An explicit per-entity factor must still win, so a drawing that sets group 41 is unaffected.
#[test]
fn an_explicit_entity_width_factor_still_wins() {
    let d = styled_drawing(1.0);
    let base = shaped_width(&d, &text_in("NARROW", 1.0));
    let squeezed = shaped_width(&d, &text_in("NARROW", 0.5));
    let ratio = squeezed / base;
    assert!((ratio - 0.5).abs() < 0.05, "entity width factor 0.5 should halve the text, ratio was {ratio}");
}

/// A style with no factor (or a nonsense one) must not collapse the text.
#[test]
fn a_missing_or_bogus_style_factor_falls_back_to_one() {
    let mut d = Drawing::new_metric();
    d.text_styles.push(TextStyle { name: "ZERO".into(), width_factor: 0.0, ..TextStyle::default() });
    d.text_styles.push(TextStyle { name: "NAN".into(), width_factor: f64::NAN, ..TextStyle::default() });

    for name in ["ZERO", "NAN", "ABSENT"] {
        let w = shaped_width(&d, &text_in(name, 1.0));
        assert!(w > 0.0 && w.is_finite(), "style {name} should fall back to width factor 1.0, got {w}");
    }
}

/// ATTRIB and ATTDEF share the same code path, so they must follow the style too.
#[test]
fn attributes_honour_the_style_width_factor() {
    let wide = styled_drawing(1.0);
    let narrow = styled_drawing(0.5);

    let measure = |d: &Drawing| {
        let a = cadcraft_doc::Attrib {
            tag: "TAG".into(),
            text: text_in("NARROW", 1.0),
            invisible: false,
            constant: false,
            prompt: String::new(),
            props: Default::default(),
            multiline: None,
            modes: Default::default(),
        };
        let (_, b) = place_text_entity(d, &a.text, &a.text.value);
        b.max.x - b.min.x
    };

    let w_wide = measure(&wide);
    let w_narrow = measure(&narrow);
    let ratio = w_narrow / w_wide;
    assert!((ratio - 0.5).abs() < 0.05, "ATTDEF should follow the style width factor, ratio was {ratio}");
}
