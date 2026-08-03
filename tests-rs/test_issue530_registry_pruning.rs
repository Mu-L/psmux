//! Issue #530: `~/.psmux` grows without bound because orphaned registry files
//! are unreachable.
//!
//! Every registry sweep in `session.rs` enumerates `.port` files and deletes
//! the siblings it finds, which makes `.port` the sole entry point to a
//! session's registry set. Teardown paths that removed `.port`/`.key`/`.pid`
//! but not `.sid` therefore stranded one file per session permanently: no code
//! path looks at a `.sid` without first finding its `.port`, so nothing could
//! ever delete it again.
//!
//! Field state that prompted this: 6,570 files in one data dir, of which 6,060
//! were `.sid` orphans and only 17 were live `.port` entries — plus 161
//! `.spawnlock` files, which are only ever removed by a `Drop` that does not
//! run when the holder is killed. The oldest was three weeks old.
//!
//! The cost is not just disk: `resolve_session_by_id` scans every `.sid` in the
//! directory to map `$N` to a session name, so each leaked file is re-read on
//! every lookup.

use super::*;

/// Unique scratch directory per test, so cases can never observe each other.
fn scratch_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "psmux-530-{}-{}-{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn write(dir: &std::path::Path, name: &str, body: &str) -> std::path::PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, body).expect("write registry file");
    p
}

fn exists(dir: &std::path::Path, name: &str) -> bool {
    dir.join(name).exists()
}

/// Nothing is alive, so every orphan is collectable.
fn all_dead(_pid: u32) -> bool {
    false
}

/// The core defect: a `.sid` whose `.port` is gone is removed.
#[test]
fn a_sid_orphaned_by_teardown_is_pruned() {
    let dir = scratch_dir("sid");
    write(&dir, "ns__work.sid", "3");

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, all_dead);

    assert_eq!(pruned, 1, "the orphaned .sid should have been removed");
    assert!(
        !exists(&dir, "ns__work.sid"),
        "orphaned .sid survived the sweep"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A live session's files must never be touched. This is the property that
/// makes the sweep safe to run on every CLI invocation.
#[test]
fn a_complete_registry_set_with_a_port_is_left_alone() {
    let dir = scratch_dir("live");
    write(&dir, "ns__work.port", "51234");
    write(&dir, "ns__work.key", "deadbeef");
    write(&dir, "ns__work.sid", "3");
    write(&dir, "ns__work.pid", "4242:134301758043996634");

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, all_dead);

    assert_eq!(pruned, 0, "a set with a .port must not be pruned");
    for f in ["ns__work.port", "ns__work.key", "ns__work.sid", "ns__work.pid"] {
        assert!(exists(&dir, f), "{f} was removed but its .port still exists");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// A server that is still coming up has written `.sid`/`.key`/`.pid` but not
/// yet its `.port` beacon. The grace period is the only thing standing between
/// the sweep and a healthy startup, so assert it directly.
#[test]
fn a_freshly_written_orphan_is_kept_until_the_grace_period_elapses() {
    let dir = scratch_dir("young");
    write(&dir, "ns__starting.sid", "7");
    write(&dir, "ns__starting.key", "abc123");

    let pruned =
        prune_orphaned_registry_files_in_with(&dir, Duration::from_secs(3600), all_dead);

    assert_eq!(pruned, 0, "files inside the grace window must be kept");
    assert!(exists(&dir, "ns__starting.sid"));
    assert!(exists(&dir, "ns__starting.key"));
    let _ = std::fs::remove_dir_all(&dir);
}

/// A wedged server that never published a port still owns its identity files;
/// deleting them would only make it harder for the #448 reaper to find.
#[test]
fn an_orphan_whose_pid_anchor_is_alive_is_kept() {
    let dir = scratch_dir("alive");
    write(&dir, "ns__wedged.pid", "4242:134301758043996634");
    write(&dir, "ns__wedged.sid", "9");

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, |pid| pid == 4242);

    assert_eq!(pruned, 0, "a live PID anchor must protect the whole set");
    assert!(exists(&dir, "ns__wedged.pid"));
    assert!(
        exists(&dir, "ns__wedged.sid"),
        ".sid is anchored by its sibling .pid, not by its own contents"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// Same set, dead owner: now the whole thing goes.
#[test]
fn an_orphan_whose_pid_anchor_is_dead_is_pruned() {
    let dir = scratch_dir("dead");
    write(&dir, "ns__gone.pid", "4242:134301758043996634");
    write(&dir, "ns__gone.sid", "9");

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, all_dead);

    assert_eq!(pruned, 2, "both satellites of a dead server should go");
    assert!(!exists(&dir, "ns__gone.pid"));
    assert!(!exists(&dir, "ns__gone.sid"));
    let _ = std::fs::remove_dir_all(&dir);
}

/// `.spawnlock` records its holder's PID in the file body rather than in a
/// sibling, and its `Drop`-based cleanup never runs when the holder is killed.
#[test]
fn a_spawnlock_is_pruned_when_its_holder_is_dead_and_kept_while_alive() {
    let dir = scratch_dir("lock");
    write(&dir, "ns____warm__.spawnlock", "22532");

    let kept = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, |pid| pid == 22532);
    assert_eq!(kept, 0, "a lock held by a live process must be kept");
    assert!(exists(&dir, "ns____warm__.spawnlock"));

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, all_dead);
    assert_eq!(pruned, 1, "a lock whose holder died must be reclaimed");
    assert!(!exists(&dir, "ns____warm__.spawnlock"));
    let _ = std::fs::remove_dir_all(&dir);
}

