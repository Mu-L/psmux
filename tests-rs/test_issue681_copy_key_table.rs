// Issue #681, the first mismatch listed under "Not covered here": the copy-mode
// key table on the LIVE route disagreed with tmux on `C-v`.
//
// The copy-mode-vi table binds it to rectangle-toggle (key-bindings.c:652 in
// 3.7c, and again at :705 for `v`); only the emacs copy-mode table pages down
// with it (:575).  `input::send_key_to_active` had no mode-keys branch at all,
// so a vi user's `C-v` paged down and block selection could not be reached from
// the keyboard.  `input::handle_key` did branch, but its vi arm SET block
// selection rather than toggling it, so a second press could not switch it
// back off.
//
// The tests drive the REAL functions over a real PTY-backed pane tree (no psmux
// server and no session is created). Registered from src/input.rs.

use super::*;

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::types::{Node, SelectionMode};

const ROWS: u16 = 30;
const COLS: u16 = 40;
const SCROLLBACK: usize = 500;
const FILL: usize = 300;
/// What one full page is worth in a pane `ROWS` tall (window-copy.c:901-907).
const PAGE: usize = (ROWS - 2) as usize;

/// ConPTY creation can fail transiently when the suite churns many short-lived
/// PTYs in parallel, so retry with backoff and name the stage that broke.
fn open_pane_pty(
    rows: u16,
    cols: u16,
) -> (
    Box<dyn portable_pty::MasterPty + Send>,
    Box<dyn portable_pty::Child + Send + Sync>,
    Box<dyn std::io::Write + Send>,
) {
    let mut last_err = String::new();
    for attempt in 0u64..5 {
        if attempt > 0 {
            std::thread::sleep(Duration::from_millis(100 * attempt));
        }
        let pty = portable_pty::native_pty_system();
        let pair = match pty.openpty(portable_pty::PtySize { rows, cols, pixel_width: 0, pixel_height: 0 }) {
            Ok(p) => p,
            Err(e) => { last_err = format!("openpty: {e:?}"); continue; }
        };
        let mut cmd = portable_pty::CommandBuilder::new("cmd.exe");
        cmd.arg("/c");
        cmd.arg("exit");
        let child = match pair.slave.spawn_command(cmd) {
            Ok(c) => c,
            Err(e) => { last_err = format!("spawn dummy: {e:?}"); continue; }
        };
        let writer = match pair.master.take_writer() {
            Ok(w) => w,
            Err(e) => { last_err = format!("take_writer: {e:?}"); continue; }
        };
        return (pair.master, child, writer);
    }
    panic!("PTY-backed pane creation failed after 5 attempts under parallel load: {last_err}");
}

fn make_pane(id: usize, rows: u16, cols: u16) -> crate::types::Pane {
    let (master, child, writer) = open_pane_pty(rows, cols);
    let term = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, SCROLLBACK)));
    let epoch = Instant::now() - Duration::from_secs(2);
    crate::types::Pane {
        master,
        writer,
        child,
        term,
        last_rows: rows,
        last_cols: cols,
        id,
        title: format!("pane{id}"),
        title_locked: false,
        child_pid: None,
        data_version: Arc::new(AtomicU64::new(0)),
        last_title_check: epoch,
        last_infer_title: epoch,
        dead: false,
        last_text_input: None,
        last_special_key: None,
        vt_bridge_cache: None,
        vti_mode_cache: None,
        mouse_input_cache: None, win32_input_latched: false,
        scroll_fg_cache: None,
        mouse_proto_owner: None,
        wheel_auth: None,
        cursor_shape: Arc::new(AtomicU8::new(0)),
        bell_pending: Arc::new(AtomicBool::new(false)),
        cpr_pending: Arc::new(AtomicBool::new(false)),
        color_query_pending: Arc::new(std::sync::atomic::AtomicU32::new(0)),
        copy_state: None, live_term: None,
        pane_style: None,
        pane_options: Default::default(),
        squelch_until: None,
        output_ring: Arc::new(Mutex::new(std::collections::VecDeque::new())),
        spawned_at: None,
        start_command: String::new(),
        cwd_hint: None,
    }
}

fn make_window(id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split { kind: crate::types::LayoutKind::Horizontal, sizes: vec![], children: vec![] },
        active_path: vec![],
        name: "w".to_string(),
        id,
        area: ratatui::layout::Rect::new(0, 0, COLS, ROWS),
        window_size: None,
        window_options: Default::default(),
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: Instant::now(),
        last_seen_version: 0,
        manual_rename: false,
        layout_index: 0,
        pane_mru: vec![],
        zoom_saved: None,
        linked_from: None,
        floating: Vec::new(),
        floating_focus: None,
    }
}

