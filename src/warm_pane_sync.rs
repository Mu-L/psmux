//! Centralised lifecycle for the warm pane.
//!
//! The warm pane is a snapshot of server state at spawn time: shell
//! binary, environment, terminal dimensions, vt100 scrollback cap.
//! When any of those change, the snapshot becomes stale.  Without a
//! single owner of "what does the warm pane need now?", each
//! invalidation site grew its own ad-hoc kill+respawn — which led to
//! gaps:
//!
//!   * `set-option default-shell` killed the warm pane but never
//!     respawned (only handled in one of two SetOption paths).
//!   * `set-option allow-predictions` was reconciled at boot only,
//!     never at runtime.
//!   * `set-option default-terminal` updated `app.environment["TERM"]`
//!     but the warm pane kept the old TERM forever.
//!   * `set-option history-limit` was not propagated at all (#271).
//!
//! This module is the only place that decides what to do, and the
//! only place that mutates `app.warm_pane`.
//!
//! Three response kinds, in increasing cost:
//!
//!   `Noop`             — change does not affect the warm pane.
//!   `Patch(...)`       — mutate the running pane in place (cheap,
//!                         keeps the shell warm).  Used for state
//!                         that only lives in the vt100 parser.
//!   `Respawn(reason)`  — kill the child shell and pre-spawn a new
//!                         one with current `AppState`.  Required for
//!                         anything that affects the child process
//!                         (env vars, shell binary, predictions).
//!
//! `apply` honours `app.warm_enabled`: if warm panes are disabled,
//! `Respawn` degrades to a kill with no respawn.

use crate::types::AppState;

