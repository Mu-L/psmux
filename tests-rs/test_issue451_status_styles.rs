// Issue #451: status-bar style options broke in the app.rs -> client.rs
// modularization. The server render-state JSON only ever shipped
// ws_style/wsc_style, so status-left-style, status-right-style and
// window-status-{activity,bell,last}-style never reached the client renderer
// and had no effect. These tests guard the exact server-side mechanism:
//   1. append_extra_style_json() must emit all five style fields (expanded).
//   2. list_windows_json_with_tabs() must carry per-window bell/last/activity
//      flags so the client can pick the right style.
// If either regresses (a field dropped again), these fail deterministically.

use super::*;

fn mk_app() -> AppState {
    let mut app = AppState::new("issue451".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app
}

fn mk_window(name: &str, id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split { kind: crate::types::LayoutKind::Horizontal, sizes: vec![], children: vec![] },
        active_path: vec![],
        name: name.to_string(),
        id,
        area: ratatui::layout::Rect::new(0, 0, 120, 30),
        window_size: None,
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: std::time::Instant::now(),
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

// ── 1. The render-state JSON must include every style that was dropped ──
#[test]
fn append_extra_style_json_emits_all_five_dropped_styles() {
    let mut app = mk_app();
    app.status_left_style = "fg=colour201".to_string();
    app.status_right_style = "bg=colour21".to_string();
    app.window_status_activity_style = "reverse".to_string();
    app.window_status_bell_style = "bg=blue".to_string();
    app.window_status_last_style = "fg=green".to_string();

    let mut buf = String::from("{\"status_style\":\"x\"}");
    append_extra_style_json(&mut buf, &app);

    // Every dropped option is now present with its configured value.
    assert!(buf.contains("\"status_left_style\":\"fg=colour201\""), "status-left-style missing: {buf}");
    assert!(buf.contains("\"status_right_style\":\"bg=colour21\""), "status-right-style missing: {buf}");
    assert!(buf.contains("\"wsa_style\":\"reverse\""), "activity-style missing: {buf}");
    assert!(buf.contains("\"wsb_style\":\"bg=blue\""), "bell-style missing: {buf}");
    assert!(buf.contains("\"wsl_style\":\"fg=green\""), "last-style missing: {buf}");

    // Result must remain a single valid JSON object.
    assert!(buf.ends_with('}'));
    let parsed: serde_json::Value = serde_json::from_str(&buf).expect("valid JSON");
    assert_eq!(parsed["wsa_style"], "reverse");
    assert_eq!(parsed["status_left_style"], "fg=colour201");
}

// Guard the injection contract: never touch a buffer that is not a closed object.
#[test]
fn append_extra_style_json_noop_when_not_object() {
    let mut app = mk_app();
    app.window_status_activity_style = "reverse".to_string();
    let mut buf = String::from("[1,2,3]"); // not ending in '}'
    append_extra_style_json(&mut buf, &app);
    assert_eq!(buf, "[1,2,3]", "must not corrupt a non-object buffer");
}

// ── 2. Per-window flags must be plumbed so the client can style tabs ──
#[test]
fn list_windows_json_carries_bell_activity_last_flags() {
    let mut app = mk_app();
    app.windows.push(mk_window("w0", 0));
    app.windows.push(mk_window("w1", 1));
    app.active_idx = 1;        // w1 is current
    app.last_window_idx = 0;   // w0 is the last-active window
    app.windows[0].activity_flag = true;
    app.windows[0].bell_flag = true;

    let json = crate::server::helpers::list_windows_json_with_tabs(&app).unwrap();
    let arr: Vec<serde_json::Value> = serde_json::from_str(&json).unwrap();
    assert_eq!(arr.len(), 2);

    // w0: not active, but bell + activity + last flags all set.
    assert_eq!(arr[0]["active"], false);
    assert_eq!(arr[0]["bell"], true, "bell flag not plumbed: {json}");
    assert_eq!(arr[0]["activity"], true, "activity flag not plumbed: {json}");
    assert_eq!(arr[0]["last"], true, "last flag not plumbed: {json}");

    // w1: active, and definitely not the last window.
    assert_eq!(arr[1]["active"], true);
    assert_eq!(arr[1]["last"], false);
    assert_eq!(arr[1]["bell"], false);
}
