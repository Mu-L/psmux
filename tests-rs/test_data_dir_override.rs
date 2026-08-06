// Regression tests for the PSMUX_DATA_DIR override (a41720f).
//
// Every data-directory consumer used to resolve the root on its own,
// mixing USERPROFILE/HOME; the fix routes them all through
// `paths::psmux_dir()` and lets an absolute PSMUX_DATA_DIR take precedence.
//
// Contracts locked here:
//
//   - with PSMUX_DATA_DIR set, every derived path (.port/.key/.sid/.pid/
//     .spawnlock, fixed-name files, server markers) lands under the
//     override root
//   - trailing separators are trimmed
//   - a relative or empty value is rejected (assertion panic)
//   - with the variable unset, the default home-based root is restored
//
// Env is process-global, so every test in this file serializes on
// ENV_LOCK and restores the previous value via a Drop guard.

use super::*;

use parking_lot::Mutex;

static ENV_LOCK: Mutex<()> = Mutex::new(());

/// An absolute path for this platform (is_absolute() semantics differ).
#[cfg(windows)]
fn abs_root() -> &'static str {
    "C:\\psmux\\data\\root"
}

#[cfg(not(windows))]
fn abs_root() -> &'static str {
    "/psmux/data/root"
}

/// Restores a mutated env var on drop, so a failure mid-test cannot leak
/// the value into other tests.
struct EnvGuard {
    var: &'static str,
    prev: Option<std::ffi::OsString>,
}

impl EnvGuard {
    fn set(var: &'static str, value: &str) -> EnvGuard {
        let prev = std::env::var_os(var);
        std::env::set_var(var, value);
        EnvGuard { var, prev }
    }

    fn remove(var: &'static str) -> EnvGuard {
        let prev = std::env::var_os(var);
        std::env::remove_var(var);
        EnvGuard { var, prev }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        match &self.prev {
            Some(value) => std::env::set_var(self.var, value),
            None => std::env::remove_var(self.var),
        }
    }
}

/// With PSMUX_DATA_DIR set, every derived path must live under the override
/// root; removing the variable restores the default root.
#[test]
fn data_dir_env_reroutes_every_derived_path() {
    let _lock = ENV_LOCK.lock();
    let _clean = EnvGuard::remove("PSMUX_DATA_DIR");
    let default_dir = psmux_dir();

    let _override = EnvGuard::set("PSMUX_DATA_DIR", abs_root());
    assert_eq!(psmux_dir(), abs_root());
    assert_eq!(psmux_dir_opt(), Some(abs_root().to_string()));
    assert_eq!(port_file("sess"), format!("{}\\sess.port", abs_root()));
    assert_eq!(key_file("sess"), format!("{}\\sess.key", abs_root()));
    assert_eq!(sid_file("sess"), format!("{}\\sess.sid", abs_root()));
    assert_eq!(pid_file("sess"), format!("{}\\sess.pid", abs_root()));
    assert_eq!(spawnlock_file("sess"), format!("{}\\sess.spawnlock", abs_root()));
    assert_eq!(port_file_opt("sess"), Some(format!("{}\\sess.port", abs_root())));
    assert_eq!(psmux_dir_file("latency.log"), format!("{}\\latency.log", abs_root()));
    assert_eq!(server_marker_dir(), format!("{}\\servers", abs_root()));
    assert_eq!(server_marker_file(42), format!("{}\\servers\\42", abs_root()));

    drop(_override);
    assert_eq!(
        psmux_dir(),
        default_dir,
        "removing PSMUX_DATA_DIR must restore the home-based root"
    );
}

/// Trailing '/' and '\\' are trimmed from the override root.
#[test]
fn data_dir_env_trims_trailing_separators() {
    let _lock = ENV_LOCK.lock();
    for raw in [format!("{}/", abs_root()), format!("{}\\", abs_root())] {
        let _g = EnvGuard::set("PSMUX_DATA_DIR", &raw);
        assert_eq!(psmux_dir(), abs_root(), "raw value {raw:?}");
    }
}

/// A relative or empty PSMUX_DATA_DIR is a configuration error and must be
/// rejected loudly, never silently resolved relative to the CWD.
#[test]
fn relative_or_empty_data_dir_is_rejected() {
    let _lock = ENV_LOCK.lock();
    for bad in ["", ".", "relative/path", "C:relative"] {
        let _g = EnvGuard::set("PSMUX_DATA_DIR", bad);
        let result = std::panic::catch_unwind(psmux_dir_opt);
        assert!(
            result.is_err(),
            "PSMUX_DATA_DIR={bad:?} must panic instead of resolving"
        );
    }
}

/// Without PSMUX_DATA_DIR the data root falls back to the home directory,
/// and the fallback is unaffected by the override code path.
#[test]
fn unset_data_dir_falls_back_to_home_root() {
    let _lock = ENV_LOCK.lock();
    let _clean = EnvGuard::remove("PSMUX_DATA_DIR");
    // Pin USERPROFILE so the fallback is deterministic on every platform
    // (home_dir() prefers USERPROFILE over HOME).
    let _profile = EnvGuard::set("USERPROFILE", "/unit/test_home");
    let _home = EnvGuard::remove("HOME");
    let _drive = EnvGuard::remove("HOMEDRIVE");
    let _path = EnvGuard::remove("HOMEPATH");

    assert_eq!(psmux_dir(), "/unit/test_home\\.psmux");
    assert_eq!(psmux_dir_opt(), Some("/unit/test_home\\.psmux".to_string()));
    assert_eq!(port_file("sess"), "/unit/test_home\\.psmux\\sess.port");
}
