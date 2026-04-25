# Issue #257: Preview support + draggable popup for choose-tree/choose-session
#
# This test verifies:
#   1. capture-pane with cross-window targeting (-t :@WID) works
#      (the underlying mechanism the preview pane relies on)
#   2. capture-pane with cross-pane targeting (-t :@WID.%PID) works
#   3. The TUI popup (choose-tree) opens visible without crashing
#   4. The injector can drive prefix+w / prefix+s to open the pickers
#
# This test does NOT screen-scrape the popup — visual verification is via
# CLI plus by confirming the underlying capture mechanism returns content.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "issue257_preview"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    & $PSMUX kill-session -t "${SESSION}_b" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Remove-Item "$psmuxDir\${SESSION}_b.*" -Force -EA SilentlyContinue
}

Cleanup

Write-Host "`n=== Issue #257: Preview support + draggable popup ===" -ForegroundColor Cyan

# Create a session with two windows so the tree has multiple entries.
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed"
    Cleanup; exit 1
}

# Create a 2nd window and put a marker in it.
& $PSMUX new-window -t $SESSION -n "preview_target"
Start-Sleep -Seconds 2
& $PSMUX send-keys -t $SESSION "echo PREVIEW_MARKER_FROM_W1" Enter
Start-Sleep -Seconds 1

# Get window IDs
$winsJson = & $PSMUX list-windows -t $SESSION -F '#{window_index}:#{window_id}:#{window_name}' 2>&1
Write-Host "  Windows: $($winsJson -join '; ')" -ForegroundColor DarkGray

# === TEST 1: capture-pane with cross-window target -t :@WID works ===
Write-Host "`n[Test 1] capture-pane -t :@WID returns active pane content" -ForegroundColor Yellow

# Find the @ id of the second window
$secondWid = $null
foreach ($line in $winsJson) {
    if ($line -match '^\s*1:@(\d+):') { $secondWid = $matches[1]; break }
}
if (-not $secondWid) {
    # Fallback: try without index parsing
    $idLine = (& $PSMUX display-message -t "${SESSION}:1" -p '#{window_id}' 2>&1).Trim()
    if ($idLine -match '@?(\d+)') { $secondWid = $matches[1] }
}
Write-Host "  Second window ID: @$secondWid" -ForegroundColor DarkGray

if ($secondWid) {
    $cap = & $PSMUX capture-pane -p -t ":@$secondWid" 2>&1 | Out-String
    if ($cap -match "PREVIEW_MARKER_FROM_W1") {
        Write-Pass "Cross-window capture-pane returned target window content"
    } else {
        Write-Fail "Cross-window capture-pane did not return marker. Got: $($cap.Substring(0, [Math]::Min(200, $cap.Length)))"
    }
} else {
    Write-Fail "Could not parse second window id"
}

# === TEST 2: capture-pane with explicit pane id -t :@WID.%PID ===
Write-Host "`n[Test 2] capture-pane -t :@WID.%PID returns specific pane" -ForegroundColor Yellow
if ($secondWid) {
    $panesJson = & $PSMUX list-panes -t "${SESSION}:1" -F '#{pane_id}' 2>&1
    $firstPane = ($panesJson | Select-Object -First 1).Trim().TrimStart('%')
    if ($firstPane -match '^\d+$') {
        $cap2 = & $PSMUX capture-pane -p -t ":@$secondWid.%$firstPane" 2>&1 | Out-String
        if ($cap2.Length -gt 0) {
            Write-Pass "Pane-targeted capture-pane returned content (length=$($cap2.Length))"
        } else {
            Write-Fail "Pane-targeted capture-pane returned empty"
        }
    } else {
        Write-Fail "Could not parse pane id from: $panesJson"
    }
}

# === TEST 3: Visible TUI popup opens without crash ===
Write-Host "`n[Test 3] Win32 TUI: prefix+w opens choose-tree popup" -ForegroundColor Yellow

$injectorExe = "$env:TEMP\psmux_injector.exe"
if (-not (Test-Path $injectorExe)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (Test-Path $csc) {
        & $csc /nologo /optimize /out:$injectorExe tests\injector.cs 2>&1 | Out-Null
    }
}

$SESSION_TUI = "issue257_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

# Add another window so the tree has content
& $PSMUX new-window -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Seconds 1

$beforeWin = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_index}' 2>&1).Trim()
Write-Host "  Active window before: $beforeWin" -ForegroundColor DarkGray

if (Test-Path $injectorExe) {
    # Open choose-tree (prefix+w), navigate down, press Enter
    & $injectorExe $proc.Id "^b{SLEEP:300}w{SLEEP:600}{ENTER}"
    Start-Sleep -Seconds 2

    # The session is still alive (didn't crash)
    & $PSMUX has-session -t $SESSION_TUI 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "Session survived prefix+w + Enter (no crash from preview rendering)"
    } else {
        Write-Fail "Session died after prefix+w (popup or preview crashed)"
    }
} else {
    Write-Fail "Injector not available (skipping TUI keystroke test)"
}

# === TEST 4: choose-session opens without crash ===
Write-Host "`n[Test 4] Win32 TUI: prefix+s opens choose-session popup" -ForegroundColor Yellow
if (Test-Path $injectorExe) {
    & $injectorExe $proc.Id "^b{SLEEP:300}s{SLEEP:600}{ESC}"
    Start-Sleep -Seconds 1
    & $PSMUX has-session -t $SESSION_TUI 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "Session survived prefix+s + Esc"
    } else {
        Write-Fail "Session died after prefix+s"
    }
}

# === Cleanup ===
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Cleanup

# === TEST 5 (follow-up): window-layout endpoint reflects real splits ===
Write-Host "`n[Test 5] window-layout returns full split layout JSON" -ForegroundColor Yellow

