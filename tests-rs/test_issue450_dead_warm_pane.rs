// Issue #450: prefix+c "won't open a new shell" / opens a broken empty window.
//
// Root cause: the warm (spare) shell pool had no liveness checking.  When the
// pooled spare died while idling (shell crash — e.g. pwsh FailFast on a broken
// console read, external kill, dead conhost), create_window/split transplanted
// the corpse into the new window.  The dead-pane reaper then pruned it within
// one ~250ms tick, so the user saw the window flash (the reporter's screenshot
// caught the pwsh FailFast dump for "1/4 of a second") or nothing at all.
//
// Fix: (1) consume-time gate — create_window/split verify the spare's child is
// alive (and its ConPTY resizable) before transplanting, falling back to a
// cold spawn otherwise; (2) the server reap tick replaces a dead spare so the
// pool self-heals.  These tests exercise (1) with real ConPTY spawns; (2) plus
// the full prefix+c path is covered by tests/test_issue450_dead_warm_pane.ps1.

use super::*;

fn test_app() -> AppState {
    let mut app = AppState::new("issue450_test".to_string());
    app.warm_enabled = true;
    app.last_window_area = ratatui::prelude::Rect { x: 0, y: 0, width: 100, height: 30 };
    app
}

/// Kill the warm pane's child and wait until the OS reports it exited.
/// TerminateProcess is asynchronous; try_wait flips within milliseconds.
fn kill_warm_child(wp: &mut crate::types::WarmPane) {
    wp.child.kill().ok();
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if !matches!(wp.child.try_wait(), Ok(None)) {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("warm child did not report exit within 5s of kill()");
}

fn active_pane_of(win: &mut Window) -> &mut Pane {
    let path = win.active_path.clone();
    active_pane_mut(&mut win.root, &path).expect("active pane")
}

fn cleanup(app: &mut AppState) {
    for win in app.windows.iter_mut() {
        crate::tree::kill_all_children(&mut win.root);
    }
    if let Some(mut wp) = app.warm_pane.take() {
        wp.child.kill().ok();
    }
}

#[test]
fn warm_pane_is_live_reports_running_child() {
    let pty = native_pty_system();
    let mut app = test_app();
    let mut wp = spawn_warm_pane(&*pty, &mut app).expect("spawn warm pane");
    assert!(
        warm_pane_is_live(&mut wp),
        "a freshly spawned warm pane must report live"
    );
    wp.child.kill().ok();
}

#[test]
fn warm_pane_is_live_reports_dead_child() {
    let pty = native_pty_system();
    let mut app = test_app();
    let mut wp = spawn_warm_pane(&*pty, &mut app).expect("spawn warm pane");
    kill_warm_child(&mut wp);
    assert!(
        !warm_pane_is_live(&mut wp),
        "a killed warm pane must report dead"
    );
}

/// THE bug scenario: the pooled spare died, then the user hits prefix+c.
/// Before the fix, create_window transplanted the corpse (window pane id ==
/// warm pane id, dead child).  After the fix it must cold-spawn a live shell.
#[test]
fn create_window_with_dead_warm_pane_delivers_live_shell() {
    let pty = native_pty_system();
    let mut app = test_app();
    let mut wp = spawn_warm_pane(&*pty, &mut app).expect("spawn warm pane");
    let warm_id = wp.pane_id;
    kill_warm_child(&mut wp);
    app.warm_pane = Some(wp);

    create_window(&*pty, &mut app, None, None, false).expect("create_window");

    assert_eq!(app.windows.len(), 1, "a window must still be created");
    assert!(
        app.warm_pane.is_none(),
        "the dead spare must be discarded, not restored"
    );
    let pane = active_pane_of(&mut app.windows[0]);
    assert_ne!(
        pane.id, warm_id,
        "BUG #450: the dead spare (pane id {warm_id}) was transplanted into the window"
    );
    assert!(
        matches!(pane.child.try_wait(), Ok(None)),
        "the delivered pane's shell must be alive"
    );
    cleanup(&mut app);
}

/// Regression guard for the fast path: a LIVE spare must still be
/// transplanted (same pane id), keeping new-window instant.
#[test]
fn create_window_with_live_warm_pane_still_transplants() {
    let pty = native_pty_system();
    let mut app = test_app();
    let wp = spawn_warm_pane(&*pty, &mut app).expect("spawn warm pane");
    let warm_id = wp.pane_id;
    app.warm_pane = Some(wp);

    create_window(&*pty, &mut app, None, None, false).expect("create_window");

    assert_eq!(app.windows.len(), 1);
    let pane = active_pane_of(&mut app.windows[0]);
    assert_eq!(
        pane.id, warm_id,
        "a live spare must be transplanted (warm fast path preserved)"
    );
    assert!(matches!(pane.child.try_wait(), Ok(None)));
    cleanup(&mut app);
}

/// Same gate on the split path: a dead spare must not be transplanted into
/// a split; the split still succeeds via cold spawn.
#[test]
fn split_with_dead_warm_pane_delivers_live_shell() {
    let pty = native_pty_system();
    let mut app = test_app();
    // First window (cold spawn — no warm pane staged yet).
    create_window(&*pty, &mut app, None, None, false).expect("create_window");
    // Stage a dead spare.
    let mut wp = spawn_warm_pane(&*pty, &mut app).expect("spawn warm pane");
    let warm_id = wp.pane_id;
    kill_warm_child(&mut wp);
    app.warm_pane = Some(wp);

    split_active_with_command(&mut app, LayoutKind::Vertical, None, Some(&*pty), None)
        .expect("split");

    let win = &mut app.windows[0];
    assert!(
        matches!(win.root, Node::Split { .. }),
        "split must still happen despite the dead spare"
    );
    let pane = active_pane_of(win);
    assert_ne!(
        pane.id, warm_id,
        "BUG #450: dead spare transplanted into the split"
    );
    assert!(
        matches!(pane.child.try_wait(), Ok(None)),
        "the split pane's shell must be alive"
    );
    cleanup(&mut app);
}
