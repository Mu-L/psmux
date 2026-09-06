//! The render path must not walk the whole process table per frame.
//!
//! `#{pane_current_command}` and `#{pane_current_path}` resolve a pane's
//! foreground process, and on Windows that means
//! `CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS)` — an enumeration of every
//! process on the machine (~340 on a normal desktop). Both variables are
//! expanded on the server's per-output render path, so a status bar or window
//! title referencing them took two full system walks per repaint, on the same
//! thread that delivers keystrokes to ConPTY.
//!
//! These tests assert the property that matters: the number of real walks is
//! bounded by time, not by how many times the render path asks. They count
//! actual enumerations via the thread-local `PROC_TABLE_WALKS` rather than
//! timing anything, so they do not get flaky on a loaded machine.
//!
//! Concurrency note: the *cache* is process-wide, and several other test
//! modules reach it through `#{pane_current_command}`. So a foreign thread can
//! populate the cache and turn one of our expected walks into a hit — it can
//! never cause an extra walk on our thread, because the counter is
//! thread-local. Assertions are written as upper bounds wherever a foreign
//! cache fill is possible, and as exact counts only where it is not.
//!
//! The freshness split is deliberate and is also pinned here: render-path
//! callers reuse a recent table, while the Ctrl+C and mouse-injection routers
//! always enumerate fresh, because serving them a stale process tree would
//! misroute a real keypress or click.

use super::*;
use std::time::Duration;

/// Serialise this module's own tests: they share the process-wide cache slot
/// and each starts by invalidating it.
static CACHE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn lock() -> std::sync::MutexGuard<'static, ()> {
    CACHE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

fn walks() -> u64 {
    PROC_TABLE_WALKS.with(|c| c.get())
}

/// Force the next render-path call to miss the cache, so a test starts from a
/// known state regardless of what ran before it. Recovers a poisoned lock (same
/// as `lock()` below) so an earlier panicking test cannot leave a populated
/// cache behind and make these order-dependent.
fn invalidate() {
    let mut g = PROC_TABLE_CACHE.lock().unwrap_or_else(|e| e.into_inner());
    *g = None;
}

#[test]
fn render_path_calls_share_one_walk_within_the_ttl() {
    let _g = lock();
    invalidate();
    let before = walks();

    // 200 expansions, as a fast-drawing pane would produce.
    for _ in 0..200 {
        let _ = process_table(RENDER_PATH_TTL);
    }

    let taken = walks() - before;
    assert!(
        taken <= 1,
        "200 render-path lookups inside one TTL took {} process walks; they \
         must share at most one — the snapshot cache is not being consulted",
        taken
    );
}

#[test]
fn pane_current_command_and_path_share_a_walk() {
    // The concrete pairing from the reported bug: a status-right with
    // #{pane_current_path} plus a set-titles-string with
    // #{pane_current_command}, expanded in the same frame, used to cost two
    // full walks. They must now cost at most one.
    let _g = lock();
    invalidate();
    let before = walks();

    let _ = get_foreground_process_name(std::process::id());
    let _ = get_foreground_cwd(std::process::id());

    let taken = walks() - before;
    assert!(
        taken <= 1,
        "pane_current_command + pane_current_path in one frame took {} process \
         walks; they must share one",
        taken
    );
}

#[test]
fn an_expired_entry_is_re_walked() {
    // A cache that never expires would pass every other test here and silently
    // freeze the window title on whatever was running when the pane opened.
    // A 1ms bound makes a foreign refresh landing inside the window negligible,
    // so this can assert an exact count.
    let _g = lock();
    let short = Duration::from_millis(1);
    let _ = process_table(Duration::ZERO); // seed a known-fresh entry
    std::thread::sleep(Duration::from_millis(30));

    let before = walks();
    let _ = process_table(short);
    let taken = walks() - before;

    assert_eq!(
        taken, 1,
        "an entry older than the freshness bound must be re-walked; took {}",
        taken
    );
}

