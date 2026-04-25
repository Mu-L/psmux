//! Live preview helpers for the choose-tree / choose-session pickers.
//!
//! Fetches `capture-pane` output from any reachable session via TCP and
//! caches results briefly so navigation through the picker stays snappy.
//!
//! See issue #257 (preview support like tmux's `screen_write_preview`).

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::session::{fetch_authed_response_multi, read_session_key};

/// Cache key: "session\twin_id\tpane_id" (pane_id == usize::MAX means
/// "use the active pane of the targeted window").
pub type PreviewCache = HashMap<String, (String, Instant)>;

pub const PREVIEW_TTL: Duration = Duration::from_millis(1500);
const CONNECT_TIMEOUT: Duration = Duration::from_millis(150);
const READ_TIMEOUT: Duration = Duration::from_millis(400);

pub fn cache_key(sess: &str, win_id: usize, pane_id: usize) -> String {
    format!("{}\t{}\t{}", sess, win_id, pane_id)
}

/// Fetch capture-pane text for the given target. Returns None if the
/// session is not reachable or the response is empty.
///
/// `pane_id == usize::MAX` => target the window only (server captures the
/// active pane). Otherwise targets a specific pane id within the window.
pub fn fetch_pane_preview(home: &str, sess: &str, win_id: usize, pane_id: usize) -> Option<String> {
    let port_path = format!("{}\\.psmux\\{}.port", home, sess);
    let port: u16 = std::fs::read_to_string(&port_path).ok()?.trim().parse().ok()?;
    let key = read_session_key(sess).ok()?;
    let target = if pane_id == usize::MAX {
        format!(":@{}", win_id)
    } else {
        format!(":@{}.%{}", win_id, pane_id)
    };
    let cmd = format!("capture-pane -p -t {}\n", target);
    let resp = fetch_authed_response_multi(
        &format!("127.0.0.1:{}", port),
        &key,
        cmd.as_bytes(),
        CONNECT_TIMEOUT,
        READ_TIMEOUT,
    )?;
    if resp.trim().is_empty() {
        None
    } else {
        Some(resp)
    }
}

/// Get a preview, using the cache if fresh, fetching otherwise.
pub fn get_or_fetch(
    cache: &mut PreviewCache,
    home: &str,
    sess: &str,
    win_id: usize,
    pane_id: usize,
) -> Option<String> {
    let key = cache_key(sess, win_id, pane_id);
    if let Some((text, ts)) = cache.get(&key) {
        if ts.elapsed() < PREVIEW_TTL {
            return Some(text.clone());
        }
    }
    let text = fetch_pane_preview(home, sess, win_id, pane_id)?;
    cache.insert(key, (text.clone(), Instant::now()));
    Some(text)
}

/// Render preview text into a Vec of lines clipped to the given dimensions.
/// Strips trailing whitespace and keeps the most recent (bottom) `height`
/// non-empty lines so the active prompt is visible.
pub fn clip_lines(text: &str, width: u16, height: u16) -> Vec<String> {
    let max_w = width as usize;
    let max_h = height as usize;
    if max_h == 0 || max_w == 0 {
        return Vec::new();
    }
    // Split, trim trailing whitespace, drop the trailing empty noise but
    // keep blank lines that appear between content.
    let raw: Vec<&str> = text.split('\n').collect();
    // Trim trailing empty lines so the last visible line is real content.
    let mut end = raw.len();
    while end > 0 && raw[end - 1].trim_end().is_empty() {
        end -= 1;
    }
    let slice = &raw[..end];
    let start = slice.len().saturating_sub(max_h);
    slice[start..]
        .iter()
        .map(|l| {
            let t = l.trim_end_matches(['\r', ' ', '\t'][..].as_ref());
            // Truncate by characters to avoid splitting on a UTF-8 boundary.
            let mut out = String::new();
            let mut w = 0;
            for ch in t.chars() {
                // Crude width: 1 per char. ratatui will handle wide chars
                // when the Paragraph is rendered.
                if w + 1 > max_w {
                    break;
                }
                out.push(ch);
                w += 1;
            }
            out
        })
        .collect()
}
