# Issue #266 — exact reproduction matching reporter's environment.
#
# The reporter's pane was running python and they saw window_name flip
# to "python". Our previous test used Start-Sleep (so active cmd stayed
# 'pwsh'/'shell') and didn't observe a flip. Now we run REAL python in
# the pane to trigger any process-based rename mechanism.
#
# ALSO: probe whether -c "$HOME" affects the bug (the reporter used it).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$VERSION = (& $PSMUX -V).Trim()
$PY = (Get-Command python -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"

function Write-Pass($m) { Write-Host "  [PASS] $m" -F Green }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -F Red }
function Write-Info($m) { Write-Host "  [INFO] $m" -F DarkCyan }

Write-Host "`n=== Issue #266 PYTHON-PROCESS REPRODUCTION ===" -F Cyan
Write-Host "  Build: $VERSION"
Write-Host "  Python at: $PY"
Write-Host "  Goal: see if python running in pane flips window_name to 'python'"
Write-Host ""

# === SCENARIO 1: matches reporter's exact command ===
$S1 = "issue266_repro1"
& $PSMUX kill-session -t $S1 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$S1.*" -Force -EA SilentlyContinue

Write-Host "[Scenario 1] Reporter's exact command (with -c HOME)" -F Yellow
Write-Info "psmux new-session -d -s $S1 -n my_explicit_name -c `"$env:USERPROFILE`""
& $PSMUX new-session -d -s $S1 -n my_explicit_name -c "$env:USERPROFILE" 2>&1 | Out-Null
Start-Sleep -Milliseconds 1500   # match reporter's `sleep 1.5`

$out1 = & $PSMUX list-windows -t $S1 -F "#{window_id} #{window_name} #{pane_current_command}" 2>&1 | Out-String
Write-Info "list-windows immediately after creation:`n  $($out1.Trim())"

# Then start python and wait
& $PSMUX send-keys -t $S1 "& '$PY'" Enter
Write-Info "Started python; waiting 5s for any rename to trigger..."
Start-Sleep -Seconds 5

$out1b = & $PSMUX list-windows -t $S1 -F "#{window_id} #{window_name} #{pane_current_command}" 2>&1 | Out-String
Write-Info "list-windows AFTER python started:`n  $($out1b.Trim())"

# Exit python
& $PSMUX send-keys -t $S1 "exit()" Enter
Start-Sleep -Seconds 2

$out1c = & $PSMUX list-windows -t $S1 -F "#{window_id} #{window_name} #{pane_current_command}" 2>&1 | Out-String
Write-Info "list-windows AFTER python exited:`n  $($out1c.Trim())"

# Read each cell separately for asserting
$nameNow = (& $PSMUX display-message -t "${S1}:0" -p '#{window_name}' 2>&1).Trim()
Write-Info "window_name now = '$nameNow'"

if ($nameNow -eq "my_explicit_name") {
    Write-Pass "S1: explicit name 'my_explicit_name' SURVIVED python session"
} else {
    Write-Fail "S1: BUG: window_name = '$nameNow' instead of 'my_explicit_name'"
}

& $PSMUX kill-session -t $S1 2>&1 | Out-Null

# === SCENARIO 2: explicit -n with renamed-to-python check WITHOUT -c flag ===
$S2 = "issue266_repro2"
& $PSMUX kill-session -t $S2 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$S2.*" -Force -EA SilentlyContinue

Write-Host "`n[Scenario 2] -n only (no -c flag)" -F Yellow
& $PSMUX new-session -d -s $S2 -n my_explicit_name 2>&1 | Out-Null
Start-Sleep -Milliseconds 1500
$out2 = & $PSMUX list-windows -t $S2 -F "#{window_id} #{window_name} #{pane_current_command}" 2>&1 | Out-String
Write-Info "After 1.5s: $($out2.Trim())"

& $PSMUX send-keys -t $S2 "& '$PY'" Enter
Start-Sleep -Seconds 5
$out2b = & $PSMUX list-windows -t $S2 -F "#{window_id} #{window_name} #{pane_current_command}" 2>&1 | Out-String
Write-Info "While python running: $($out2b.Trim())"

$nameNow2 = (& $PSMUX display-message -t "${S2}:0" -p '#{window_name}' 2>&1).Trim()
if ($nameNow2 -eq "my_explicit_name") {
    Write-Pass "S2: explicit name SURVIVED with python active"
} else {
    Write-Fail "S2: BUG: window_name = '$nameNow2'"
}

& $PSMUX kill-session -t $S2 2>&1 | Out-Null

# === SCENARIO 3: CONTROL — no -n, with python ===
$S3 = "issue266_repro3"
& $PSMUX kill-session -t $S3 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$S3.*" -Force -EA SilentlyContinue

Write-Host "`n[Scenario 3] CONTROL: NO -n flag, with python" -F Yellow
& $PSMUX new-session -d -s $S3 2>&1 | Out-Null
Start-Sleep -Milliseconds 1500
$out3 = & $PSMUX list-windows -t $S3 -F "#{window_id} #{window_name} #{pane_current_command}" 2>&1 | Out-String
Write-Info "After 1.5s (no python): $($out3.Trim())"

& $PSMUX send-keys -t $S3 "& '$PY'" Enter
Start-Sleep -Seconds 5
$out3b = & $PSMUX list-windows -t $S3 -F "#{window_id} #{window_name} #{pane_current_command}" 2>&1 | Out-String
Write-Info "After python started: $($out3b.Trim())"

$nameNow3 = (& $PSMUX display-message -t "${S3}:0" -p '#{window_name}' 2>&1).Trim()
$paneCmd3 = (& $PSMUX display-message -t "${S3}:0" -p '#{pane_current_command}' 2>&1).Trim()

if ($paneCmd3 -match 'python') {
    Write-Pass "S3 (control): pane_current_command correctly tracked python"
} else {
    Write-Info "S3 (control): pane_current_command = '$paneCmd3' (not 'python')"
}

if ($nameNow3 -match 'python|pwsh') {
    Write-Pass "S3 (control): automatic-rename DID change name to active cmd '$nameNow3'"
} else {
    Write-Info "S3 (control): name = '$nameNow3' (rename mechanism may not be re-triggering after creation)"
}

& $PSMUX kill-session -t $S3 2>&1 | Out-Null

Write-Host "`n============================================" -F Cyan
Write-Host "FINDING" -F Cyan
Write-Host "============================================" -F Cyan
Write-Host "  Compare these three scenarios to determine the bug nature:"
Write-Host "  - S1 (with -n + -c HOME + python): name was '$nameNow'"
Write-Host "  - S2 (with -n + python):           name was '$nameNow2'"
Write-Host "  - S3 (no -n + python — control):   name was '$nameNow3'"