#[test]
fn the_render_path_ttl_is_bounded_and_non_zero() {
    // Zero would silently disable the cache and restore the per-frame walk;
    // an over-long bound would freeze the window title. Neither is a change
    // anyone should make without noticing.
    assert!(
        !RENDER_PATH_TTL.is_zero(),
        "RENDER_PATH_TTL of zero disables the cache — that is the bug, restored"
    );
    assert!(
        RENDER_PATH_TTL <= Duration::from_millis(500),
        "RENDER_PATH_TTL of {:?} is long enough to make the window title look \
         stuck",
        RENDER_PATH_TTL
    );
}

#[test]
fn zero_max_age_always_walks() {
    // Ctrl+C routing (foreground_is_shell) and mouse-transport selection
    // (has_vt_bridge_descendant) pass Duration::ZERO. They fire on deliberate
    // user input, not per frame, and must never act on a stale process tree.
    // A foreign thread cannot suppress these, so the count is exact.
    let _g = lock();
    let before = walks();

    for _ in 0..5 {
        let _ = process_table(Duration::ZERO);
    }

    let taken = walks() - before;
    assert_eq!(
        taken, 5,
        "Duration::ZERO must bypass the cache every time; got {} walks for 5 \
         calls — an interrupt or click could be routed off a stale tree",
        taken
    );
}

#[test]
fn a_fresh_walk_refreshes_the_shared_cache() {
    // A ZERO-max_age caller still paid for the walk, so a render-path caller
    // immediately after should reuse it rather than walking again.
    let _g = lock();
    let _ = process_table(Duration::ZERO);
    let before = walks();
    let _ = process_table(RENDER_PATH_TTL);

    assert_eq!(
        walks() - before,
        0,
        "a render-path lookup right after a fresh walk should reuse it"
    );
}

#[test]
fn the_table_is_plausibly_populated() {
    // Guard against the caching layer succeeding at returning nothing: every
    // assertion above would still pass on a permanently empty table.
    let _g = lock();
    let table = process_table(Duration::ZERO).expect("process snapshot should succeed");
    assert!(
        table.len() > 10,
        "process table has only {} entries — enumeration is broken, and the \
         cache tests above would pass anyway",
        table.len()
    );
    let me = std::process::id();
    assert!(
        table.iter().any(|(pid, _, _)| *pid == me),
        "the test process itself should appear in its own process table"
    );
}

#[test]
fn foreground_is_shell_classifies_live_processes() {
    use std::process::{Command, Stdio};

    let _g = lock();
    let classify = |pid, expected| {
        // Generous on purpose: this waits on the OS to spawn a process and
        // publish it in the process table, which has no bound under load. The
        // loop breaks the instant the verdict is right, so a healthy machine
        // never pays for the headroom; a loaded one stops reporting a product
        // failure it does not have. Seen at 3s while a full sweep was running.
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        let mut verdict = None;
        loop {
            let present = process_table(Duration::ZERO)
                .is_some_and(|table| table.iter().any(|(entry_pid, _, _)| *entry_pid == pid));
            if present {
                verdict = foreground_is_shell(pid);
                if verdict == Some(expected) {
                    break verdict;
                }
            }
            if std::time::Instant::now() >= deadline {
                break verdict;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    };

    let mut shell = Command::new("cmd.exe")
        .args(["/D", "/Q", "/K"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn cmd");
    let shell_verdict = classify(shell.id(), true);
    let _ = shell.kill();
    let _ = shell.wait();
    assert_eq!(shell_verdict, Some(true), "cmd must classify as a shell");

    let mut ping = Command::new("ping.exe")
        .args(["-n", "60", "127.0.0.1"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn ping");
    let ping_verdict = classify(ping.id(), false);
    let _ = ping.kill();
    let _ = ping.wait();
    assert_eq!(
        ping_verdict,
        Some(false),
        "ping must classify as a non-shell"
    );
}
