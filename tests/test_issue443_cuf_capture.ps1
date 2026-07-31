# Issue #443: cells skipped by a cursor advance must survive capture.
#
# Root cause: a never-written grid cell reports empty contents(), so a
# serializer that pushes contents() verbatim emitted nothing for it and the
# on-screen gap closed up, fusing adjacent words. The boundary is written vs
# never-written cells, not CUF vs CHA: literal spaces survive because they
# materialize a real cell, and BOTH ESC[nC (CUF) and ESC[nG (CHA) leave the
# skipped cells empty.
#
# src/copy_mode.rs::push_capture_cell backfills a space for every in-bounds
# blank cell and skips the trailing half of a wide glyph (otherwise every
# CJK/wide character would gain a phantom column). capture_row_text applies
# that to a column range, and every capture/copy path routes through it:
#   -p / ranged / -e   ... capture-pane text paths
#   capture-pane       ... no -p, i.e. capture into a paste buffer
#   copy-mode yank     ... Char/Line/Rect, and D (copy to end of line)
#
# The copy-mode yank paths need TUI key input, so they are covered by the Rust
# tests in tests-rs/test_issue443_blank_cell_capture.rs (registered from
# src/copy_mode.rs). This script covers the CLI-reachable capture paths.
#
# The payload is emitted from a script file (tests/payload_issue443_cuf.ps1)
# rather than through send-keys, because send-keys collapses interior
# whitespace in its argument and would confound the capture assertions.
#
# Isolation (AGENTS.md): runs under New-PsmuxTestEnv, which redirects
# USERPROFILE/HOME to a throwaway dir and scrubs inherited PSMUX_*/TMUX vars,
# plus a dedicated -L namespace. It therefore cannot see, disturb, or kill a
# psmux session the user is running for real.

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# SAFETY GATE — please read before removing.
#
# This script starts a real server, so it is NOT safe on a machine running
# psmux sessions you care about, and New-PsmuxTestEnv does not make it safe:
#
#   main.rs:223 calls reap_orphaned_servers() on EVERY psmux invocation,
#   BEFORE -L is parsed. reap_orphaned_servers_in() bails out only when the
#   data dir does NOT exist (the #474 guard). New-PsmuxTestEnv *creates* an
#   empty .psmux under the throwaway home, so the guard passes with an empty
#   registry. The reaper then enumerates loopback listeners MACHINE-WIDE
#   (GetExtendedTcpTable), keeps every process whose image is psmux/tmux/pmux,
#   and terminates each one older than ORPHAN_REAP_MIN_AGE that the empty
#   registry does not account for — i.e. every psmux server on the box, in
#   every namespace. -L cannot help: it is parsed after the reaper has run.
#
# Until that guard also covers "dir exists but registry is empty", this runs
# only where terminating every server on the box is harmless: a CI runner
# (detected automatically) or an explicit opt-in for a disposable Windows
# account or VM:
#
#   $env:PSMUX_ALLOW_DESTRUCTIVE_TESTS = '1'
#
# CI is auto-detected on purpose. Requiring the opt-in there would make the
# nightly integration suite skip this script and report a green pass for a test
# that never ran, which is worse than not having it.
#
# The CUF/CHA/wide-glyph serialization contract this script exercises is also
# covered, with no server at all, by the Rust tests in
# tests-rs/test_issue443_blank_cell_capture.rs (run: cargo test --bin psmux
# tests_issue443). Prefer those for local verification.
# ---------------------------------------------------------------------------
$isDisposable = $env:PSMUX_ALLOW_DESTRUCTIVE_TESTS -or $env:CI -or $env:GITHUB_ACTIONS
if (-not $isDisposable) {
    Write-Host "[SKIP] test_issue443_cuf_capture: starts a real server; psmux's orphan reaper" -ForegroundColor Yellow
    Write-Host "       would terminate every psmux server on this machine (see header)." -ForegroundColor Yellow
    Write-Host "       Set PSMUX_ALLOW_DESTRUCTIVE_TESTS=1 in a disposable environment to run it." -ForegroundColor Yellow
    Write-Host "       Server-free coverage: cargo test --bin psmux tests_issue443" -ForegroundColor Yellow
    exit 0
}

. "$PSScriptRoot\psmux_test_helpers.ps1"

$ctx = New-PsmuxTestEnv -Tag 'i443'
$PSMUX = $ctx.PsmuxExe
$ns = Register-PsmuxNamespace -Ctx $ctx -Namespace "i443"
$S = "i443"
$payload = Join-Path $PSScriptRoot "payload_issue443_cuf.ps1"

$pass = 0; $fail = 0
function Check($name, $got, $want) {
    if ($got -ceq $want) {
        Write-Host ("  [PASS] {0}" -f $name) -ForegroundColor Green; $script:pass++
    } else {
        Write-Host ("  [FAIL] {0}: got=[{1}] want=[{2}]" -f $name, ($got -replace ' ', '.'), ($want -replace ' ', '.')) -ForegroundColor Red
        $script:fail++
    }
}

