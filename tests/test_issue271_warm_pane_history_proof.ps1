# Issue #271: Win32 TUI proof — launch a real visible psmux window
# (config-driven), generate output through the warm-pane path, and
# verify scrollback retention via CLI dump.  This exercises the
# server/connection.rs TCP dispatch path against a live TUI.

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

function Wait-OutputComplete {
    param([string]$Target, [string]$Marker, [int]$TimeoutMs = 60000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $cap = & $PSMUX capture-pane -t $Target -p 2>&1 | Out-String
        if ($cap -match $Marker) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

Write-Host "`n=== Issue #271 TUI proof: visible window, real warm pane ===" -ForegroundColor Cyan

# Build config that raises history-limit far above the default 2000.
$configFile = "$env:TEMP\psmux_test_271_proof.conf"
@"
set -g history-limit 100000
"@ | Set-Content -Path $configFile -Encoding UTF8

# Cleanup any residual server first
& $PSMUX kill-server 2>&1 | Out-Null
Start-Sleep -Seconds 1
Remove-Item "$psmuxDir\*.port","$psmuxDir\*.key","$psmuxDir\*.sess" -Force -EA SilentlyContinue

# Launch a REAL VISIBLE psmux window with the config applied.  The TUI
# is driven via psmux CLI commands — these go through the same TCP
# dispatch path the user's keybindings/commands use.
$SESSION = "issue271_proof"
$env:PSMUX_CONFIG_FILE = $configFile
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
$env:PSMUX_CONFIG_FILE = $null
Start-Sleep -Seconds 5

if (-not (Wait-PanePrompt -Target $SESSION -TimeoutMs 20000)) {
    Write-Fail "TUI session did not present a shell prompt"
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    exit 1
}
Write-Pass "TUI session ready (shell prompt visible)"

# Verify the option propagated into the TUI session
$hl = (& $PSMUX show-options -g -v history-limit -t $SESSION 2>&1).Trim()
Write-Info "show-options -g -v history-limit = $hl"
if ($hl -eq "100000") { Write-Pass "TUI: option visible to server (history-limit=100000)" }
else { Write-Fail "TUI: option not propagated, got $hl" }

# Drive output through send-keys (via TCP dispatch) — exact path a real
# user takes.  Generate well over the old 2000-line default.
Write-Info "Generating 5000 lines through send-keys / TCP dispatch..."
& $PSMUX send-keys -t $SESSION '1..5000 | ForEach-Object { "line $_" }' Enter 2>&1 | Out-Null

if (-not (Wait-OutputComplete -Target $SESSION -Marker "line 4990" -TimeoutMs 90000)) {
    Write-Fail "TUI: output never reached line 4990 within 90s"
} else {
    Write-Pass "TUI: 5000 lines emitted"
    Start-Sleep -Seconds 2

    # Capture deep scrollback from the visible session.  If the warm
    # pane's scrollback cap was reconciled with history-limit=100000,
    # all 5000 lines must be retained.  If the bug had returned, only
    # the last ~2000 would be present.
    $deep = & $PSMUX capture-pane -t $SESSION -S -200000 -p 2>&1 | Out-String
    $lineMatches = [regex]::Matches($deep, '(?m)^line (\d+)\b')
    $count = $lineMatches.Count
    if ($count -ge 4900) {
        Write-Pass "TUI: $count of 5000 lines retained in real visible session"
    } elseif ($count -lt 2500) {
        Write-Fail "TUI: only $count retained — REGRESSION of #271"
    } else {
        Write-Fail "TUI: unexpected retention count $count"
    }

    # history_size formatter in a live TUI session
    $hs = (& $PSMUX display-message -t $SESSION -p '#{history_size}' 2>&1).Trim()
    Write-Info "TUI: display-message #{history_size} = $hs"
    if ([int]$hs -gt 0 -and [int]$hs -lt 100000) {
        Write-Pass "TUI: #{history_size}=$hs reflects actual fill, not cap"
    } else {
        Write-Fail "TUI: #{history_size}=$hs looks suspicious (should be ~5000-ish, < 100000)"
    }
}

# Cleanup
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $PSMUX kill-server 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item $configFile -Force -EA SilentlyContinue
Remove-Item "$psmuxDir\*.port","$psmuxDir\*.key","$psmuxDir\*.sess" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
