# Issue #264: paste-buffer TUI visual verification
# Win32 TUI test - launches real psmux window, drives via CLI

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION_TUI = "tui_264_proof"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

# Cleanup
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

Write-Host "`n=== Issue #264 TUI Visual Verification ===" -ForegroundColor Cyan

# Launch REAL visible psmux window
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "TUI session creation failed"
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    exit 1
}
Write-Pass "TUI session created with visible window"

# --- TUI Test 1: paste-buffer delivers to visible pane ---
Write-Host "`n[TUI Test 1] paste-buffer into visible TUI pane" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION_TUI "clear" Enter
Start-Sleep -Seconds 1

& $PSMUX set-buffer -b tui1 'echo TUI_PASTE_BUFFER_PROOF'
& $PSMUX paste-buffer -b tui1 -t $SESSION_TUI
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -t $SESSION_TUI Enter
Start-Sleep -Seconds 2

$capTui1 = & $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String
if ($capTui1 -match "TUI_PASTE_BUFFER_PROOF") {
    Write-Pass "TUI: paste-buffer delivered content to visible pane"
} else {
    Write-Fail "TUI: paste-buffer did NOT deliver content. Captured: $($capTui1.Trim())"
}

# --- TUI Test 2: paste-buffer -p (bracketed paste) into visible pane ---
Write-Host "`n[TUI Test 2] paste-buffer -p into visible TUI pane" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION_TUI "clear" Enter
Start-Sleep -Seconds 1

& $PSMUX set-buffer -b tui2 'echo TUI_BRACKETED_PASTE_PROOF'
& $PSMUX paste-buffer -p -b tui2 -t $SESSION_TUI
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -t $SESSION_TUI Enter
Start-Sleep -Seconds 2

$capTui2 = & $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String
if ($capTui2 -match "TUI_BRACKETED_PASTE_PROOF") {
    Write-Pass "TUI: paste-buffer -p delivered content to visible pane"
} else {
    Write-Fail "TUI: paste-buffer -p did NOT deliver. Captured: $($capTui2.Trim())"
}

# --- TUI Test 3: split-window + paste-buffer to specific pane ---
Write-Host "`n[TUI Test 3] paste-buffer after split-window (multi-pane)" -ForegroundColor Yellow
& $PSMUX split-window -v -t $SESSION_TUI
Start-Sleep -Seconds 2

& $PSMUX send-keys -t $SESSION_TUI "clear" Enter
Start-Sleep -Seconds 1

& $PSMUX set-buffer -b tui3 'echo TUI_SPLIT_PASTE_PROOF'
& $PSMUX paste-buffer -b tui3 -t $SESSION_TUI
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -t $SESSION_TUI Enter
Start-Sleep -Seconds 2

$capTui3 = & $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String
if ($capTui3 -match "TUI_SPLIT_PASTE_PROOF") {
    Write-Pass "TUI: paste-buffer works in split pane"
} else {
    Write-Fail "TUI: paste-buffer in split pane failed. Captured: $($capTui3.Trim())"
}

# --- TUI Test 4: multiple paste-buffers in sequence ---
Write-Host "`n[TUI Test 4] sequential paste-buffer operations" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION_TUI "clear" Enter
Start-Sleep -Seconds 1

& $PSMUX set-buffer -b seq1 'echo SEQUENTIAL_A'
& $PSMUX paste-buffer -b seq1 -t $SESSION_TUI
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $SESSION_TUI Enter
Start-Sleep -Seconds 1

& $PSMUX set-buffer -b seq2 'echo SEQUENTIAL_B'
& $PSMUX paste-buffer -b seq2 -t $SESSION_TUI
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $SESSION_TUI Enter
Start-Sleep -Seconds 2

$capSeq = & $PSMUX capture-pane -t $SESSION_TUI -p 2>&1 | Out-String
$hasA = $capSeq -match "SEQUENTIAL_A"
$hasB = $capSeq -match "SEQUENTIAL_B"
if ($hasA -and $hasB) {
    Write-Pass "TUI: sequential paste-buffers both delivered"
} else {
    Write-Fail "TUI: sequential paste missing A=$hasA B=$hasB"
}

# Cleanup
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== TUI Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -eq 0) {
    Write-Host "`n  TUI VERIFICATION: paste-buffer works correctly in real visible psmux window" -ForegroundColor Green
}

exit $script:TestsFailed
