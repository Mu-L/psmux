// Issue #589: "Undercurl style is not supported".
//
// Windows ConPTY hands psmux the SGR 4 subparameter forms verbatim
// (`ESC[4:3m` for undercurl, `ESC[4:4m`, `ESC[4:5m`) and rewrites `4:2` to the
// legacy `ESC[21m`.  Before this fix the parser matched only the single
// parameter `[4]`, so every subparameter form fell through to `unhandled` and
// the cell ended up with NO underline at all.  SGR 58 (underline colour) and
// SGR 59 (reset it) were dropped for the same reason.
//
// tmux parity: tmux 3.4 input.c input_csi_dispatch_sgr_colon handles p[0]==4
// with cases 0..5 mapping onto GRID_ATTR_UNDERSCORE..UNDERSCORE_5, case 21
// maps onto UNDERSCORE_2, and p[0]==58 sets gc->us.

use vt100_psmux as vt100;

fn style_at(bytes: &[u8], col: u16) -> vt100::UnderlineStyle {
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(bytes);
    parser.screen().cell(0, col).unwrap().underline_style()
}

fn ulcolor_at(bytes: &[u8], col: u16) -> vt100::Color {
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(bytes);
    parser.screen().cell(0, col).unwrap().underline_color()
}

#[test]
fn sgr_4_plain_is_single_underline() {
    assert_eq!(style_at(b"\x1b[4mX", 0), vt100::UnderlineStyle::Single);
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(b"\x1b[4mX");
    assert!(parser.screen().cell(0, 0).unwrap().underline());
}

#[test]
fn sgr_4_semicolon_1_is_underline_plus_bold_not_undercurl() {
    // `ESC[4;1m` is two parameters: underline and bold.  It must NOT be read
    // as the subparameter form.
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(b"\x1b[4;1mX");
    let cell = parser.screen().cell(0, 0).unwrap();
    assert_eq!(cell.underline_style(), vt100::UnderlineStyle::Single);
    assert!(cell.bold());
}

#[test]
fn sgr_4_subparams_select_extended_styles() {
    assert_eq!(style_at(b"\x1b[4:0mX", 0), vt100::UnderlineStyle::None);
    assert_eq!(style_at(b"\x1b[4:1mX", 0), vt100::UnderlineStyle::Single);
    assert_eq!(style_at(b"\x1b[4:2mX", 0), vt100::UnderlineStyle::Double);
    assert_eq!(style_at(b"\x1b[4:3mX", 0), vt100::UnderlineStyle::Curly);
    assert_eq!(style_at(b"\x1b[4:4mX", 0), vt100::UnderlineStyle::Dotted);
    assert_eq!(style_at(b"\x1b[4:5mX", 0), vt100::UnderlineStyle::Dashed);
}

#[test]
fn extended_styles_still_report_underline() {
    // Everything that only knows about SGR 4 must keep drawing a line.
    for seq in [
        &b"\x1b[4:2mX"[..],
        &b"\x1b[4:3mX"[..],
        &b"\x1b[4:4mX"[..],
        &b"\x1b[4:5mX"[..],
        &b"\x1b[21mX"[..],
    ] {
        let mut parser = vt100::Parser::new(5, 80, 0);
        parser.process(seq);
        assert!(
            parser.screen().cell(0, 0).unwrap().underline(),
            "underline() false for {seq:?}"
        );
    }
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(b"\x1b[4:0mX");
    assert!(!parser.screen().cell(0, 0).unwrap().underline());
}

#[test]
fn sgr_21_is_double_underline() {
    // ConPTY rewrites `4:2` into `21`, so this arm is the one that fires for
    // double underlines coming out of a Windows pane.
    assert_eq!(style_at(b"\x1b[21mX", 0), vt100::UnderlineStyle::Double);
}

#[test]
fn sgr_58_sets_underline_colour_semicolon_form() {
    assert_eq!(
        ulcolor_at(b"\x1b[4:3m\x1b[58;2;255;0;0mX", 0),
        vt100::Color::Rgb(255, 0, 0)
    );
    assert_eq!(
        ulcolor_at(b"\x1b[58;5;9mX", 0),
        vt100::Color::Idx(9)
    );
}

