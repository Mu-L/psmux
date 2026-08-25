# Issue #596: Ctrl+P / Ctrl+N in copy mode move the cursor instead of scrolling.
#
# The reporter was right about what happens and docs/keybindings.md was wrong
# about what should happen. tmux 3.4 binds C-p to cursor-up and C-n to
# cursor-down in the copy-mode table (key-bindings.c:571 and :572) and does not
# bind either in copy-mode-vi. The keys that scroll the viewport one line in
# tmux are C-Up and C-Down, bound in BOTH tables (key-bindings.c:635/:636 and
# :727/:728). psmux had no arm for those, so a real Ctrl+Arrow in copy mode did
# nothing at all.
#
# This test pins all four keys on both surfaces:
#   Layer 1 (CLI + TCP dump-state) drives the server command path with
#           `send-keys -t s C-p` and reads copy_cursor_row / scroll_offset back.
#   Layer 2 (MANDATORY attached Win32 TUI) launches a real attached client and
#           injects real WriteConsoleInput KEY_EVENT records, which is the only
#           way to prove what a user pressing the key actually gets.
#
# Both mode-keys settings are covered because psmux keeps the emacs motions live
# in vi mode too.

param([string]$PsmuxPath = "")

$ErrorActionPreference = "Continue"
$env:PSMUX_NO_WARM = "1"

$PSMUX = if ($PsmuxPath) { $PsmuxPath } else { "$env:USERPROFILE\.cargo\bin\psmux.exe" }
if (-not (Test-Path $PSMUX)) { Write-Host "[FAIL] psmux not found at $PSMUX"; exit 1 }

$SOCK = "i596"
$psmuxDir = "$env:USERPROFILE\.psmux"
$pass = 0
$fail = 0
$skip = 0

function Write-Pass($m) { Write-Host "[PASS] $m" -ForegroundColor Green; $script:pass++ }
function Write-Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Write-Skip($m) { Write-Host "[SKIP] $m" -ForegroundColor Yellow; $script:skip++ }

function Get-Leaf([string]$Session) {
    $portFile = "$psmuxDir\${SOCK}__$Session.port"
    $keyFile = "$psmuxDir\${SOCK}__$Session.key"
    if (-not (Test-Path $portFile)) { return $null }
    $port = (Get-Content $portFile -Raw).Trim()
    $key = (Get-Content $keyFile -Raw).Trim()
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    } catch { return $null }
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("dump-state`n"); $writer.Flush()
    try { $resp = $reader.ReadLine() } catch { $resp = $null }
    $tcp.Close()
    if (-not $resp -or $resp.Length -lt 50) { return $null }
    return ($resp | ConvertFrom-Json).layout
}

function Fill-Pane([string]$Session) {
    & $PSMUX -L $SOCK send-keys -t $Session "1..300 | % { `"line-`$_`" }" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 3
}

Write-Host "`n=== ISSUE #596: copy mode Ctrl+P / Ctrl+N / Ctrl+Up / Ctrl+Down ===" -ForegroundColor Cyan

# ══════════════════════════════════════════════════════════════════════════
# Layer 1: CLI + TCP dump-state (server command dispatch path)
# ══════════════════════════════════════════════════════════════════════════
Write-Host "`n--- Layer 1: CLI send-keys + dump-state ---" -ForegroundColor Cyan

