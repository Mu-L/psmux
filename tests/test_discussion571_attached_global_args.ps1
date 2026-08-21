# Discussion #571: tmux accepts attached short-option arguments for global
# options (`tmux -Lsockname`), the form libtmux emits.  psmux silently
# DROPPED the token: `-Ld571 new-session` exited 0 but created the session
# in the DEFAULT namespace (reproduced on 3.3.8 before the fix).
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$NS = "d571ns"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Cleanup {
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    & $PSMUX kill-session -t d571stray 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
}

Cleanup
Write-Host "`n=== Discussion #571: attached global short options ===" -ForegroundColor Cyan

# Test 1: -L<name> attached creates the session in the RIGHT namespace
Write-Host "[Test 1] -L$NS (attached) lands in namespace $NS" -ForegroundColor Yellow
& $PSMUX "-L$NS" new-session -d -s d571a 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX -L $NS has-session -t d571a 2>$null
$inNs = ($LASTEXITCODE -eq 0)
& $PSMUX has-session -t d571a 2>$null
$inDefault = ($LASTEXITCODE -eq 0)
if ($inNs -and -not $inDefault) { Write-Pass "session in $NS namespace, not in default" }
else { Write-Fail "inNs=$inNs inDefault=$inDefault (silent -L drop = old bug)" }

# Test 2: attached and detached forms address the SAME server
Write-Host "[Test 2] attached -L talks to the same server as detached" -ForegroundColor Yellow
$name = (& $PSMUX "-L$NS" display-message -t d571a -p '#{session_name}' 2>&1 | Out-String).Trim()
if ($name -eq "d571a") { Write-Pass "attached -L routed the query ($name)" }
else { Write-Fail "expected d571a, got '$name'" }

# Test 3: attached global -t routes commands
Write-Host "[Test 3] -td571a (attached) before the subcommand routes" -ForegroundColor Yellow
$name = (& $PSMUX "-L$NS" "-td571a" display-message -p '#{session_name}' 2>&1 | Out-String).Trim()
if ($name -eq "d571a") { Write-Pass "attached -t routed ($name)" }
else { Write-Fail "expected d571a, got '$name'" }

# Test 4: attached -f applies the config file
Write-Host "[Test 4] -f<path> (attached) applies config" -ForegroundColor Yellow
$conf = "$env:TEMP\d571.conf"
"set -g escape-time 4321" | Set-Content -Path $conf -Encoding UTF8
& $PSMUX "-L$NS" "-f$conf" new-session -d -s d571f 2>&1 | Out-Null
Start-Sleep -Seconds 3
$et = (& $PSMUX -L $NS show-options -g -v escape-time -t d571f 2>&1 | Out-String).Trim()
if ($et -eq "4321") { Write-Pass "escape-time=4321 from attached -f config" }
else { Write-Fail "expected 4321, got '$et'" }

# Test 5: post-subcommand -L is untouched (select-pane -L / resize-pane -L)
Write-Host "[Test 5] command-level -L still works after the rewrite" -ForegroundColor Yellow
& $PSMUX -L $NS split-window -h -t d571a 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$before = (& $PSMUX -L $NS display-message -t d571a -p '#{pane_index}' 2>&1 | Out-String).Trim()
& $PSMUX -L $NS select-pane -L -t d571a 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$after = (& $PSMUX -L $NS display-message -t d571a -p '#{pane_index}' 2>&1 | Out-String).Trim()
if ($before -ne $after) { Write-Pass "select-pane -L moved focus ($before -> $after)" }
else { Write-Fail "select-pane -L did nothing (pane stayed $after)" }

# Test 6: the libtmux invocation shape end-to-end (attach-style with -L glued)
Write-Host "[Test 6] libtmux shape: psmux -L<name> <cmd> -t <target>" -ForegroundColor Yellow
& $PSMUX "-L$NS" rename-window -t d571a "d571win" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$wn = (& $PSMUX -L $NS display-message -t d571a -p '#{window_name}' 2>&1 | Out-String).Trim()
if ($wn -eq "d571win") { Write-Pass "rename through attached -L applied ($wn)" }
else { Write-Fail "expected d571win, got '$wn'" }

Cleanup
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