/// The sweep must not wander outside the registry: the session-id counter, its
/// lock, and debug logs share the directory and are not `.port` satellites.
#[test]
fn non_registry_files_are_never_touched() {
    let dir = scratch_dir("bystanders");
    write(&dir, "next_session_id", "41");
    write(&dir, "next_session_id.lock", "1234");
    write(&dir, "session.log", "some debug output");
    let _ = std::fs::create_dir_all(dir.join("instances"));
    let _ = std::fs::create_dir_all(dir.join("servers"));

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, all_dead);

    assert_eq!(pruned, 0, "no bystander file should have been removed");
    assert!(exists(&dir, "next_session_id"));
    assert!(exists(&dir, "next_session_id.lock"));
    assert!(exists(&dir, "session.log"));
    assert!(dir.join("instances").is_dir());
    assert!(dir.join("servers").is_dir());
    let _ = std::fs::remove_dir_all(&dir);
}

/// Reproduces the observed field shape: many dead namespaces leaving only
/// `.sid` behind, alongside one genuinely live session.
#[test]
fn a_backlog_of_dead_namespaces_is_cleared_without_harming_the_live_one() {
    let dir = scratch_dir("backlog");
    for i in 0..50 {
        write(&dir, &format!("jefe-conformance-{i}-0__probe.sid"), "1");
    }
    write(&dir, "live__work.port", "51234");
    write(&dir, "live__work.sid", "2");

    let pruned = prune_orphaned_registry_files_in_with(&dir, Duration::ZERO, all_dead);

    assert_eq!(pruned, 50, "every orphaned namespace should be cleared");
    assert!(exists(&dir, "live__work.port"));
    assert!(exists(&dir, "live__work.sid"));
    let remaining = std::fs::read_dir(&dir).unwrap().count();
    assert_eq!(remaining, 2, "only the live session's files should remain");
    let _ = std::fs::remove_dir_all(&dir);
}

/// `remove_session_registry_files` is what teardown paths must use; verify it
/// really takes the whole set, since a partial delete is what created #530.
#[test]
fn removing_a_registry_set_leaves_nothing_behind() {
    let dir = scratch_dir("removeall");
    let port = write(&dir, "ns__work.port", "51234");
    write(&dir, "ns__work.key", "deadbeef");
    write(&dir, "ns__work.sid", "3");
    write(&dir, "ns__work.pid", "4242:134301758043996634");

    remove_session_registry_files(&port);

    let remaining = std::fs::read_dir(&dir).unwrap().count();
    assert_eq!(
        remaining, 0,
        "teardown must not strand a satellite; leftovers are unreachable forever"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