/// One window, one pane `ROWS` tall holding `FILL` numbered lines, already in
/// copy mode with the cursor parked mid viewport so neither a cursor motion nor
/// a scroll is clamped by an edge.
fn copy_app(mode_keys: &str) -> AppState {
    let mut app = AppState::new("issue681keys".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app.mode_keys = mode_keys.to_string();
    let pane = make_pane(0, ROWS, COLS);
    {
        let mut parser = pane.term.lock().expect("parser lock");
        for i in 1..=FILL {
            parser.process(format!("line-{i}\r\n").as_bytes());
        }
    }
    let mut win = make_window(0);
    win.root = Node::Leaf(pane);
    win.active_path = vec![];
    app.windows.push(win);
    app.active_idx = 0;
    app.mode = Mode::CopyMode;
    app.copy_scroll_offset = 0;
    app.copy_pos = Some((ROWS / 2, 0));
    app
}

fn row(app: &AppState) -> u16 {
    app.copy_pos.expect("copy_pos must be tracked in copy mode").0
}

fn offset(app: &AppState) -> usize {
    app.copy_scroll_offset
}

// ══════════════ C-v is rectangle-toggle in vi, page-down in emacs ══════════════

#[test]
fn live_ctrl_v_toggles_rectangle_in_vi_and_does_not_scroll() {
    let mut app = copy_app("vi");
    // Park the view off the live end so a stray page down would be visible.
    crate::copy_mode::scroll_copy_up(&mut app, 50);
    let before = offset(&app);

    crate::input::send_key_to_active(&mut app, "C-v").unwrap();
    assert!(
        matches!(app.copy_selection_mode, SelectionMode::Rect),
        "copy-mode-vi C-v is rectangle-toggle (key-bindings.c:652), it must switch block selection on"
    );
    assert_eq!(offset(&app), before, "rectangle-toggle must not move the view");

    crate::input::send_key_to_active(&mut app, "C-v").unwrap();
    assert!(
        matches!(app.copy_selection_mode, SelectionMode::Char),
        "a toggle: the second C-v must switch block selection back off"
    );
    assert_eq!(offset(&app), before, "still no scrolling");
}

#[test]
fn live_ctrl_v_still_pages_down_in_emacs() {
    // The emacs copy-mode table keeps C-v as page-down (key-bindings.c:575).
    let mut app = copy_app("emacs");
    crate::copy_mode::scroll_copy_up(&mut app, 100);
    let before = offset(&app);

    crate::input::send_key_to_active(&mut app, "C-v").unwrap();
    assert_eq!(offset(&app), before - PAGE, "emacs C-v must page down one page");
    assert!(
        matches!(app.copy_selection_mode, SelectionMode::Char),
        "emacs C-v must leave the selection mode alone"
    );
}

#[test]
fn handle_key_ctrl_v_toggles_rectangle_off_again() {
    // The pre-server dispatcher branched on mode-keys but only ever switched
    // block selection ON, so a second press could not switch it off.
    let mut app = copy_app("vi");
    let event = KeyEvent::new(KeyCode::Char('v'), KeyModifiers::CONTROL);

    crate::input::handle_key(&mut app, event).unwrap();
    assert!(matches!(app.copy_selection_mode, SelectionMode::Rect), "first C-v switches block selection on");

    crate::input::handle_key(&mut app, event).unwrap();
    assert!(matches!(app.copy_selection_mode, SelectionMode::Char), "second C-v switches it back off");
}

#[test]
fn both_dispatchers_agree_on_ctrl_v() {
    for mode_keys in ["vi", "emacs"] {
        let mut a = copy_app(mode_keys);
        let mut b = copy_app(mode_keys);
        crate::copy_mode::scroll_copy_up(&mut a, 100);
        crate::copy_mode::scroll_copy_up(&mut b, 100);

        crate::input::handle_key(&mut a, KeyEvent::new(KeyCode::Char('v'), KeyModifiers::CONTROL)).unwrap();
        crate::input::send_key_to_active(&mut b, "C-v").unwrap();

        assert_eq!(
            (offset(&a), a.copy_selection_mode == SelectionMode::Rect),
            (offset(&b), b.copy_selection_mode == SelectionMode::Rect),
            "mode-keys {mode_keys}: handle_key and send_key_to_active must agree on C-v"
        );
    }
}
