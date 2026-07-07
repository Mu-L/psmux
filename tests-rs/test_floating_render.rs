// Feature: floating panes (tmux new-pane) — deterministic render proof.
//
// Builds a FloatJson and renders it through the real client
// `render_float_overlays` into a headless TestBackend, then asserts the border
// glyphs land at the float's position and the pane content is drawn inside.
// Ground truth for a client-rendered overlay (capture-pane cannot see it).

use crate::client::{FloatJson, render_float_overlays};
use crate::layout::{RowRunsJson, CellRunJson};

fn row_of(ch: char, n: usize) -> RowRunsJson {
    RowRunsJson {
        runs: (0..n).map(|_| CellRunJson {
            text: ch.to_string(), fg: String::new(), bg: String::new(),
            flags: 0, width: 1, link: None,
        }).collect(),
    }
}

fn render(fl: &FloatJson, cw: u16, ch: u16) -> ratatui::buffer::Buffer {
    use ratatui::backend::TestBackend;
    use ratatui::layout::Rect;
    use ratatui::Terminal;
    let backend = TestBackend::new(cw, ch);
    let mut term = Terminal::new(backend).unwrap();
    term.draw(|f| {
        render_float_overlays(f, Rect::new(0, 0, cw, ch), std::slice::from_ref(fl));
    }).unwrap();
    term.backend().buffer().clone()
}

fn cell_char(buf: &ratatui::buffer::Buffer, x: u16, y: u16) -> char {
    let w = buf.area.width as usize;
    buf.content[(y as usize) * w + (x as usize)].symbol().chars().next().unwrap_or(' ')
}

fn make_float(x: u16, y: u16, w: u16, h: u16, border: &str) -> FloatJson {
    // inner is (w-2) x (h-2), filled with 'Z'.
    let rows: Vec<RowRunsJson> = (0..h.saturating_sub(2)).map(|_| row_of('Z', (w.saturating_sub(2)) as usize)).collect();
    FloatJson {
        x, y, w, h, border: border.to_string(), focused: true, title: String::new(), rows,
    }
}

#[test]
fn single_border_and_content_positioned() {
    let fl = make_float(5, 3, 20, 6, "single");
    let buf = render(&fl, 80, 24);
    // Top-left corner of the box at (x=5,y=3).
    assert_eq!(cell_char(&buf, 5, 3), '┌', "single top-left corner at float origin");
    assert_eq!(cell_char(&buf, 24, 3), '┐', "single top-right corner");
    assert_eq!(cell_char(&buf, 5, 8), '└', "single bottom-left corner");
    // Content 'Z' sits just inside the border.
    assert_eq!(cell_char(&buf, 6, 4), 'Z', "content drawn inside the border");
    // Outside the float is untouched (space).
    assert_eq!(cell_char(&buf, 0, 0), ' ');
}

#[test]
fn double_border_uses_double_glyphs() {
    let fl = make_float(2, 2, 16, 6, "double");
    let buf = render(&fl, 60, 20);
    assert_eq!(cell_char(&buf, 2, 2), '╔', "double top-left corner");
    assert_eq!(cell_char(&buf, 17, 2), '╗', "double top-right corner");
    assert_eq!(cell_char(&buf, 3, 3), 'Z', "content inside double border");
}

#[test]
fn heavy_border_uses_thick_glyphs() {
    let fl = make_float(0, 0, 12, 5, "heavy");
    let buf = render(&fl, 40, 12);
    assert_eq!(cell_char(&buf, 0, 0), '┏', "heavy top-left corner");
}

#[test]
fn none_border_draws_content_without_box() {
    let fl = make_float(4, 2, 14, 5, "none");
    let buf = render(&fl, 60, 20);
    // No corner glyph at the origin; content starts at the origin instead.
    assert_eq!(cell_char(&buf, 4, 2), 'Z', "none: content at origin, no border");
    for bad in ['┌', '╔', '┏'] {
        let found = buf.content.iter().any(|c| c.symbol().chars().next() == Some(bad));
        assert!(!found, "none border must draw no box glyph {:?}", bad);
    }
}
