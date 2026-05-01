// Issue #272: TTL cache for `#(cmd)` shell expansions in status-format.
//
// These tests prove the cache layer added in src/format.rs:
//   1. First call spawns the subprocess (cache miss).
//   2. Subsequent calls within TTL return the cached value WITHOUT spawning.
//   3. Calls after TTL expiry re-spawn.
//   4. Different commands have separate cache entries (no key collisions).
//   5. status_interval=0 still caches with a 1s floor (so typing never
//      pays the spawn cost on every state_dirty push).
//
// Spawn detection strategy: the helper command appends a line to a unique
// counter file each time it runs. We count file lines to prove how many
// real subprocess spawns happened, regardless of what `expand_format`
// returns. This is the irrefutable measurement.

use super::*;
use std::time::Duration;

fn mock_app(interval_secs: u64) -> AppState {
    let mut app = AppState::new("issue272".to_string());
    app.window_base_index = 0;
    app.status_interval = interval_secs;
    app
}

/// Build a counter file path unique to this test (avoids cross-test races).
fn counter_path(test_name: &str) -> std::path::PathBuf {
    // Include a per-process random suffix so parallel runs don't collide.
    let pid = std::process::id();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!(
        "psmux_issue272_{}_{}_{}.count",
        test_name, pid, nanos
    ))
}

/// Build a `#(...)` command that appends to `counter_path` each time the
/// subprocess runs. The command's stdout is empty; we measure spawn count
/// purely by counting lines in the counter file.
fn tracer_cmd(counter: &std::path::Path) -> String {
    // On Windows the format engine uses `cmd /C`; on Unix it uses `sh -c`.
    // Either way, redirecting an `echo` to a file is portable enough for
    // our needs here. Use forward slashes so cmd /C accepts the path.
    let p = counter.display().to_string().replace('\\', "/");
    if cfg!(windows) {
        format!("echo x>>{}", p)
    } else {
        format!("echo x>>{}", p)
    }
}

fn line_count(p: &std::path::Path) -> usize {
    match std::fs::read_to_string(p) {
        Ok(s) => s.lines().count(),
        Err(_) => 0,
    }
}

fn cleanup(p: &std::path::Path) {
    let _ = std::fs::remove_file(p);
}

// ───────────────────────── tests ─────────────────────────

#[test]
fn cache_miss_spawns_once_then_cache_hits_skip_spawn() {
    let counter = counter_path("hit_skip");
    cleanup(&counter);
    let app = mock_app(15);
    let fmt = format!("X#({})Y", tracer_cmd(&counter));

    // Call expand_format 50 times in tight succession (simulates the
    // server-push path firing during active typing).
    for _ in 0..50 {
        let _ = expand_format(&fmt, &app);
    }

    let spawns = line_count(&counter);
    cleanup(&counter);

    assert_eq!(
        spawns, 1,
        "Cache MISS-then-HIT: 50 expand_format calls within TTL should \
         spawn the subprocess exactly once. Observed: {} spawns. \
         (If this fails, the TTL cache regressed and issue #272 is back.)",
        spawns
    );
}

#[test]
fn cache_expires_and_respawns_after_ttl() {
    let counter = counter_path("expiry");
    cleanup(&counter);
    // status_interval=1 -> TTL = 1s.
    let app = mock_app(1);
    let fmt = format!("#({})", tracer_cmd(&counter));

    let _ = expand_format(&fmt, &app);
    assert_eq!(line_count(&counter), 1, "First call should spawn");

    // Burst of calls within TTL — should not respawn.
    for _ in 0..10 { let _ = expand_format(&fmt, &app); }
    assert_eq!(
        line_count(&counter),
        1,
        "Calls within 1s TTL window should hit cache (no respawn)"
    );

    // Wait past TTL.
    std::thread::sleep(Duration::from_millis(1100));

    // Next call should respawn.
    let _ = expand_format(&fmt, &app);
    let spawns = line_count(&counter);
    cleanup(&counter);

    assert_eq!(
        spawns, 2,
        "After TTL expiry the next call must respawn. Observed total spawns: {}",
        spawns
    );
}

