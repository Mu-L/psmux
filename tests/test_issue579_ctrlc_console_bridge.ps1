# Issue #579: Ctrl+C exits WSL instead of sending SIGINT inside psmux.
#
# Root-cause class (proven by mechanism emulation + measurement):
#   send_ctrl_c_event guarded its GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0)
#   broadcast with a classification of ONE deepest foreground leaf resolved by
#   a highest-PID-child walk.  The broadcast hits EVERY process on the pane
#   console.  A broadcast into a console holding a Cygwin/MSYS shell (Git
#   Bash, MSYS2) is lethal to wsl.exe: the shell's runtime hard-kills the
#   native children its own bookkeeping tracks (issue #491's mechanism), and
#   that bookkeeping is invisible to Windows PPID walks (MSYS fork stubs exit,
#   severing the PPID chain - measured: intact seconds earlier, severed by
#   Ctrl+C time).  Windows PIDs are also not monotonic, so the leaf walk can
#   descend the wrong sibling subtree and classify a shell while wsl.exe is
#   live, which fires the lethal broadcast.
#
# Fix: after AttachConsole, enumerate the console's REAL membership via
# GetConsoleProcessList and skip the broadcast when any member is a VT bridge
# (wsl/ssh) or a Cygwin/MSYS unix shell.  The raw 0x03 the call site writes is
# all tmux ever delivers, and a Cygwin shell's own pty machinery turns it into
# SIGINT for its foreground work, natives included.
#
# The arms below assert the VALIDATED behavior matrix on the fixed build.
# Deliberately NOT asserted: a backgrounded `wsl.exe -e sleep &` job dying to
# Ctrl+C in a Git Bash pane - that is native MSYS behavior, reproduced
# identically in plain conhost Git Bash with no psmux involved.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$bash = "C:\Program Files\Git\bin\bash.exe"
& wsl.exe -e true 2>$null
$hasWsl = ($LASTEXITCODE -eq 0)
if (-not (Test-Path $bash)) { Write-Host "SKIP: Git Bash not found" -ForegroundColor Yellow; exit 0 }

$INJ = "$env:TEMP\psmux_injector.exe"
if (-not (Test-Path $INJ)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    $src = Join-Path $PSScriptRoot "injector.cs"
    & $csc /nologo /optimize /out:$INJ $src 2>&1 | Out-Null
}
if (-not (Test-Path $INJ)) { Write-Host "SKIP: injector compile failed" -ForegroundColor Yellow; exit 0 }

$env:PSMUX_NO_WARM = "1"

