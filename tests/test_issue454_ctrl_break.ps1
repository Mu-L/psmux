# Issue #454: "Ctrl+Break kills session"
#
# Reported: pressing Ctrl+Break to kill a non-responsive program detaches/kills
# the psmux session (the attached window vanishes) while the program keeps
# running, exactly the opposite of Windows Terminal where Ctrl+Break interrupts
# the program and you stay in your shell.
#
# Root cause: the attached CLIENT installed NO console control handler. Windows
# ALWAYS delivers Ctrl+Break as a CTRL_BREAK_EVENT console signal (it can never
# arrive as a keystroke, even in raw mode), so the crossterm key loop never sees
# it and the OS default handler terminated the client. Secondary: relaying a real
# CTRL_BREAK_EVENT to a ConPTY pane child does not work (ConPTY never relays it)
# and broadcasting it to process group 0 only kills the server that hosts the
# pane. The reliable interrupt to a ConPTY child is the Ctrl+C path.
#
# Fix:
#   1. Client installs a console control handler that survives Ctrl+Break /
#      Ctrl+C and flags the main loop to forward "send-key C-Break".
#   2. The server's send-key "C-Break" delivers the reliable Ctrl+C interrupt
#      (raw 0x03 + CTRL_C_EVENT) to the pane's foreground process.
#   3. The server's console handler survives a stray Ctrl+Break so a relayed
#      signal can never tear the server (and every session) down.
#
# Verification cannot use send-keys/WriteConsoleInput because Ctrl+Break is a
# SIGNAL, not a keystroke. This test compiles ctrl_break_sender.cs which raises a
# genuine CTRL_BREAK_EVENT on the client's console, the true real-world path.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

# --- Compile the Ctrl+Break signal sender -----------------------------------
$breakExe = "$env:TEMP\psmux_ctrl_break_sender.exe"
$src = Join-Path $PSScriptRoot "ctrl_break_sender.cs"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
}
& $csc /nologo /optimize /out:$breakExe $src 2>&1 | Out-Null
if (-not (Test-Path $breakExe)) { Write-Host "Cannot compile ctrl_break_sender.cs" -ForegroundColor Red; exit 1 }

function New-Sess($s) {
    & $PSMUX kill-session -t $s 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$s.*" -Force -EA SilentlyContinue
    $p = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$s -PassThru
    Start-Sleep -Seconds 5
    return $p
}
function Alive($s) { & $PSMUX has-session -t $s 2>$null; return ($LASTEXITCODE -eq 0) }

Write-Host "`n=== Issue #454: Ctrl+Break must interrupt the program, not kill the session ===" -ForegroundColor Cyan

# ── TEST 1: idle shell — client + session + shell all survive Ctrl+Break ──────
Write-Host "`n[Test 1] Idle shell survives Ctrl+Break (client, session, shell)" -ForegroundColor Yellow
$s1 = "iss454_idle"
$p1 = New-Sess $s1
& $PSMUX send-keys -t $s1 "echo IDLE_READY" Enter
Start-Sleep -Seconds 2
& $breakExe $p1.Id break
Start-Sleep -Seconds 2
$p1.Refresh()
if (-not $p1.HasExited) { Write-Pass "client still attached after Ctrl+Break (was killed before fix)" }
else { Write-Fail "client process exited on Ctrl+Break (bug)" }
if (Alive $s1) { Write-Pass "session still alive after Ctrl+Break" }
else { Write-Fail "session died on Ctrl+Break" }
& $PSMUX send-keys -t $s1 "echo SHELL_ALIVE_1" Enter
Start-Sleep -Seconds 2
$cap1 = & $PSMUX capture-pane -t $s1 -p 2>&1 | Out-String
if ($cap1 -match "SHELL_ALIVE_1") { Write-Pass "shell still executes commands after Ctrl+Break" }
else { Write-Fail "shell unresponsive after Ctrl+Break" }
& $PSMUX kill-session -t $s1 2>&1 | Out-Null
try { if (-not $p1.HasExited) { Stop-Process -Id $p1.Id -Force -EA SilentlyContinue } } catch {}
Start-Sleep -Milliseconds 500

# ── TEST 2: hung child program — killed by Ctrl+Break, shell returns to prompt ─
Write-Host "`n[Test 2] Ctrl+Break kills a hung child program and returns to prompt" -ForegroundColor Yellow
$s2 = "iss454_child"
# Baseline of any pre-existing ping.exe so we only track the ones WE launch.
$pingBaseline = @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Select-Object -Expand ProcessId)
$p2 = New-Sess $s2
& $PSMUX send-keys -t $s2 "ping -t 127.0.0.1" Enter
Start-Sleep -Seconds 3
$pingPids = @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Select-Object -Expand ProcessId |
    Where-Object { $_ -notin $pingBaseline })