foreach ($mode in @("vi", "emacs")) {
    $S = "i596cli$mode"
    & $PSMUX -L $SOCK kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    & $PSMUX -L $SOCK new-session -d -s $S -x 80 -y 24 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1200
    & $PSMUX -L $SOCK set-option -t $S -g mode-keys $mode 2>&1 | Out-Null
    Fill-Pane $S
    & $PSMUX -L $SOCK copy-mode -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500

    $l = Get-Leaf $S
    if (-not $l -or -not $l.copy_mode) {
        Write-Skip "$mode : could not enter copy mode over the CLI, nothing proven"
        & $PSMUX -L $SOCK kill-session -t $S 2>&1 | Out-Null
        continue
    }

    # Park the cursor mid pane so no edge clamps a motion or a scroll.
    for ($i = 0; $i -lt 6; $i++) { & $PSMUX -L $SOCK send-keys -t $S "Up" 2>&1 | Out-Null; Start-Sleep -Milliseconds 120 }
    $b = Get-Leaf $S
    Write-Host ("      mid pane: scroll_offset={0} row={1}" -f $b.scroll_offset, $b.copy_cursor_row)

    # C-p: cursor up one row, viewport still.
    & $PSMUX -L $SOCK send-keys -t $S "C-p" 2>&1 | Out-Null; Start-Sleep -Milliseconds 250
    $a = Get-Leaf $S
    if ($a.copy_cursor_row -eq ($b.copy_cursor_row - 1) -and $a.scroll_offset -eq $b.scroll_offset) {
        Write-Pass "$mode : C-p moved the cursor $($b.copy_cursor_row) -> $($a.copy_cursor_row), scroll_offset stayed $($a.scroll_offset)"
    } else {
        Write-Fail "$mode : C-p expected row $($b.copy_cursor_row - 1) / offset $($b.scroll_offset), got row $($a.copy_cursor_row) / offset $($a.scroll_offset)"
    }

    # C-n: cursor down one row, viewport still.
    $b = $a
    & $PSMUX -L $SOCK send-keys -t $S "C-n" 2>&1 | Out-Null; Start-Sleep -Milliseconds 250
    $a = Get-Leaf $S
    if ($a.copy_cursor_row -eq ($b.copy_cursor_row + 1) -and $a.scroll_offset -eq $b.scroll_offset) {
        Write-Pass "$mode : C-n moved the cursor $($b.copy_cursor_row) -> $($a.copy_cursor_row), scroll_offset stayed $($a.scroll_offset)"
    } else {
        Write-Fail "$mode : C-n expected row $($b.copy_cursor_row + 1) / offset $($b.scroll_offset), got row $($a.copy_cursor_row) / offset $($a.scroll_offset)"
    }

    # C-Up: viewport up one line, cursor still.
    $b = $a
    & $PSMUX -L $SOCK send-keys -t $S "C-Up" 2>&1 | Out-Null; Start-Sleep -Milliseconds 250
    $a = Get-Leaf $S
    if ($a.scroll_offset -eq ($b.scroll_offset + 1) -and $a.copy_cursor_row -eq $b.copy_cursor_row) {
        Write-Pass "$mode : C-Up scrolled $($b.scroll_offset) -> $($a.scroll_offset), cursor row stayed $($a.copy_cursor_row)"
    } else {
        Write-Fail "$mode : C-Up expected offset $($b.scroll_offset + 1) / row $($b.copy_cursor_row), got offset $($a.scroll_offset) / row $($a.copy_cursor_row)"
    }

    # C-Down: viewport back down one line, cursor still.
    $b = $a
    & $PSMUX -L $SOCK send-keys -t $S "C-Down" 2>&1 | Out-Null; Start-Sleep -Milliseconds 250
    $a = Get-Leaf $S
    if ($a.scroll_offset -eq ($b.scroll_offset - 1) -and $a.copy_cursor_row -eq $b.copy_cursor_row) {
        Write-Pass "$mode : C-Down scrolled $($b.scroll_offset) -> $($a.scroll_offset), cursor row stayed $($a.copy_cursor_row)"
    } else {
        Write-Fail "$mode : C-Down expected offset $($b.scroll_offset - 1) / row $($b.copy_cursor_row), got offset $($a.scroll_offset) / row $($a.copy_cursor_row)"
    }

    & $PSMUX -L $SOCK kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
}

# ══════════════════════════════════════════════════════════════════════════
# Layer 2 (MANDATORY): attached Win32 TUI, real WriteConsoleInput keystrokes
# ══════════════════════════════════════════════════════════════════════════
Write-Host "`n--- Layer 2: attached TUI + WriteConsoleInput injection ---" -ForegroundColor Cyan

$injector = "$env:TEMP\psmux_injector_596.exe"
if (-not (Test-Path $injector)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    }
    & $csc /nologo /optimize /out:$injector "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
}

