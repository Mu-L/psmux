#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/install-psmux-win-$$
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/home" "$tmp/config"

HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" \
    sh "$repo/scripts/install-psmux-win.sh" \
        --host user@windows-host \
        --psmux C:/Users/user/.cargo/bin/psmux.exe \
        --bin-dir "$tmp/bin" >/dev/null

[ -x "$tmp/bin/psmux-win" ] || {
    echo 'FAIL: psmux-win was not installed executable' >&2
    exit 1
}
grep -Fx 'host=user@windows-host' "$tmp/config/psmux-win/config" >/dev/null
grep -Fx 'remote_psmux=C:/Users/user/.cargo/bin/psmux.exe' "$tmp/config/psmux-win/config" >/dev/null

HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" \
    sh "$repo/scripts/install-psmux-win.sh" \
        --host user@windows-host \
        --psmux psmux \
        --bin-dir "$tmp/bin" >/dev/null

find "$tmp/bin" -name 'psmux-win.backup-*' | grep . >/dev/null || {
    echo 'FAIL: reinstall did not back up the launcher' >&2
    exit 1
}
find "$tmp/config/psmux-win" -name 'config.backup-*' | grep . >/dev/null || {
    echo 'FAIL: reinstall did not back up the config' >&2
    exit 1
}
grep -Fx 'remote_psmux=psmux' "$tmp/config/psmux-win/config" >/dev/null

echo 'PASS: installer creates executable and config, then backs both up on reinstall'
