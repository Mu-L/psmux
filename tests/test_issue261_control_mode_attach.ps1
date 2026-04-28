# Issue #261: psmux -CC attach must emit initial state burst (tmux protocol bootstrap)
# Without this, iTerm2's tmux integration freezes on `tmux -CC attach`.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "issue261_cc"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 2
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

Write-Host "`n=== Issue #261: -CC attach initial state burst ===" -ForegroundColor Cyan

# Run -CC attach, send EOF immediately to terminate cleanly. We must capture
# the bootstrap notifications that should arrive BEFORE we send any command.
$outFile = "$env:TEMP\issue261_cc_out.txt"
Remove-Item $outFile -EA SilentlyContinue

# Pipe an empty stdin (EOF) so the client connects, receives the burst,
# then exits. cmd /c with `< nul` gives us a real EOF.
cmd /c "psmux -CC attach -t $SESSION < nul > `"$outFile`" 2>&1"
Start-Sleep -Seconds 1

if (-not (Test-Path $outFile)) {
    Write-Fail "No output file produced"
    Cleanup
    exit 1
}
$content = Get-Content $outFile -Raw
Write-Host "--- captured output ---"
Write-Host $content
Write-Host "--- end ---"

# Required initial-state notifications (per tmux control protocol)
if ($content -match "%sessions-changed") { Write-Pass "%sessions-changed emitted" }
else { Write-Fail "Missing %sessions-changed" }

if ($content -match "%session-changed \`$\d+ $SESSION") { Write-Pass "%session-changed `$id name emitted" }
else { Write-Fail "Missing %session-changed `$id name" }

if ($content -match "%window-add @\d+") { Write-Pass "%window-add @id emitted" }
else { Write-Fail "Missing %window-add" }

if ($content -match "%layout-change @\d+ \d+x\d+") { Write-Pass "%layout-change emitted" }
else { Write-Fail "Missing %layout-change" }

if ($content -match "%session-window-changed \`$\d+ @\d+") { Write-Pass "%session-window-changed emitted" }
else { Write-Fail "Missing %session-window-changed" }

if ($content -match "%window-pane-changed @\d+ %\d+") { Write-Pass "%window-pane-changed emitted" }
else { Write-Fail "Missing %window-pane-changed" }

# Bug regression guard: prior to fix, output was EMPTY (zero bytes of state).
if ($content.Length -gt 50) { Write-Pass "Initial burst non-trivial ($($content.Length) bytes)" }
else { Write-Fail "Output too short ($($content.Length) bytes) — bootstrap probably missing" }

Cleanup
Remove-Item $outFile -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
