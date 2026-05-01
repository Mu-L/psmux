# Issue #266: TUI Visual Proof — automatic-rename vs explicit -n NAME
# Launches a REAL visible psmux window, drives state via CLI, verifies name sticks

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "i266_tui_proof"
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
Write-Host "`n=== Issue #266 TUI Visual Proof ===" -ForegroundColor Cyan
Write-Host ("=" * 60)

# Launch a REAL visible psmux window with -n flag
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION,"-n","tui_named_window" -PassThru
Start-Sleep -Seconds 5

# Verify session exists
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "TUI session creation failed"
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    exit 1
}

# --- TUI Check 1: Name is set correctly in attached TUI session ---
Write-Host "[TUI 1] Window name in attached TUI session" -ForegroundColor Yellow
$name = (& $PSMUX display-message -t $SESSION -p '#{window_name}' 2>&1).Trim()
if ($name -eq "tui_named_window") { Write-Pass "TUI: window name is 'tui_named_window'" }
else { Write-Fail "TUI: expected 'tui_named_window', got '$name'" }

# --- TUI Check 2: Drive activity via send-keys, name persists ---
Write-Host "[TUI 2] Name persists after send-keys activity in TUI" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "echo tui_activity_test" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX send-keys -t $SESSION "dir" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3
$name = (& $PSMUX display-message -t $SESSION -p '#{window_name}' 2>&1).Trim()
if ($name -eq "tui_named_window") { Write-Pass "TUI: name persists after activity: '$name'" }
else { Write-Fail "TUI: name changed after activity to '$name'" }

# --- TUI Check 3: Split window and verify name sticks ---
Write-Host "[TUI 3] Name persists after split-window in TUI" -ForegroundColor Yellow
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 2
$name = (& $PSMUX display-message -t $SESSION -p '#{window_name}' 2>&1).Trim()
$panes = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1).Trim()
if ($name -eq "tui_named_window" -and $panes -eq "2") {
    Write-Pass "TUI: name='$name', panes=$panes after split"
} else {
    Write-Fail "TUI: name='$name' panes=$panes (expected tui_named_window, 2)"
}

# --- TUI Check 4: new-window -n in TUI, both names persist ---
Write-Host "[TUI 4] new-window -n in TUI, verify both names" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION -n "tui_second" 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX send-keys -t "$SESSION`:0" "echo w0" Enter 2>&1 | Out-Null
& $PSMUX send-keys -t "$SESSION`:1" "echo w1" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 5

$allNames = (& $PSMUX list-windows -t $SESSION -F '#{window_index}:#{window_name}' 2>&1 | Out-String).Trim()
Write-Host "    All windows: [$allNames]" -ForegroundColor DarkGray
$has1 = $allNames -match "tui_named_window"
$has2 = $allNames -match "tui_second"
if ($has1 -and $has2) { Write-Pass "TUI: both explicit names preserved in attached TUI" }
else { Write-Fail "TUI: names changed: $allNames" }

# --- Cleanup ---
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Start-Sleep -Seconds 1
Cleanup

Write-Host "`n=== TUI Proof Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