Write-Host ""
Write-Host "=== #443 capture keeps cursor-skipped cells ===" -ForegroundColor Cyan
Write-Host "  psmux: $PSMUX  namespace: $ns" -ForegroundColor DarkGray

try {
    & $PSMUX -L $ns new-session -d -s $S -x 80 -y 24 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    & $PSMUX -L $ns send-keys -t $S 'clear' Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    & $PSMUX -L $ns send-keys -t $S "chcp 65001 > `$null; [Console]::OutputEncoding=[Text.Encoding]::UTF8; powershell -NoProfile -ExecutionPolicy Bypass -File `"$payload`"" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    # Index the captured lines by their leading marker.
    function Index-Lines($lines) {
        $g = @{}
        $lines | ForEach-Object {
            if ($_ -match "^SPCA") { $g.SPC = $_ }
            elseif ($_ -match "^CUFA") { $g.CUF = $_ }
            elseif ($_ -match "^CHAA") { $g.CHA = $_ }
            elseif ($_ -match "^WIDE:") { $g.WIDE = $_ }
        }
        return $g
    }

    # --- capture-pane -p (text path) ---
    Write-Host "  --- capture-pane -p ---" -ForegroundColor DarkGray
    $g = Index-Lines (& $PSMUX -L $ns capture-pane -t $S -p)
    Check "CUF gaps (4 spaces each)"    $g.CUF "CUFA    CUFB    CUFC    CUFD"
    Check "CHA gaps (5 then 6 spaces)"  $g.CHA "CHAA     CHAB      CHAC"
    Check "literal spaces intact"       $g.SPC "SPCA    SPCB    SPCC"

    # Wide/CJK regression guard (issue #441): the two CJK glyphs must sit
    # adjacent with NO phantom space between or around them. Assert via
    # space-free structure rather than a literal CJK string, since the outer
    # console may not encode CJK (it would ?-substitute the expected literal
    # and give a false failure).
    $wideOk = ($g.WIDE -notmatch ' ') -and $g.WIDE.StartsWith("WIDE:") -and $g.WIDE.EndsWith(":END")
    if ($wideOk) { Write-Host "  [PASS] wide/CJK no phantom spaces (#441 guard)" -ForegroundColor Green; $pass++ }
    else { Write-Host ("  [FAIL] wide/CJK: got=[{0}]" -f ($g.WIDE -replace ' ', '.')) -ForegroundColor Red; $fail++ }

    # --- capture-pane -e (styled path) ---
    Write-Host "  --- capture-pane -p -e (SGR-stripped) ---" -ForegroundColor DarkGray
    $cufe = ((& $PSMUX -L $ns capture-pane -t $S -p -e) | Where-Object { $_ -match "CUFA" }) -replace "$([char]27)\[[0-9;]*m", ""
    Check "CUF gaps preserved in -e" $cufe "CUFA    CUFB    CUFC    CUFD"

    # --- capture-pane with NO -p: capture into a paste buffer ---
    # Same command, buffer variant. This path kept the old inline serializer
    # and still collapsed the gaps; save-buffer is the CLI way to read it back.
    Write-Host "  --- capture-pane (no -p) + save-buffer ---" -ForegroundColor DarkGray
    $bufFile = Join-Path $ctx.Home "i443_buffer.txt"
    & $PSMUX -L $ns capture-pane -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    & $PSMUX -L $ns save-buffer $bufFile 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    if (Test-Path $bufFile) {
        $gb = Index-Lines (Get-Content $bufFile)
        Check "buffer: CUF gaps"        $gb.CUF "CUFA    CUFB    CUFC    CUFD"
        Check "buffer: CHA gaps"        $gb.CHA "CHAA     CHAB      CHAC"
        Check "buffer: literal spaces"  $gb.SPC "SPCA    SPCB    SPCC"
        $wideBufOk = ($gb.WIDE -notmatch ' ') -and $gb.WIDE.StartsWith("WIDE:") -and $gb.WIDE.EndsWith(":END")
        if ($wideBufOk) { Write-Host "  [PASS] buffer: wide/CJK no phantom spaces" -ForegroundColor Green; $pass++ }
        else { Write-Host ("  [FAIL] buffer: wide/CJK: got=[{0}]" -f ($gb.WIDE -replace ' ', '.')) -ForegroundColor Red; $fail++ }
    } else {
        Write-Host "  [FAIL] save-buffer produced no file at $bufFile" -ForegroundColor Red; $fail++
    }
}
finally {
    Remove-PsmuxTestEnv -Ctx $ctx
}

Write-Host ""
Write-Host "RESULT: PASS=$pass FAIL=$fail"
exit $fail