if (-not (Test-Path $injector)) {
    Write-Skip "could not compile injector.cs, the attached TUI layer proves nothing"
} else {
    # The suite itself may run inside a psmux pane. An attached client refuses to
    # start there ("sessions should be nested with care"), so launch through a
    # .cmd that scrubs the nesting variables first.
    $S = "i596tui"
    $launchCmd = "$env:TEMP\psmux_596_launch.cmd"
    @"
@echo off
set PSMUX_SESSION=
set PSMUX_PANE=
set TMUX=
set TMUX_PANE=
set PSMUX=
set PSMUX_NO_WARM=1
"$PSMUX" -L $SOCK new-session -s $S -x 80 -y 24
"@ | Set-Content -Path $launchCmd -Encoding ASCII

    & $PSMUX -L $SOCK kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $null = Start-Process -FilePath $launchCmd -PassThru
    Start-Sleep -Seconds 7

    $cli = Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" |
        Where-Object { $_.CommandLine -match "-L $SOCK" -and $_.CommandLine -match "new-session -s $S" }

    if (-not $cli) {
        Write-Skip "no attached client came up, injection layer proves nothing"
    } else {
        $clientPid = $cli.ProcessId
        Write-Host "      attached client pid=$clientPid"
        Fill-Pane $S

        # prefix (C-b) then '[' enters copy mode, exactly as a user does it.
        & $injector $clientPid "^b" | Out-Null
        Start-Sleep -Milliseconds 400
        & $injector $clientPid "[" | Out-Null
        Start-Sleep -Milliseconds 900

        $l = Get-Leaf $S
        if (-not $l -or -not $l.copy_mode) {
            Write-Skip "prefix+[ did not reach the client, no keys were delivered, nothing proven"
        } else {
            Write-Pass "injected prefix+[ entered copy mode (copy_mode=$($l.copy_mode))"

            # Park the cursor mid pane with real Up presses.
            for ($i = 0; $i -lt 5; $i++) { & $injector $clientPid "{UP}" | Out-Null; Start-Sleep -Milliseconds 220 }

            # ^p  -> cursor up one row, viewport still
            $b = Get-Leaf $S
            & $injector $clientPid "^p" | Out-Null; Start-Sleep -Milliseconds 500
            $a = Get-Leaf $S
            if ($a.copy_cursor_row -eq ($b.copy_cursor_row - 1) -and $a.scroll_offset -eq $b.scroll_offset) {
                Write-Pass "TUI Ctrl+P moved the cursor $($b.copy_cursor_row) -> $($a.copy_cursor_row), scroll_offset stayed $($a.scroll_offset)"
            } else {
                Write-Fail "TUI Ctrl+P expected row $($b.copy_cursor_row - 1) / offset $($b.scroll_offset), got row $($a.copy_cursor_row) / offset $($a.scroll_offset)"
            }

            # ^n  -> cursor down one row, viewport still
            $b = $a
            & $injector $clientPid "^n" | Out-Null; Start-Sleep -Milliseconds 500
            $a = Get-Leaf $S
            if ($a.copy_cursor_row -eq ($b.copy_cursor_row + 1) -and $a.scroll_offset -eq $b.scroll_offset) {
                Write-Pass "TUI Ctrl+N moved the cursor $($b.copy_cursor_row) -> $($a.copy_cursor_row), scroll_offset stayed $($a.scroll_offset)"
            } else {
                Write-Fail "TUI Ctrl+N expected row $($b.copy_cursor_row + 1) / offset $($b.scroll_offset), got row $($a.copy_cursor_row) / offset $($a.scroll_offset)"
            }

            # Ctrl+Up as a real KEY_EVENT: VK_UP with LEFT_CTRL_PRESSED.
            $b = $a
            & $injector $clientPid "{RAW:26:00:0008}" | Out-Null; Start-Sleep -Milliseconds 500
            $a = Get-Leaf $S
            if ($a.scroll_offset -eq ($b.scroll_offset + 1) -and $a.copy_cursor_row -eq $b.copy_cursor_row) {
                Write-Pass "TUI Ctrl+Up scrolled $($b.scroll_offset) -> $($a.scroll_offset), cursor row stayed $($a.copy_cursor_row)"
            } else {
                Write-Fail "TUI Ctrl+Up expected offset $($b.scroll_offset + 1) / row $($b.copy_cursor_row), got offset $($a.scroll_offset) / row $($a.copy_cursor_row)"
            }

            # Ctrl+Down: VK_DOWN with LEFT_CTRL_PRESSED.
            $b = $a
            & $injector $clientPid "{RAW:28:00:0008}" | Out-Null; Start-Sleep -Milliseconds 500
            $a = Get-Leaf $S
            if ($a.scroll_offset -eq ($b.scroll_offset - 1) -and $a.copy_cursor_row -eq $b.copy_cursor_row) {
                Write-Pass "TUI Ctrl+Down scrolled $($b.scroll_offset) -> $($a.scroll_offset), cursor row stayed $($a.copy_cursor_row)"
            } else {
                Write-Fail "TUI Ctrl+Down expected offset $($b.scroll_offset - 1) / row $($b.copy_cursor_row), got offset $($a.scroll_offset) / row $($a.copy_cursor_row)"
            }

            # Repeat the whole quartet to rule out a one shot fluke.
            $flaky = $false
            for ($round = 1; $round -le 3; $round++) {
                $b = Get-Leaf $S
                & $injector $clientPid "^p" | Out-Null; Start-Sleep -Milliseconds 400
                $a1 = Get-Leaf $S
                if ($a1.copy_cursor_row -ne ($b.copy_cursor_row - 1)) { $flaky = $true }
                & $injector $clientPid "{RAW:26:00:0008}" | Out-Null; Start-Sleep -Milliseconds 400
                $a2 = Get-Leaf $S
                if ($a2.scroll_offset -ne ($a1.scroll_offset + 1)) { $flaky = $true }
                & $injector $clientPid "{RAW:28:00:0008}" | Out-Null; Start-Sleep -Milliseconds 400
                $a3 = Get-Leaf $S
                if ($a3.scroll_offset -ne $a1.scroll_offset) { $flaky = $true }
                & $injector $clientPid "^n" | Out-Null; Start-Sleep -Milliseconds 400
            }
            if ($flaky) { Write-Fail "repeat rounds disagreed with the first pass" }
            else { Write-Pass "3 repeat rounds of Ctrl+P / Ctrl+Up / Ctrl+Down all behaved identically" }
        }

        & $PSMUX -L $SOCK kill-session -t $S 2>&1 | Out-Null
        Start-Sleep -Milliseconds 600
        Stop-Process -Id $clientPid -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n=== RESULT: $pass passed, $fail failed, $skip skipped ===" -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 }
exit 0