function New-Pane([string]$S, [string[]]$shellArgs) {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $p = Start-Process -FilePath $PSMUX -ArgumentList (@("new-session","-s",$S) + $shellArgs) -PassThru
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $cap = & $PSMUX capture-pane -t $S -p 2>&1 | Out-String
        if ($cap -match '\$|>') { break }
    }
    return $p
}
function Close-Pane([string]$S, $p) {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    try { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } catch {}
}
function Stop-MarkerPings {
    Get-CimInstance Win32_Process -Filter "Name='ping.exe'" |
        Where-Object { $_.CommandLine -match '127\.0\.0\.1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
}

Write-Host "`n=== Issue #579: console-scoped Ctrl+C bridge guard ===" -ForegroundColor Cyan

# --- Arm 1: git-bash pane + native cooked app; ^C must interrupt it while the
# broadcast is skipped (Cygwin shell on console). ---
Write-Host "[Arm 1] git-bash pane, ping -t, Ctrl+C interrupts" -ForegroundColor Yellow
$p1 = New-Pane "t579a1" @($bash,"-i")
& $PSMUX send-keys -t "t579a1" "ping -t 127.0.0.1" Enter
Start-Sleep -Seconds 4
$cap = & $PSMUX capture-pane -t "t579a1" -p 2>&1 | Out-String
if ($cap -match "Reply from 127") {
    & $INJ $p1.Id "^c"
    Start-Sleep -Seconds 2
    & $PSMUX send-keys -t "t579a1" "echo BACK_ALIVE" Enter
    Start-Sleep -Seconds 2
    $cap2 = & $PSMUX capture-pane -t "t579a1" -p 2>&1 | Out-String
    $pings = @(Get-CimInstance Win32_Process -Filter "Name='ping.exe'" | Where-Object { $_.CommandLine -match '127\.0\.0\.1' }).Count
    if ($cap2 -match "BACK_ALIVE" -and $pings -eq 0) { Write-Pass "ping interrupted, bash prompt live" }
    else { Write-Fail "ping interrupt failed (pings left=$pings)" }
} else { Write-Fail "ping never started in git-bash pane" }
Close-Pane "t579a1" $p1
Stop-MarkerPings

# --- Arm 2: git-bash pane + foreground interactive WSL; ^C must reach the
# guest as SIGINT and the WSL session must survive. ---
if ($hasWsl) {
    Write-Host "[Arm 2] git-bash pane, foreground wsl, WSL survives Ctrl+C" -ForegroundColor Yellow
    $p2 = New-Pane "t579a2" @($bash,"-i")
    & $PSMUX send-keys -t "t579a2" "wsl.exe" Enter
    Start-Sleep -Seconds 6
    & $PSMUX send-keys -t "t579a2" "sleep 100" Enter
    Start-Sleep -Seconds 2
    $before = @(Get-Process wsl -EA SilentlyContinue).Count
    & $INJ $p2.Id "^c"
    Start-Sleep -Seconds 2
    $after = @(Get-Process wsl -EA SilentlyContinue).Count
    $cap = & $PSMUX capture-pane -t "t579a2" -p 2>&1 | Out-String
    if ($before -gt 0 -and $after -ge $before -and $cap -match '\^C') {
        Write-Pass "fg WSL survived, ^C forwarded ($before -> $after)"
    } elseif ($before -eq 0) {
        Write-Host "  [SKIP] wsl did not start inside the pane" -ForegroundColor Yellow
    } else {
        Write-Fail "fg WSL arm failed ($before -> $after)"
    }
    & $PSMUX send-keys -t "t579a2" "exit" Enter
    Start-Sleep -Seconds 1
    Close-Pane "t579a2" $p2
} else {
    Write-Host "[Arm 2] SKIP: no working WSL distro" -ForegroundColor Yellow
}

# --- Arm 3: pwsh pane + cooked app; the pre-existing interrupt path must be
# untouched (no unix shell on the pane console -> guard does not engage). ---
Write-Host "[Arm 3] pwsh pane, ping -t, Ctrl+C interrupts (path unchanged)" -ForegroundColor Yellow
$p3 = New-Pane "t579a3" @()
& $PSMUX send-keys -t "t579a3" "ping -t 127.0.0.1" Enter
Start-Sleep -Seconds 4
$cap = & $PSMUX capture-pane -t "t579a3" -p 2>&1 | Out-String
if ($cap -match "Reply from 127") {
    & $INJ $p3.Id "^c"
    Start-Sleep -Seconds 2
    & $PSMUX send-keys -t "t579a3" "echo PWSH_BACK" Enter
    Start-Sleep -Seconds 2
    $cap2 = & $PSMUX capture-pane -t "t579a3" -p 2>&1 | Out-String
    $pings = @(Get-CimInstance Win32_Process -Filter "Name='ping.exe'" | Where-Object { $_.CommandLine -match '127\.0\.0\.1' }).Count
    if ($cap2 -match "PWSH_BACK" -and $pings -eq 0) { Write-Pass "pwsh ping interrupted, prompt live" }
    else { Write-Fail "pwsh ping interrupt failed (pings left=$pings)" }
} else { Write-Fail "ping never started in pwsh pane" }
Close-Pane "t579a3" $p3
Stop-MarkerPings

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
