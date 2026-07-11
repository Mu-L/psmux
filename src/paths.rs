//! Single source of truth for psmux's home and data directories.
//!
//! Every `.port`/`.key`/`.sid`/warm-pool/log path routes through [`psmux_dir`]
//! (or [`psmux_dir_opt`]), so client and server can never disagree about where
//! the bookkeeping lives.

/// User home directory: `USERPROFILE`, then `HOME`. Empty string if neither is
/// set (matches the historical `.unwrap_or_default()` behavior at every call
/// site).
pub fn home_dir() -> String {
    std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_default()
}

/// psmux data directory, without a trailing separator. Fallible variant for
/// call sites that early-exit when home is missing (`.ok()?` /
/// `Err(_) => return …`). `None` when no home directory is available.
pub fn psmux_dir_opt() -> Option<String> {
    let home = home_dir();
    if home.is_empty() {
        None
    } else {
        Some(format!("{}\\.psmux", home))
    }
}

/// psmux data directory, without a trailing separator. Infallible variant for
/// call sites that today use `.unwrap_or_default()`.
///
/// When no home directory is set, returns `\.psmux` — byte-identical to the
/// historical `format!("{}\.psmux", "")`. It does not panic: the historical
/// behavior is to proceed and let the filesystem call fail gracefully, and a
/// crash on an unset `USERPROFILE` would be worse.
pub fn psmux_dir() -> String {
    psmux_dir_opt().unwrap_or_else(|| "\\.psmux".to_string())
}

/// Path to a fixed-name file directly under the data directory (e.g.
/// `latency.log`, `last_session`, `next_session_id`, `crash.log`).
pub fn psmux_dir_file(name: impl AsRef<str>) -> String {
    format!("{}\\{}", psmux_dir(), name.as_ref())
}

/// Path to a session's `.port` file (the TCP port its server listens on).
pub fn port_file(session: impl AsRef<str>) -> String {
    format!("{}\\{}.port", psmux_dir(), session.as_ref())
}

/// Fallible variant of [`port_file`]: `None` when no data directory can be
/// determined. Lets a call site early-exit on the same condition without having
/// to know that `port_file` routes through `psmux_dir`.
pub fn port_file_opt(session: impl AsRef<str>) -> Option<String> {
    psmux_dir_opt().map(|dir| format!("{}\\{}.port", dir, session.as_ref()))
}

/// Path to a session's `.key` file (the auth key for its server).
pub fn key_file(session: impl AsRef<str>) -> String {
    format!("{}\\{}.key", psmux_dir(), session.as_ref())
}

/// Path to a session's `.sid` file (its stable session id).
pub fn sid_file(session: impl AsRef<str>) -> String {
    format!("{}\\{}.sid", psmux_dir(), session.as_ref())
}

/// Path to a session's `.pid` file (the liveness anchor: the server pid).
pub fn pid_file(session: impl AsRef<str>) -> String {
    format!("{}\\{}.pid", psmux_dir(), session.as_ref())
}

/// Path to a session's `.spawnlock` file (the warm-pool spawn lock).
pub fn spawnlock_file(session: impl AsRef<str>) -> String {
    format!("{}\\{}.spawnlock", psmux_dir(), session.as_ref())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn psmux_dir_is_home_relative_dot_psmux() {
        // The test environment always has a home, so the data dir resolves to
        // {home}\.psmux and the two accessors agree.
        let dir = psmux_dir();
        assert!(dir.ends_with("\\.psmux"), "got {dir:?}");
        assert_eq!(psmux_dir_opt().as_deref(), Some(dir.as_str()));
    }

    #[test]
    fn per_session_helpers_append_name_and_suffix_to_data_dir() {
        let dir = psmux_dir();
        assert_eq!(port_file("foo"), format!("{}\\foo.port", dir));
        assert_eq!(key_file("foo"), format!("{}\\foo.key", dir));
        assert_eq!(sid_file("foo"), format!("{}\\foo.sid", dir));
        assert_eq!(pid_file("foo"), format!("{}\\foo.pid", dir));
        assert_eq!(spawnlock_file("foo"), format!("{}\\foo.spawnlock", dir));
    }

    #[test]
    fn psmux_dir_file_appends_fixed_name() {
        assert_eq!(
            psmux_dir_file("latency.log"),
            format!("{}\\latency.log", psmux_dir())
        );
    }
}
