# psmux Issue #273 — Pressing prefix twice should jump to start of line
# (forwards a literal prefix keystroke to the inner shell).
#
# Verifies:
#   1. Default prefix table contains `C-b send-prefix` (tmux parity).
#   2. After `set -g prefix C-a`, `C-a send-prefix` is auto-added so the
#      user's reported nushell-with-prefix=C-a case "just works".
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue273_send_prefix.ps1

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass { param($msg) Write-Host "[PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Test { param($msg) Write-Host "[TEST] $msg" -ForegroundColor White }

$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -ErrorAction SilentlyContinue).Path
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -ErrorAction SilentlyContinue).Path }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }
Write-Info "Using: $PSMUX"

# Clean slate
& $PSMUX kill-server 2>$null
Start-Sleep -Seconds 1
Remove-Item "$env:USERPROFILE\.psmux\*.port" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\.psmux\*.key" -Force -ErrorAction SilentlyContinue

$SESSION = "test_273"

# Start a detached session
Start-Process -FilePath $PSMUX -ArgumentList "new-session -d -s $SESSION" -WindowStyle Hidden
Start-Sleep -Seconds 2

# --- Test 1: Default prefix table has `C-b send-prefix` ---
Write-Test "1: Default prefix table contains 'C-b send-prefix'"
$keys = & $PSMUX list-keys -t $SESSION 2>&1 | Out-String
if ($keys -match "C-b\s+send-prefix") {
    Write-Pass "1: C-b send-prefix is in default prefix table"
} else {
    Write-Fail "1: C-b send-prefix missing from default prefix table"
    Write-Host "list-keys output was:`n$keys"
}

# --- Test 2: Issue #273 — set prefix to C-a auto-binds C-a to send-prefix ---
Write-Test "2: 'set -g prefix C-a' auto-binds C-a to send-prefix"
& $PSMUX set-option -t $SESSION -g prefix C-a 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$keys = & $PSMUX list-keys -t $SESSION 2>&1 | Out-String
if ($keys -match "C-a\s+send-prefix") {
    Write-Pass "2: C-a send-prefix auto-added after set -g prefix C-a"
} else {
    Write-Fail "2: C-a send-prefix NOT auto-added — user's nushell case still broken"
    Write-Host "list-keys output was:`n$keys"
}

# --- Test 3: User override of the new prefix key is preserved ---
Write-Test "3: User-defined `bind C-a some-other-cmd` is not overridden"
# Reset session
& $PSMUX kill-session -t $SESSION 2>$null
Start-Sleep -Milliseconds 500
Start-Process -FilePath $PSMUX -ArgumentList "new-session -d -s $SESSION" -WindowStyle Hidden
Start-Sleep -Seconds 2

# User explicitly binds C-a to something else BEFORE setting prefix
& $PSMUX bind-key -t $SESSION C-a display-message 2>&1 | Out-Null
& $PSMUX set-option -t $SESSION -g prefix C-a 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$keys = & $PSMUX list-keys -t $SESSION 2>&1 | Out-String
# Find the line for C-a binding
$caLines = ($keys -split "`r?`n") | Where-Object { $_ -match "\bC-a\b" }
$hasUserBinding = ($caLines | Where-Object { $_ -match "display-message" }).Count -gt 0
$hasSendPrefix = ($caLines | Where-Object { $_ -match "send-prefix" }).Count -gt 0
if ($hasUserBinding -and -not $hasSendPrefix) {
    Write-Pass "3: User's C-a override preserved; send-prefix not added"
} elseif ($hasUserBinding -and $hasSendPrefix) {
    Write-Fail "3: Both bindings present — user override should win"
    Write-Host "C-a lines:`n$($caLines -join "`n")"
} else {
    Write-Fail "3: User's C-a override was lost"
    Write-Host "C-a lines:`n$($caLines -join "`n")"
}

# Cleanup
& $PSMUX kill-session -t $SESSION 2>$null
Start-Sleep -Milliseconds 500
& $PSMUX kill-server 2>$null

Write-Host ""
Write-Host "──────────────────────────────────────"
Write-Host "Issue #273 results: $script:TestsPassed passed / $script:TestsFailed failed"
Write-Host "──────────────────────────────────────"
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
