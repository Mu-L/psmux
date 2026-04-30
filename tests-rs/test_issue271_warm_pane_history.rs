// Issue #271: warm-created pane retains 2000-line scrollback despite
// configured history-limit; #{history_size} reports configured cap
// instead of actual retained line count.
//
// These tests cover the vt100 primitive that the warm-pane fix relies
// on.  The full path (warm pane spawned with default cap → config
// raises history-limit → consume reconciles cap → output retained
// past the old cap) is covered by tests/test_issue271_warm_pane_history.ps1
// because it requires real ConPTY/shell scaffolding.

use super::*;

/// vt100 must expose a setter to grow the scrollback cap *after* the
/// parser was constructed.  Without it, the warm-pane fast path can't
/// reconcile the parser's cap with `app.history_limit` at consume time.
#[test]
fn vt100_set_scrollback_len_grows_cap() {
    let mut p = vt100::Parser::new(4, 20, 2000);
    assert_eq!(p.screen().scrollback_len(), 2000);
    p.screen_mut().set_scrollback_len(100_000);
    assert_eq!(p.screen().scrollback_len(), 100_000);
}

/// Shrinking the cap below current fill must trim the oldest rows.
/// The fix path only ever grows the cap, but the API needs symmetric
/// behaviour to be safe — e.g. if a future code path lowers the limit.
#[test]
fn vt100_set_scrollback_len_trims_excess_when_shrinking() {
    let mut p = vt100::Parser::new(2, 20, 2000);
    let mut data = String::new();
    for i in 0..50 {
        data.push_str(&format!("row {i}\r\n"));
    }
    p.process(data.as_bytes());
    let filled_before = p.screen().scrollback_filled();
    assert!(
        filled_before > 10,
        "expected scrollback to fill (got {filled_before})"
    );

    p.screen_mut().set_scrollback_len(5);
    assert_eq!(p.screen().scrollback_len(), 5);
    assert!(
        p.screen().scrollback_filled() <= 5,
        "shrink should trim, got {}",
        p.screen().scrollback_filled()
    );
}

/// `scrollback_filled` must return the live row count (the number used
/// by the `#{history_size}` formatter), distinct from `scrollback_len`
/// (the configured cap).  The two were conflated in #271.
#[test]
fn vt100_scrollback_filled_distinct_from_cap() {
    let mut p = vt100::Parser::new(3, 20, 100);
    let mut data = String::new();
    for i in 0..7 {
        data.push_str(&format!("L{i}\r\n"));
    }
    p.process(data.as_bytes());
    assert_eq!(p.screen().scrollback_len(), 100, "cap unchanged");
    let filled = p.screen().scrollback_filled();
    assert!(
        filled > 0 && filled < 100,
        "filled should reflect actual rows, got {filled}"
    );
}

/// The exact scenario from the warm-pane consume path: parser is born
/// with the default cap (2000), config raises `history_limit`, then
/// the cap is reconciled at consume time.  Subsequent output must be
/// retained well past the original 2000-line ceiling.
#[test]
fn warm_pane_simulation_retains_beyond_default_cap() {
    // Spawn the "warm pane" parser with the default 2000 cap.
    let mut parser = vt100::Parser::new(2, 30, 2000);
    assert_eq!(parser.screen().scrollback_len(), 2000);

    // Simulate the consume-time reconciliation: config raised the
    // limit to 100_000.  This is exactly what pane.rs does in the
    // warm-pane fast path after #271.
    parser.screen_mut().set_scrollback_len(100_000);

    // Now stream 5000 lines through.  With the original cap, only the
    // last ~2000 would survive.  After the fix, all 5000 must remain.
    let mut data = String::new();
    for i in 0..5_000 {
        data.push_str(&format!("line {i}\r\n"));
    }
    parser.process(data.as_bytes());

    let filled = parser.screen().scrollback_filled();
    assert!(
        filled >= 4_900,
        "BUG #271: expected ~5000 retained after cap raise, got {filled}"
    );
    assert!(
        filled <= 100_000,
        "must not exceed new cap, got {filled}"
    );
}
