# Issue #271 follow-up: verify runtime config changes propagate to the
# warm pane.  Two scenarios:
#   A) `set-environment PATH` → warm-pane shell sees new PATH
#      (existing #137 mechanism, kill+respawn)
#   B) `set-option history-limit` → warm pane's parser cap is updated
#      live (added in this fix)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Wait-PanePrompt {
    param([string]$Target, [int]$TimeoutMs = 15000, [string]$Pattern = "PS [A-Z]:\\")
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
            if ($cap -match $Pattern) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Wait-Output {
    param([string]$Target, [string]$Marker, [int]$TimeoutMs = 30000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
        if ($cap -match $Marker) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Cleanup
& $PSMUX kill-server 2>&1 | Out-Null
Start-Sleep -Seconds 1
Remove-Item "$psmuxDir\*.port","$psmuxDir\*.key","$psmuxDir\*.sess" -Force -EA SilentlyContinue

Write-Host "`n=== Scenario A: set-environment propagates to warm pane (existing #137 mechanism) ===" -ForegroundColor Cyan

$SESSION_A = "iss271_envprop_a"
& $PSMUX new-session -d -s $SESSION_A 2>&1 | Out-Null
Start-Sleep -Seconds 4

if (-not (Wait-PanePrompt -Target $SESSION_A)) {
    Write-Fail "Session A: prompt never appeared"
} else {
    Write-Pass "Session A: shell ready"
    $token = "ISSUE271_TOKEN_$(Get-Random)"

    # Set env var BEFORE creating any new window — the existing warm pane
    # at this point should be killed+respawned with the new env.
    & $PSMUX set-environment -g "ISSUE271_VAR" $token 2>&1 | Out-Null
    Start-Sleep -Seconds 3  # let respawn complete

    # Now open a new window — this consumes the (respawned) warm pane.
    & $PSMUX new-window -t $SESSION_A 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    $newWin = "${SESSION_A}:1"
    if (Wait-PanePrompt -Target $newWin) {
        & $PSMUX send-keys -t $newWin '$env:ISSUE271_VAR' Enter 2>&1 | Out-Null
        if (Wait-Output -Target $newWin -Marker $token -TimeoutMs 10000) {
            Write-Pass "set-environment propagated through warm pane (token visible in new pane)"
        } else {
            $cap = & $PSMUX capture-pane -t $newWin -p 2>&1 | Out-String
            Write-Fail "Token not found in new pane. Capture tail:`n$($cap.Substring([Math]::Max(0,$cap.Length-300)))"
        }
    }
}
& $PSMUX kill-session -t $SESSION_A 2>&1 | Out-Null
& $PSMUX kill-server 2>&1 | Out-Null
Start-Sleep -Seconds 1
Remove-Item "$psmuxDir\*.port","$psmuxDir\*.key","$psmuxDir\*.sess" -Force -EA SilentlyContinue

Write-Host "`n=== Scenario B: set-option history-limit propagates to warm pane (new in #271) ===" -ForegroundColor Cyan

$SESSION_B = "iss271_optprop_b"
& $PSMUX new-session -d -s $SESSION_B 2>&1 | Out-Null
Start-Sleep -Seconds 4

if (-not (Wait-PanePrompt -Target $SESSION_B)) {
    Write-Fail "Session B: prompt never appeared"
} else {
    Write-Pass "Session B: shell ready"

    # Default is 2000.  Raise it via set-option AFTER the warm pane was
    # already pre-spawned with the default cap.
    & $PSMUX set-option -g history-limit 80000 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $hl = (& $PSMUX show-options -g -v history-limit 2>&1).Trim()
    if ($hl -eq "80000") { Write-Pass "set-option recorded: history-limit=80000" }
    else { Write-Fail "history-limit expected 80000, got $hl" }

    # Now open a new window.  With the runtime propagation fix, the warm
    # pane's parser already knows about the new cap, so the consume path
    # finds it in sync.  Without it, my consume-time reconciliation still
    # catches it — both layers are exercised here.
    & $PSMUX new-window -t $SESSION_B 2>&1 | Out-Null
    Start-Sleep -Seconds 4

    $newWin = "${SESSION_B}:1"
    if (Wait-PanePrompt -Target $newWin) {
        Write-Info "Generating 5000 lines in new window..."
        & $PSMUX send-keys -t $newWin '1..5000 | ForEach-Object { "line $_" }' Enter 2>&1 | Out-Null
        if (Wait-Output -Target $newWin -Marker "line 4990" -TimeoutMs 60000) {
            Start-Sleep -Seconds 2
            $deep = & $PSMUX capture-pane -t $newWin -S -200000 -p 2>&1 | Out-String
            $count = ([regex]::Matches($deep, '(?m)^line (\d+)\b')).Count
            Write-Info "Retained $count of 5000 lines"
            if ($count -ge 4900) {
                Write-Pass "Runtime set-option history-limit honoured by warm-pane-consumed window"
            } elseif ($count -lt 2500) {
                Write-Fail "Runtime set-option NOT honoured — only $count retained"
            } else {
                Write-Fail "Unexpected count $count"
            }
        } else {
            Write-Fail "Output never reached line 4990"
        }
    }
}
& $PSMUX kill-session -t $SESSION_B 2>&1 | Out-Null
& $PSMUX kill-server 2>&1 | Out-Null
Remove-Item "$psmuxDir\*.port","$psmuxDir\*.key","$psmuxDir\*.sess" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
