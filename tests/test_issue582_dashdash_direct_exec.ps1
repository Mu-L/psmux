# Issue #582: every pane-creating path except the server-boot `-- argv`
# case funneled the command through `pwsh.exe -NoLogo -Command "<joined>"`,
# so `new-window -t S -- cmd.exe /k ...` ran cmd.exe under a hidden pwsh
# wrapper (and #{pane_pid} reported the wrapper, not the command).
#
# tmux semantics (spawn.c): a multi-argument command is execvp'd DIRECTLY;
# only a single string routes through the shell. The fix preserves the
# `--` argv boundary from CLI to spawn: multi-token `--` argv is exec'd
# directly for new-window / split-window / respawn-pane, single tokens and
# string commands keep the historical shell route.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "t582e2e"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$env:PSMUX_NO_WARM = "1"
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $SESSION -- cmd.exe /k echo hello582
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }

function Get-PaneTree($panePid) {
    # Returns "direct" if the pane pid is cmd.exe itself, or "wrapped:<name>"
    # if it is a shell wrapper with the command as a child.
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$panePid" -ErrorAction SilentlyContinue
    if (-not $p) { return "missing" }
    if ($p.Name -eq 'cmd.exe') { return "direct" }
    $kids = Get-CimInstance Win32_Process | Where-Object { [int]$_.ParentProcessId -eq [int]$panePid }
    $cmdkid = $kids | Where-Object { $_.Name -eq 'cmd.exe' } | Select-Object -First 1
    if ($cmdkid) { return "wrapped:$($p.Name)" }
    return "other:$($p.Name)"
}

Write-Host "`n=== Issue #582: -- argv direct exec (tmux execvp parity) ===" -ForegroundColor Cyan

# --- Arm 1: new-session -- argv spawns directly (control, worked before) ---
Write-Host "[Arm 1] new-session -- argv is direct" -ForegroundColor Yellow
$pid0 = (& $PSMUX display-message -t "${SESSION}:0.0" -p '#{pane_pid}' 2>&1 | Out-String).Trim()
$tree0 = Get-PaneTree $pid0
if ($tree0 -eq 'direct') { Write-Pass "session root pane is cmd.exe itself (pid $pid0)" }
else { Write-Fail "session root pane tree: $tree0 (pid=$pid0)" }

# --- Arm 2: new-window -- argv spawns directly (the reported bug) ---
Write-Host "[Arm 2] new-window -- argv is direct" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION -- cmd.exe /k echo hello582b
Start-Sleep -Seconds 3
$pid1 = (& $PSMUX display-message -t "${SESSION}:1.0" -p '#{pane_pid}' 2>&1 | Out-String).Trim()
$tree1 = Get-PaneTree $pid1
if ($tree1 -eq 'direct') { Write-Pass "new-window -- pane is cmd.exe itself, no pwsh wrapper (pid $pid1)" }
else { Write-Fail "new-window -- pane tree: $tree1 (pid=$pid1)" }
$cap = & $PSMUX capture-pane -t "${SESSION}:1" -p 2>&1 | Out-String
if ($cap -match 'hello582b') { Write-Pass "argv arguments survived (echo output present)" }
else { Write-Fail "command arguments lost: [$($cap.Trim())]" }

# --- Arm 3: split-window -- argv spawns directly ---
Write-Host "[Arm 3] split-window -- argv is direct" -ForegroundColor Yellow
& $PSMUX split-window -d -t "${SESSION}:0" -- cmd.exe /k echo hello582c
Start-Sleep -Seconds 3
$pid01 = (& $PSMUX display-message -t "${SESSION}:0.1" -p '#{pane_pid}' 2>&1 | Out-String).Trim()
$tree01 = Get-PaneTree $pid01
if ($tree01 -eq 'direct') { Write-Pass "split-window -- pane is cmd.exe itself (pid $pid01)" }
else { Write-Fail "split-window -- pane tree: $tree01 (pid=$pid01)" }

# --- Arm 4: single-string command keeps shell semantics (tmux parity) ---
Write-Host "[Arm 4] string form still routes through the shell" -ForegroundColor Yellow
& $PSMUX new-window -t $SESSION "cmd.exe /k echo hello582d"
Start-Sleep -Seconds 3
$pid2 = (& $PSMUX display-message -t "${SESSION}:2.0" -p '#{pane_pid}' 2>&1 | Out-String).Trim()
$tree2 = Get-PaneTree $pid2
if ($tree2 -match '^wrapped:(pwsh|powershell)') { Write-Pass "string command runs under the shell ($tree2), tmux string semantics" }
else { Write-Fail "string form tree unexpected: $tree2 (pid=$pid2)" }
$cap = & $PSMUX capture-pane -t "${SESSION}:2" -p 2>&1 | Out-String
if ($cap -match 'hello582d') { Write-Pass "string form output intact" }
else { Write-Fail "string form output missing: [$($cap.Trim())]" }

# --- Arm 5: teammate idioms unaffected ---
Write-Host "[Arm 5] -- cat placeholder and quoted respawn still work" -ForegroundColor Yellow
$paneId = (& $PSMUX new-window -t $SESSION -P -F '#{pane_id}' -- cat 2>&1 | Out-String).Trim()
Start-Sleep -Seconds 3
$dead = (& $PSMUX display-message -t $paneId -p '#{pane_dead}' 2>&1 | Out-String).Trim()
if ($dead -eq '0') { Write-Pass "new-window -- cat still blocks silently" }
else { Write-Fail "cat placeholder died (dead=$dead)" }
& $PSMUX respawn-pane -k -t $paneId -- "pwsh -NoProfile -Command Write-Output RESPAWN582; Start-Sleep 300" 2>&1 | Out-Null
Start-Sleep -Seconds 3
$cap = & $PSMUX capture-pane -t $paneId -p 2>&1 | Out-String
if ($cap -match 'RESPAWN582') { Write-Pass "quoted-string respawn (teammate idiom) intact" }
else { Write-Fail "quoted respawn broken: [$($cap.Trim())]" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