$cap2a = & $PSMUX capture-pane -t $s2 -p 2>&1 | Out-String
if ($cap2a -match "Pinging|Reply from|bytes of data") { Write-Pass "child program (ping) is running in the pane" }
else { Write-Fail "child program did not start" }

& $breakExe $p2.Id break
# Poll up to ~5s for the child to be gone (interrupt delivery is async).
$pingStillUp = $pingPids
for ($i = 0; $i -lt 10; $i++) {
    Start-Sleep -Milliseconds 500
    $pingStillUp = @(Get-Process -Id $pingPids -EA SilentlyContinue)
    if ($pingStillUp.Count -eq 0) { break }
}
$p2.Refresh()
if (-not $p2.HasExited) { Write-Pass "client survived Ctrl+Break with a running child" }
else { Write-Fail "client exited on Ctrl+Break" }
if (Alive $s2) { Write-Pass "session survived Ctrl+Break with a running child" }
else { Write-Fail "session died on Ctrl+Break" }
if ($pingStillUp.Count -eq 0) { Write-Pass "hung child program was interrupted/killed by Ctrl+Break" }
else { Write-Fail "child program still running after Ctrl+Break ($($pingStillUp.Count) left)" }
& $PSMUX send-keys -t $s2 "echo SHELL_BACK_2" Enter
Start-Sleep -Seconds 2
$cap2b = & $PSMUX capture-pane -t $s2 -p 2>&1 | Out-String
if ($cap2b -match "SHELL_BACK_2") { Write-Pass "shell returned to prompt after killing the program" }
else { Write-Fail "shell did not return to prompt" }
& $PSMUX kill-session -t $s2 2>&1 | Out-Null
try { if (-not $p2.HasExited) { Stop-Process -Id $p2.Id -Force -EA SilentlyContinue } } catch {}
Get-Process -Id $pingPids -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 500

# ── TEST 3: server survives a direct Ctrl+Break (regression guard) ────────────
Write-Host "`n[Test 3] Server survives a direct Ctrl+Break signal" -ForegroundColor Yellow
$s3 = "iss454_srv"
$p3 = New-Sess $s3
$serverPid = $null
for ($i = 0; $i -lt 20; $i++) {
    if (Test-Path "$psmuxDir\$s3.pid") {
        $serverPid = (Get-Content "$psmuxDir\$s3.pid" -Raw).Trim()
        if ($serverPid -match '^\d+$') { break }
    }
    Start-Sleep -Milliseconds 250
}
if (-not ($serverPid -match '^\d+$')) { Write-Fail "could not read server pid"; $serverPid = "0" }
& $breakExe $serverPid break
Start-Sleep -Seconds 2
if (Get-Process -Id $serverPid -EA SilentlyContinue) { Write-Pass "server process survived a direct Ctrl+Break" }
else { Write-Fail "server process died on direct Ctrl+Break" }
if (Alive $s3) { Write-Pass "session still reachable after server-directed Ctrl+Break" }
else { Write-Fail "session unreachable after server-directed Ctrl+Break" }
& $PSMUX kill-session -t $s3 2>&1 | Out-Null
try { if (-not $p3.HasExited) { Stop-Process -Id $p3.Id -Force -EA SilentlyContinue } } catch {}
Start-Sleep -Milliseconds 500

# ── TEST 4: Win32 TUI visual verification (CLI-driven) ────────────────────────
Write-Host "`n[Test 4] Win32 TUI: session remains functional through Ctrl+Break" -ForegroundColor Yellow
$s4 = "iss454_tui"
$p4 = New-Sess $s4
& $PSMUX split-window -v -t $s4 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$panesBefore = (& $PSMUX display-message -t $s4 -p '#{window_panes}' 2>&1).Trim()
& $breakExe $p4.Id break
Start-Sleep -Seconds 2
$p4.Refresh()
$panesAfter = (& $PSMUX display-message -t $s4 -p '#{window_panes}' 2>&1).Trim()
if (-not $p4.HasExited -and $panesAfter -eq $panesBefore -and $panesAfter -eq "2") {
    Write-Pass "TUI: 2-pane layout intact and window alive after Ctrl+Break"
} else {
    Write-Fail "TUI: layout/window changed after Ctrl+Break (panes $panesBefore -> $panesAfter, exited=$($p4.HasExited))"
}
& $PSMUX kill-session -t $s4 2>&1 | Out-Null
try { if (-not $p4.HasExited) { Stop-Process -Id $p4.Id -Force -EA SilentlyContinue } } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