#[test]
fn sgr_58_sets_underline_colour_colon_forms() {
    // `58:2::r:g:b` carries an empty colour space id; `58:2:r:g:b` does not.
    assert_eq!(
        ulcolor_at(b"\x1b[58:2::0:255:0mX", 0),
        vt100::Color::Rgb(0, 255, 0)
    );
    assert_eq!(
        ulcolor_at(b"\x1b[58:2:0:255:0mX", 0),
        vt100::Color::Rgb(0, 255, 0)
    );
    assert_eq!(ulcolor_at(b"\x1b[58:5:9mX", 0), vt100::Color::Idx(9));
}

#[test]
fn colon_form_truecolour_fg_and_bg_also_parse() {
    let mut parser = vt100::Parser::new(5, 80, 0);
    parser.process(b"\x1b[38:2::1:2:3m\x1b[48:2::4:5:6mX");
    let cell = parser.screen().cell(0, 0).unwrap();
    assert_eq!(cell.fgcolor(), vt100::Color::Rgb(1, 2, 3));
    assert_eq!(cell.bgcolor(), vt100::Color::Rgb(4, 5, 6));
}

// ─── reset paths: nothing may bleed into the following text ─────────────────

#[test]
fn sgr_0_clears_style_and_colour() {
    let bytes = b"\x1b[4:3m\x1b[58;2;255;0;0mA\x1b[0mB";
    assert_eq!(style_at(bytes, 0), vt100::UnderlineStyle::Curly);
    assert_eq!(style_at(bytes, 1), vt100::UnderlineStyle::None);
    assert_eq!(ulcolor_at(bytes, 1), vt100::Color::Default);
}

#[test]
fn sgr_24_clears_every_underline_style() {
    for seq in [
        &b"\x1b[4:2mA\x1b[24mB"[..],
        &b"\x1b[4:3mA\x1b[24mB"[..],
        &b"\x1b[4:4mA\x1b[24mB"[..],
        &b"\x1b[4:5mA\x1b[24mB"[..],
        &b"\x1b[21mA\x1b[24mB"[..],
    ] {
        assert_eq!(
            style_at(seq, 1),
            vt100::UnderlineStyle::None,
            "style leaked past SGR 24 for {seq:?}"
        );
    }
}

#[test]
fn sgr_4_colon_0_clears_every_underline_style() {
    assert_eq!(
        style_at(b"\x1b[4:3mA\x1b[4:0mB", 1),
        vt100::UnderlineStyle::None
    );
}

#[test]
fn sgr_59_clears_only_the_underline_colour() {
    let bytes = b"\x1b[4:3m\x1b[58;2;255;0;0mA\x1b[59mB";
    assert_eq!(ulcolor_at(bytes, 0), vt100::Color::Rgb(255, 0, 0));
    assert_eq!(ulcolor_at(bytes, 1), vt100::Color::Default);
    // The curl itself survives, exactly like tmux's `case 59: gc->us = 8`.
    assert_eq!(style_at(bytes, 1), vt100::UnderlineStyle::Curly);
}

#[test]
fn plain_sgr_4_downgrades_a_curl_to_a_straight_line() {
    assert_eq!(
        style_at(b"\x1b[4:3mA\x1b[4mB", 1),
        vt100::UnderlineStyle::Single
    );
}

// ─── re-encoding: contents_formatted must replay the style ──────────────────

#[test]
fn contents_formatted_replays_extended_styles() {
    let mut parser = vt100::Parser::new(3, 40, 0);
    parser.process(b"\x1b[4:3m\x1b[58;2;255;0;0mcurly");
    let out = parser.screen().contents_formatted();
    let text = String::from_utf8_lossy(&out).into_owned();
    assert!(text.contains("4:3"), "no 4:3 in {text:?}");
    assert!(text.contains("58;2;255;0;0"), "no underline colour in {text:?}");
}

#[test]
fn contents_formatted_replays_each_style_code() {
    for (seq, want) in [
        (&b"\x1b[4:2mx"[..], "4:2"),
        (&b"\x1b[4:3mx"[..], "4:3"),
        (&b"\x1b[4:4mx"[..], "4:4"),
        (&b"\x1b[4:5mx"[..], "4:5"),
    ] {
        let mut parser = vt100::Parser::new(3, 40, 0);
        parser.process(seq);
        let out = parser.screen().contents_formatted();
        let text = String::from_utf8_lossy(&out).into_owned();
        assert!(text.contains(want), "expected {want} in {text:?}");
    }
}
