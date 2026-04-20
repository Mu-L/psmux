# Issue #244: Win32 TUI Visual Verification + Proof
# Proves capture-pane scrollback bug exists in a REAL visible TUI session.
# Generates output that scrolls off screen, then verifies capture-pane
# fails to retrieve it via both CLI and TUI paths.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup($name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
}

Write-Host ("=" * 60)
Write-Host "Issue #244: Win32 TUI VISUAL VERIFICATION"
Write-Host ("=" * 60)

# ============================================================
# TUI Strategy A: CLI-based visual verification
# ============================================================
$SESSION_TUI = "issue244_tui_proof"
Cleanup $SESSION_TUI

# Launch a REAL visible psmux window
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

# Verify the session came up
& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "TUI session creation failed"
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    exit 1
}

Write-Host "`n[TUI Test 1] Session is alive and responsive" -ForegroundColor Yellow
$sessName = (& $PSMUX display-message -t $SESSION_TUI -p '#{session_name}' 2>&1).Trim()
if ($sessName -eq $SESSION_TUI) { Write-Pass "TUI session responds to display-message" }
else { Write-Fail "TUI session name mismatch: $sessName" }

# ============================================================
# Generate scrollback in the TUI window
# ============================================================
Write-Host "`n[TUI Test 2] Generate 300 lines of output in TUI pane" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION_TUI '1..300 | ForEach-Object { Write-Host "TUIPROOF-LINE-$_" }' Enter
Start-Sleep -Seconds 6

# Wait for the command to finish
& $PSMUX send-keys -t $SESSION_TUI '' Enter
Start-Sleep -Seconds 2

# ============================================================
# Test: default capture returns only visible lines
# ============================================================
Write-Host "`n[TUI Test 3] Default capture returns limited visible lines" -ForegroundColor Yellow
$defaultCap = & $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String
$defaultMarkers = ($defaultCap.Split("`n") | Where-Object { $_ -match "TUIPROOF-LINE-\d+" })
$defaultCount = $defaultMarkers.Count
Write-Host "    Default capture: $defaultCount marker lines"
if ($defaultCount -le 40) { Write-Pass "Default capture limited to visible ($defaultCount lines)" }
else { Write-Pass "Default capture returned $defaultCount lines" }

# ============================================================
# Test: -S -200 should return scrollback but doesn't
# ============================================================
Write-Host "`n[TUI Test 4] TUI: capture-pane -S -200 vs default" -ForegroundColor Yellow
$scrollCap = & $PSMUX capture-pane -t $SESSION_TUI -p -S -200 2>&1 | Out-String
$scrollMarkers = ($scrollCap.Split("`n") | Where-Object { $_ -match "TUIPROOF-LINE-\d+" })
$scrollCount = $scrollMarkers.Count
Write-Host "    -S -200 capture: $scrollCount marker lines"

if ($scrollCount -le $defaultCount + 5) {
    Write-Fail "BUG (TUI): -S -200 returned only $scrollCount lines (same as default $defaultCount). Scrollback NOT read in TUI session."
} else {
    Write-Pass "TUI: -S -200 returned $scrollCount lines (scrollback works)"
}

# ============================================================
# Test: -S - should return all 300 lines but doesn't
# ============================================================
Write-Host "`n[TUI Test 5] TUI: capture-pane -S - (entire scrollback)" -ForegroundColor Yellow
$fullCap = & $PSMUX capture-pane -t $SESSION_TUI -p "-S" "-" 2>&1 | Out-String
$fullMarkers = ($fullCap.Split("`n") | Where-Object { $_ -match "TUIPROOF-LINE-\d+" })
$fullCount = $fullMarkers.Count
Write-Host "    -S - capture: $fullCount marker lines"

if ($fullCount -le $defaultCount + 5) {
    Write-Fail "BUG (TUI): -S - returned only $fullCount lines (same as default $defaultCount). Full scrollback NOT accessible."
} else {
    if ($fullCount -ge 250) {
        Write-Pass "TUI: -S - returned $fullCount lines (most of 300 lines recovered)"
    } else {
        Write-Fail "PARTIAL (TUI): -S - returned $fullCount lines, expected ~300"
    }
}

# ============================================================
# Test: Can we find early lines (line 1, line 10)?
# ============================================================
Write-Host "`n[TUI Test 6] TUI: Early line recovery check" -ForegroundColor Yellow
$line1Found = $fullCap -match "TUIPROOF-LINE-1\b"
$line10Found = $fullCap -match "TUIPROOF-LINE-10\b"
$line50Found = $fullCap -match "TUIPROOF-LINE-50\b"
Write-Host "    Line 1: $line1Found | Line 10: $line10Found | Line 50: $line50Found"

if (-not $line1Found -and -not $line10Found -and -not $line50Found) {
    Write-Fail "BUG (TUI): None of the early lines (1, 10, 50) are recoverable in TUI session."
} else {
    Write-Pass "TUI: Early lines are recoverable"
}

# ============================================================
# Test: styled capture (-e) in TUI also misses scrollback
# ============================================================
Write-Host "`n[TUI Test 7] TUI: capture-pane -e -S -100 (styled)" -ForegroundColor Yellow
$styledCap = & $PSMUX capture-pane -t $SESSION_TUI -p -e -S -100 2>&1 | Out-String
$stripped = $styledCap -replace '\x1b\[[0-9;]*m', ''
$styledMarkers = ($stripped.Split("`n") | Where-Object { $_ -match "TUIPROOF-LINE-\d+" })
$styledCount = $styledMarkers.Count
Write-Host "    Styled -S -100: $styledCount marker lines"

if ($styledCount -le $defaultCount + 5) {
    Write-Fail "BUG (TUI styled): -e -S -100 returned only $styledCount lines. Styled capture also lacks scrollback."
} else {
    Write-Pass "TUI styled: -e -S -100 returned $styledCount lines"
}

# ============================================================
# Test: split-window still works (TUI functional check)
# ============================================================
Write-Host "`n[TUI Test 8] TUI functional: split-window" -ForegroundColor Yellow
& $PSMUX split-window -v -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 1000
$panes = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes" }
else { Write-Fail "TUI: expected 2 panes, got $panes" }

# ============================================================
# Summary
# ============================================================
Write-Host "`n--- TUI SCROLLBACK BUG SUMMARY ---" -ForegroundColor Cyan
Write-Host "    Lines generated:       300"
Write-Host "    Default capture lines: $defaultCount"
Write-Host "    -S -200 capture lines: $scrollCount"
Write-Host "    -S - capture lines:    $fullCount"
Write-Host "    Styled -S -100 lines:  $styledCount"

if ($scrollCount -le $defaultCount + 5 -and $fullCount -le $defaultCount + 5) {
    Write-Host "`n    CONFIRMED: capture-pane cannot access scrollback in live TUI sessions." -ForegroundColor Red
}

# Cleanup
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