/// Decision returned by the `for_*` helpers.  Apply via [`apply`].
pub enum WarmPaneSync {
    Noop,
    Patch(WarmPanePatch),
    Respawn(&'static str),
}

/// In-place mutations safe to perform on a running warm pane.
#[derive(Clone)]
pub enum WarmPanePatch {
    /// Resize the vt100 parser's scrollback cap.  Trims oldest rows
    /// if shrinking.  See `vt100::Screen::set_scrollback_len`.
    HistoryLimit(usize),
}

/// Decide what the warm pane needs given that a server option changed.
/// The caller has already mutated `app` so this reads the new value
/// straight off `AppState`, not from the raw `value` string.
///
/// Adding a new option that affects the warm pane?  Add it here.
/// Forgetting to do so leaves the warm pane stale until the next
/// kill-everything event (server restart, env-var change, resize),
/// which is exactly the class of bug this module exists to prevent.
pub fn for_option_change(name: &str, app: &AppState) -> WarmPaneSync {
    match name {
        // Parser-only: patch in place, no shell restart needed.
        // Kept cheap because users may set this in the prompt and we
        // do not want to throw away ~470ms of shell init for it.
        "history-limit" => WarmPaneSync::Patch(WarmPanePatch::HistoryLimit(app.history_limit)),

        // The shell binary itself differs — must respawn.
        "default-shell" => WarmPaneSync::Respawn("default-shell changed"),

        // We send a different PSReadLine init script depending on this
        // option (PSRL_FIX vs PSRL_CRASH_GUARD).  The script runs once
        // at shell startup, so a running shell is stuck with whichever
        // it got — only a fresh spawn picks up the new value (#165).
        "allow-predictions" => WarmPaneSync::Respawn("allow-predictions changed"),

        // default-terminal feeds `TERM` into the child env at spawn
        // time.  An already-running child has the old TERM baked in.
        "default-terminal" => WarmPaneSync::Respawn("default-terminal changed"),

        // Claude Code TTY-shim flags are read by `set_tmux_env` at
        // spawn time — running children miss the change.
        "claude-code-fix-tty" | "claude-code-force-interactive" => {
            WarmPaneSync::Respawn("claude-code option changed")
        }

        // Everything else either does not affect the warm pane (status
        // styles, key tables, hooks, etc.) or is read live (mouse,
        // status-visible) so no warm-pane action is required.
        _ => WarmPaneSync::Noop,
    }
}

/// `set-environment` / `unset-environment` always require a respawn:
/// you cannot mutate a running process's environment block from
/// outside (kernel-level constraint), so the child must be re-execed.
/// Already-handled in the codebase prior to this module (#137); now
/// consolidated through one entry point.
pub fn for_env_change() -> WarmPaneSync {
    WarmPaneSync::Respawn("environment changed")
}

/// When the client terminal resizes, the warm pane's parser grid is
/// at the old dimensions.  Respawn at the new size so the next
/// transplant lands pixel-perfect on the first frame with no reflow.
pub fn for_resize(app: &AppState, new_rows: u16, new_cols: u16) -> WarmPaneSync {
    match app.warm_pane.as_ref() {
        Some(wp) if wp.rows == new_rows && wp.cols == new_cols => WarmPaneSync::Noop,
        _ => WarmPaneSync::Respawn("client resized"),
    }
}

/// After the user's config has been parsed at server boot, the
/// early-warm pane (born with all defaults) needs to be reconciled
/// with whatever the config actually set.  Returns the cheapest
/// action that gets the warm pane to a state consistent with `app`.
///
/// Order matters: respawn-class triggers are checked first because a
/// respawn implicitly applies all patch-class state to the new pane.
pub fn for_post_config(app: &AppState) -> WarmPaneSync {
    // Config disabled warm panes — `apply` handles this by killing
    // without respawning when `warm_enabled` is false.
    if !app.warm_enabled {
        return WarmPaneSync::Respawn("warm panes disabled by config");
    }

    // Custom default-shell set: the early warm pane has the wrong
    // shell binary.  Respawn to get the right one.  Doing this at
    // post-config time (rather than killing-and-deferring) keeps
    // create_window's fast path warm.
    if !app.default_shell.is_empty() {
        return WarmPaneSync::Respawn("post-config: custom default-shell");
    }

    // Config injected env vars (e.g. via set -g default-terminal,
    // set-environment in the config, or update-environment passing
    // through client env): the early child has them missing.
    let needs_env = app.environment.iter().any(|(k, _)| {
        !k.starts_with("PSMUX_TARGET_SESSION") && k != "TMUX" && k != "TMUX_PANE"
    });
    if needs_env {
        return WarmPaneSync::Respawn("post-config: env vars set");
    }

    // Config flipped allow-predictions on — the early pwsh got the
    // wrong PSReadLine init.
    if app.allow_predictions {
        return WarmPaneSync::Respawn("post-config: predictions enabled");
    }

    // history-limit only differs in the parser cap, no respawn.
    if app.history_limit != 2000 {
        return WarmPaneSync::Patch(WarmPanePatch::HistoryLimit(app.history_limit));
    }

    WarmPaneSync::Noop
}

/// The single mutation point for `app.warm_pane`.  Every other call
/// site outside of pre-warm boot and consume paths goes through here.
pub fn apply(
    app: &mut AppState,
    pty_system: &dyn portable_pty::PtySystem,
    sync: WarmPaneSync,
) {
    match sync {
        WarmPaneSync::Noop => {}
        WarmPaneSync::Patch(patch) => apply_patch(app, patch),
        WarmPaneSync::Respawn(_reason) => respawn(app, pty_system),
    }
}

fn apply_patch(app: &mut AppState, patch: WarmPanePatch) {
    let wp = match app.warm_pane.as_ref() {
        Some(wp) => wp,
        None => return,
    };
    match patch {
        WarmPanePatch::HistoryLimit(n) => {
            if let Ok(mut parser) = wp.term.lock() {
                if parser.screen().scrollback_len() != n {
                    parser.screen_mut().set_scrollback_len(n);
                }
            }
        }
    }
}

fn respawn(app: &mut AppState, pty_system: &dyn portable_pty::PtySystem) {
    // Always kill any existing warm pane first — there is no in-place
    // way to swap shell binaries or environment blocks.
    if let Some(mut old) = app.warm_pane.take() {
        old.child.kill().ok();
    }
    // Honour warm_enabled: a config-disabled warm pane must not come
    // back to life after a Respawn — the user opted out.
    if !app.warm_enabled {
        return;
    }
    match crate::pane::spawn_warm_pane(pty_system, app) {
        Ok(wp) => {
            app.warm_pane = Some(wp);
        }
        Err(_) => {
            // Best-effort: if a respawn fails (e.g. transient PTY
            // creation error) we leave warm_pane = None and the next
            // consume path falls back to a synchronous cold spawn.
        }
    }
}

/// Helper for warm-pane consume sites in `pane.rs`.  When a warm
/// pane is transplanted into a real session, its parser may still
/// hold a stale scrollback cap (config raised history-limit after
/// the pane was born and the patch was missed).  This is the safety
/// net that guarantees consume-time consistency even if a future
/// caller forgets to invoke `apply` on a state change.
pub fn reconcile_consumed_parser(parser: &mut vt100::Parser, history_limit: usize) {
    if parser.screen().scrollback_len() != history_limit {
        parser.screen_mut().set_scrollback_len(history_limit);
    }
}

#[cfg(test)]
#[path = "../tests-rs/test_warm_pane_sync.rs"]
mod test_warm_pane_sync;
