//! Build script for psmux.
//!
//! Captures the exact git commit the binary was built from and exposes it to
//! the crate as compile-time environment variables:
//!
//!   * `PSMUX_GIT_HASH`      — short commit hash (e.g. `f179849`), or `unknown`
//!   * `PSMUX_GIT_HASH_FULL` — full 40-char commit hash, or `unknown`
//!   * `PSMUX_GIT_DIRTY`     — `true` if the working tree had uncommitted
//!                             changes at build time, otherwise `false`
//!   * `PSMUX_GIT_DATE`      — commit date (YYYY-MM-DD), or `unknown`
//!
//! Git may be unavailable (for example when the crate is built from a
//! crates.io tarball rather than a git checkout). In that case every value
//! falls back gracefully to `unknown` / `false` so the build always succeeds.
//!
//! On Windows the script additionally embeds a Win32 resource block into the
//! executable: the application icon plus a VS_VERSIONINFO record. Without it
//! Windows has no name, description or version to show for the process, so
//! Task Manager, the taskbar, alt-tab and consent dialogs such as the one
//! 1Password raises all display a nameless generic entry (issue #620).

use std::process::Command;

fn main() {
    // Rebuild whenever HEAD moves (new commit, checkout, etc.) so the embedded
    // hash never goes stale. These files may not exist in a tarball build; the
    // rerun hints are harmless if absent.
    println!("cargo:rerun-if-changed=.git/HEAD");
    println!("cargo:rerun-if-changed=.git/refs");

    embed_windows_resources();

    let short = git(&["rev-parse", "--short", "HEAD"]).unwrap_or_else(|| "unknown".to_string());
    let full = git(&["rev-parse", "HEAD"]).unwrap_or_else(|| "unknown".to_string());
    let date = git(&["show", "-s", "--format=%cd", "--date=short", "HEAD"])
        .unwrap_or_else(|| "unknown".to_string());

    // "Dirty" means tracked, version-controlled source differs from HEAD, i.e.
    // the binary can no longer be reproduced from the named commit alone.
    // `--untracked-files=no` deliberately ignores untracked files (build tool
    // state, editor scratch, etc.) so they never produce a false "dirty" flag.
    let dirty = git(&["status", "--porcelain", "--untracked-files=no"])
        .map(|s| !s.is_empty())
        .unwrap_or(false);

    println!("cargo:rustc-env=PSMUX_GIT_HASH={short}");
    println!("cargo:rustc-env=PSMUX_GIT_HASH_FULL={full}");
    println!("cargo:rustc-env=PSMUX_GIT_DIRTY={dirty}");
    println!("cargo:rustc-env=PSMUX_GIT_DATE={date}");
}

/// Embed the icon and the VS_VERSIONINFO block (Windows hosts only).
///
/// The `#[cfg(windows)]` here is the *host* platform, which is what gates the
/// `winresource` build-dependency in `Cargo.toml`. The target is checked
/// separately below so a Windows host cross-compiling to a non-Windows target
/// still produces a clean build.
#[cfg(windows)]
fn embed_windows_resources() {
    use std::path::Path;
    use winresource::{VersionInfo, WindowsResource};

    // Only PE targets carry Win32 resources. A Windows host building for,
    // say, a Linux target must skip this entirely.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }

    let icon = Path::new("assets").join("psmux.ico");
    println!("cargo:rerun-if-changed={}", icon.display());

    let version = env!("CARGO_PKG_VERSION");

    // A build that quietly dropped the icon would reintroduce #620, so treat a
    // missing asset as a build failure rather than carrying on without it.
    assert!(
        icon.is_file(),
        "{} is missing; it is required to embed the application icon",
        icon.display()
    );

    let mut res = WindowsResource::new();
    res.set_icon(icon.to_str().expect("assets/psmux.ico path is not UTF-8"));

    res.set("ProductName", "psmux")
        .set("FileDescription", "psmux terminal multiplexer")
        .set("CompanyName", "psmux")
        .set("InternalName", "psmux")
        // All three binaries (psmux, pmux, tmux) are the same image built from
        // src/main.rs; psmux.exe is the canonical name.
        .set("OriginalFilename", "psmux.exe")
        .set("LegalCopyright", "Copyright (c) psmux contributors. MIT licensed.")
        .set("FileVersion", version)
        .set("ProductVersion", version);

    // VS_FIXEDFILEINFO wants a packed u64: major.minor.patch.build, 16 bits
    // each. Cargo versions are three components, so the build field stays 0.
    let packed = packed_version(version);
    res.set_version_info(VersionInfo::FILEVERSION, packed);
    res.set_version_info(VersionInfo::PRODUCTVERSION, packed);

    if let Err(e) = res.compile() {
        // rc.exe ships with the Windows SDK, which the MSVC Rust toolchain
        // already requires, so this should not happen. Fail loudly rather than
        // silently shipping another nameless binary.
        panic!("failed to embed the Windows resource block (icon / version info): {e}");
    }
}

#[cfg(not(windows))]
fn embed_windows_resources() {}

/// Pack `major.minor.patch` into the u64 layout VS_FIXEDFILEINFO expects.
/// Non-numeric or missing components fall back to 0.
#[cfg(windows)]
fn packed_version(version: &str) -> u64 {
    let mut parts = version
        .split(['.', '-', '+'])
        .map(|p| p.parse::<u64>().unwrap_or(0));
    let major = parts.next().unwrap_or(0);
    let minor = parts.next().unwrap_or(0);
    let patch = parts.next().unwrap_or(0);
    (major << 48) | (minor << 32) | (patch << 16)
}

/// Run `git <args>` and return trimmed stdout on success, or `None` if git is
/// missing or the command failed.
fn git(args: &[&str]) -> Option<String> {
    let output = Command::new("git").args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if s.is_empty() { None } else { Some(s) }
}
