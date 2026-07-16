//! Single source of truth for psmux's home and data directories.
//!
//! Every `.port`/`.key`/`.sid`/warm-pool/log path routes through [`psmux_dir`]
//! (or [`psmux_dir_opt`]), so client and server can never disagree about where
//! the bookkeeping lives.

/// User home directory: `USERPROFILE`, then the Windows profile API, then
/// `HOMEDRIVE`+`HOMEPATH`, then `HOME`. Empty string when nothing resolves.
///
/// `HOME` is deliberately the LAST resort on Windows (issue #474): MSYS2
/// login shells unset `USERPROFILE` and set `HOME` to a POSIX-style path
/// (`/home/user`), so a psmux invocation from an MSYS2 shell that trusted
/// `HOME` would resolve the data dir somewhere the registry does not live.
/// The startup orphan reaper would then see every live server as untracked
/// and terminate them all. Querying the profile API keeps every invocation
/// of the same user converging on the same data dir regardless of which
/// shell launched it.
pub fn home_dir() -> String {
    if let Ok(v) = std::env::var("USERPROFILE") {
        if !v.is_empty() {
            return v;
        }
    }
    #[cfg(windows)]
    if let Some(p) = windows_profile_dir() {
        return p;
    }
    let drive = std::env::var("HOMEDRIVE").unwrap_or_default();
    let path = std::env::var("HOMEPATH").unwrap_or_default();
    if !drive.is_empty() && !path.is_empty() {
        let p = format!("{}{}", drive, path);
        if std::path::Path::new(&p).is_dir() {
            return p;
        }
    }
    std::env::var("HOME").unwrap_or_default()
}

/// The current user's profile directory straight from the OS
/// (`GetUserProfileDirectoryW` on the process token), independent of any
/// environment variable a shell may have rewritten or unset.
#[cfg(windows)]
fn windows_profile_dir() -> Option<String> {
    use std::ffi::c_void;
    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentProcess() -> *mut c_void;
        fn OpenProcessToken(process: *mut c_void, access: u32, token: *mut *mut c_void) -> i32;
        fn CloseHandle(h: *mut c_void) -> i32;
    }
    #[link(name = "userenv")]
    extern "system" {
        fn GetUserProfileDirectoryW(token: *mut c_void, buf: *mut u16, len: *mut u32) -> i32;
    }
    const TOKEN_QUERY: u32 = 0x0008;
    unsafe {
        let mut token: *mut c_void = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return None;
        }
        let mut buf = [0u16; 512];
        let mut len = buf.len() as u32;
        let ok = GetUserProfileDirectoryW(token, buf.as_mut_ptr(), &mut len);
        CloseHandle(token);
        if ok == 0 || len == 0 {
            return None;
        }
        let s = String::from_utf16_lossy(&buf[..(len as usize).saturating_sub(1)]);
        if s.is_empty() { None } else { Some(s) }
    }
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

#[cfg(test)]
#[path = "../tests-rs/test_issue474_home_resolution.rs"]
mod tests_issue474_home_resolution;