#[test]
fn different_commands_have_independent_cache_entries() {
    let counter_a = counter_path("indep_a");
    let counter_b = counter_path("indep_b");
    cleanup(&counter_a);
    cleanup(&counter_b);

    let app = mock_app(15);
    let fmt_a = format!("#({})", tracer_cmd(&counter_a));
    let fmt_b = format!("#({})", tracer_cmd(&counter_b));

    for _ in 0..20 {
        let _ = expand_format(&fmt_a, &app);
        let _ = expand_format(&fmt_b, &app);
    }

    let a = line_count(&counter_a);
    let b = line_count(&counter_b);
    cleanup(&counter_a);
    cleanup(&counter_b);

    assert_eq!(a, 1, "Command A should spawn exactly once across 20 calls; got {}", a);
    assert_eq!(b, 1, "Command B should spawn exactly once across 20 calls; got {}", b);
}

#[test]
fn status_interval_zero_still_caches_with_one_second_floor() {
    let counter = counter_path("zero_interval");
    cleanup(&counter);
    // The fix uses .max(1) so status-interval=0 doesn't disable caching.
    // Without that floor a user with `set -g status-interval 0` would
    // still hit the per-frame spawn pathology described in issue #272.
    let app = mock_app(0);
    let fmt = format!("#({})", tracer_cmd(&counter));

    for _ in 0..50 {
        let _ = expand_format(&fmt, &app);
    }

    let spawns = line_count(&counter);
    cleanup(&counter);

    assert_eq!(
        spawns, 1,
        "status_interval=0 must still cache (1s floor) to keep typing snappy. \
         Got {} spawns from 50 rapid calls.",
        spawns
    );
}

#[test]
fn cached_value_is_returned_to_callers_not_just_silently_dropped() {
    // This test guards against a subtle bug: if the cache stores values
    // but expand_format ignores them and re-runs anyway, spawn count is
    // still right but output could be stale/empty/wrong. Verify the
    // caller sees the cached output.
    let counter = counter_path("retval");
    cleanup(&counter);

    let app = mock_app(60);
    // Helper that prints a stable token AND increments the counter.
    let p = counter.display().to_string().replace('\\', "/");
    let cmd = if cfg!(windows) {
        format!("echo TOKEN-272 & echo x>>{}", p)
    } else {
        format!("echo TOKEN-272; echo x>>{}", p)
    };
    let fmt = format!("[#({})]", cmd);

    let first = expand_format(&fmt, &app);
    let second = expand_format(&fmt, &app);
    let third = expand_format(&fmt, &app);

    let spawns = line_count(&counter);
    cleanup(&counter);

    assert!(
        first.contains("TOKEN-272"),
        "First call output must contain helper stdout, got: {:?}",
        first
    );
    assert_eq!(
        first, second,
        "Cached call must return same value as first call"
    );
    assert_eq!(
        second, third,
        "Cached call must keep returning same value"
    );
    assert_eq!(
        spawns, 1,
        "Only one spawn should have occurred across 3 calls within TTL; got {}",
        spawns
    );
}

#[test]
fn cache_does_not_leak_command_text_into_output() {
    // Sanity check: the cache key is the command, but the cached *value*
    // is the stdout. A bug where we cache the command text instead would
    // make the status line display the helper command verbatim.
    let counter = counter_path("no_leak");
    cleanup(&counter);

    let app = mock_app(15);
    let p = counter.display().to_string().replace('\\', "/");
    let cmd = if cfg!(windows) {
        format!("echo SAFE_OUT & echo x>>{}", p)
    } else {
        format!("echo SAFE_OUT; echo x>>{}", p)
    };
    let fmt = format!("#({})", cmd);

    let out = expand_format(&fmt, &app);
    cleanup(&counter);

    assert!(out.contains("SAFE_OUT"), "Output should contain helper stdout");
    assert!(
        !out.contains("echo SAFE_OUT"),
        "Output must NOT contain the raw command text (cache key vs value mixup): {:?}",
        out
    );
}
