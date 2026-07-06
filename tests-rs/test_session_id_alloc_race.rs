// Root cause of the flaky `session_id_is_unique` test: `allocate_session_id`
// did a non-atomic read-modify-write on the `.psmux/next_session_id` counter
// file with no synchronization. Two concurrent callers (parallel test threads,
// or two sessions starting at once across processes) both read the same
// `current`, both return it, and both write `current + 1` -> duplicate ids.
//
// The fix serializes the read-modify-write with a process-global mutex plus a
// cross-process advisory lock file. This test hammers `allocate_session_id`
// from many threads at once and asserts every id is distinct, which reliably
// failed before the fix.

use super::*;

#[test]
fn allocate_session_id_is_unique_under_concurrency() {
    const THREADS: usize = 16;
    const PER_THREAD: usize = 32;

    let barrier = std::sync::Arc::new(std::sync::Barrier::new(THREADS));
    let mut handles = Vec::new();
    for _ in 0..THREADS {
        let b = barrier.clone();
        handles.push(std::thread::spawn(move || {
            // Release all threads simultaneously to maximize the race window.
            b.wait();
            let mut ids = Vec::with_capacity(PER_THREAD);
            for _ in 0..PER_THREAD {
                ids.push(allocate_session_id());
            }
            ids
        }));
    }

    let mut all = Vec::new();
    for h in handles {
        all.extend(h.join().expect("thread panicked"));
    }

    let total = all.len();
    let mut sorted = all.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(
        sorted.len(),
        total,
        "allocate_session_id handed out duplicate ids under concurrency: {} unique of {} allocated",
        sorted.len(),
        total
    );
}