$SESSION_LAY = "issue257_layout"
& $PSMUX kill-session -t $SESSION_LAY 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION_LAY.*" -Force -EA SilentlyContinue

& $PSMUX new-session -d -s $SESSION_LAY
Start-Sleep -Seconds 2
& $PSMUX split-window -h -t $SESSION_LAY 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
& $PSMUX split-window -v -t $SESSION_LAY 2>&1 | Out-Null
Start-Sleep -Milliseconds 600

$wid = (& $PSMUX display-message -t $SESSION_LAY -p '#{window_id}' 2>&1).Trim().TrimStart('@')
$panes = & $PSMUX list-panes -t $SESSION_LAY -F '#{pane_id}' 2>&1
$paneCount = ($panes | Where-Object { $_ -match '%\d+' }).Count
Write-Host "  Window @$wid has $paneCount panes" -ForegroundColor DarkGray

if ($paneCount -ne 3) {
    Write-Fail "Expected 3 panes, got $paneCount"
} else {
    $portPath = "$psmuxDir\$SESSION_LAY.port"
    $keyPath  = "$psmuxDir\$SESSION_LAY.key"
    if (-not (Test-Path $portPath) -or -not (Test-Path $keyPath)) {
        Write-Fail "Port or key file missing for $SESSION_LAY"
    } else {
        $port = [int](Get-Content $portPath -Raw).Trim()
        $key  = (Get-Content $keyPath -Raw).Trim()
        try {
            $client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $port)
            $stream = $client.GetStream()
            $stream.ReadTimeout = 1500
            $writer = [System.IO.StreamWriter]::new($stream)
            $writer.NewLine = "`n"
            $writer.AutoFlush = $true
            $reader = [System.IO.StreamReader]::new($stream)
            $writer.WriteLine("AUTH $key")
            # Consume auth ack ("OK")
            $null = $reader.ReadLine()
            $writer.WriteLine("window-layout $wid")
            Start-Sleep -Milliseconds 400
            $resp = ""
            while ($stream.DataAvailable) {
                $resp += [char]$stream.ReadByte()
            }
            $client.Close()
            Write-Host "  Layout JSON: $resp" -ForegroundColor DarkGray
            $leafCount = ([regex]::Matches($resp, '"type":"leaf"')).Count
            $hasSplit  = $resp -match '"type":"split"'
            $hasH = $resp -match '"kind":"Horizontal"'
            $hasV = $resp -match '"kind":"Vertical"'
            if ($hasSplit -and $leafCount -ge 3 -and $hasH -and $hasV) {
                Write-Pass "window-layout returned 3 leaves with both Horizontal+Vertical splits"
            } else {
                Write-Fail "Layout JSON missing structure (split=$hasSplit, leaves=$leafCount, H=$hasH, V=$hasV)"
            }
        } catch {
            Write-Fail "TCP request to window-layout failed: $_"
        }
    }
}

& $PSMUX kill-session -t $SESSION_LAY 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION_LAY.*" -Force -EA SilentlyContinue

# === TEST 6: capture-pane -e -p preserves ANSI SGR escape sequences ===
Write-Host "`n[Test 6] capture-pane -e -p emits SGR escape sequences" -ForegroundColor Yellow
$SESSION_E = "issue257_esc"
& $PSMUX kill-session -t $SESSION_E 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
Remove-Item "$psmuxDir\$SESSION_E.*" -Force -EA SilentlyContinue

& $PSMUX new-session -d -s $SESSION_E
Start-Sleep -Seconds 2
# Print a colored marker (red on default)
& $PSMUX send-keys -t $SESSION_E "Write-Host 'ESCMARKER' -ForegroundColor Red" Enter
Start-Sleep -Seconds 2

$capE = & $PSMUX capture-pane -e -p -t $SESSION_E 2>&1 | Out-String
# Look for ESC[ ... m sequences (SGR) and the marker
$ESC = [char]27
$hasSgr = $capE -match "$ESC\["
$hasMarker = $capE -match 'ESCMARKER'
if ($hasSgr -and $hasMarker) {
    Write-Pass "capture-pane -e returned SGR-escaped output containing the marker"
} else {
    Write-Fail "Expected SGR + ESCMARKER. hasSgr=$hasSgr hasMarker=$hasMarker"
}
& $PSMUX kill-session -t $SESSION_E 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION_E.*" -Force -EA SilentlyContinue

# === TEST 7: Win32 TUI: pressing 'p' inside choose-session does not crash ===
Write-Host "`n[Test 7] Win32 TUI: 'p' toggles preview without crashing" -ForegroundColor Yellow
if (Test-Path $injectorExe) {
    $SESSION_TG = "issue257_toggle"
    & $PSMUX kill-session -t $SESSION_TG 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    Remove-Item "$psmuxDir\$SESSION_TG.*" -Force -EA SilentlyContinue

    $procT = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TG -PassThru
    Start-Sleep -Seconds 4

    # Open choose-session, press p twice (toggle off, toggle on), then Esc.
    & $injectorExe $procT.Id "^b{SLEEP:300}s{SLEEP:600}p{SLEEP:200}p{SLEEP:200}{ESC}"
    Start-Sleep -Seconds 1
    & $PSMUX has-session -t $SESSION_TG 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "Session survived 'p' toggle in choose-session"
    } else {
        Write-Fail "Session died after pressing 'p'"
    }
    & $PSMUX kill-session -t $SESSION_TG 2>&1 | Out-Null
    try { Stop-Process -Id $procT.Id -Force -EA SilentlyContinue } catch {}
    Remove-Item "$psmuxDir\$SESSION_TG.*" -Force -EA SilentlyContinue
} else {
    Write-Fail "Injector not available"
}
