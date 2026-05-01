# Issue #264: paste-buffer does not deliver content to pane
# REPRODUCTION TEST - prove whether paste-buffer works or not

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "repro_264"
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

# === SETUP ===
Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed"
    exit 1
}
Write-Pass "Session $SESSION created"

Write-Host "`n=== Issue #264 Reproduction Tests ===" -ForegroundColor Cyan

# === TEST 1: set-buffer + paste-buffer (no -p, named buffer) ===
Write-Host "`n[Test 1] set-buffer + paste-buffer (no -p, named buffer -b b1)" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "clear" Enter
Start-Sleep -Seconds 1

& $PSMUX set-buffer -b b1 'echo TEST_1_NO_DASH_P'
$showB1 = & $PSMUX show-buffer -b b1 2>&1 | Out-String
Write-Host "  show-buffer b1: $($showB1.Trim())"

& $PSMUX paste-buffer -b b1 -t $SESSION
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -t $SESSION Enter
Start-Sleep -Seconds 2

$cap1 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap1 -match "TEST_1_NO_DASH_P") {
    Write-Pass "paste-buffer delivered 'echo TEST_1_NO_DASH_P' to pane"
} else {
    Write-Fail "paste-buffer did NOT deliver content. Captured: $($cap1.Trim())"
}

# === TEST 2: set-buffer + paste-buffer -p (bracketed paste, named buffer) ===
Write-Host "`n[Test 2] set-buffer + paste-buffer -p (bracketed paste, named buffer -b b2)" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "clear" Enter
Start-Sleep -Seconds 1

& $PSMUX set-buffer -b b2 'echo TEST_2_WITH_DASH_P'
$showB2 = & $PSMUX show-buffer -b b2 2>&1 | Out-String
Write-Host "  show-buffer b2: $($showB2.Trim())"

& $PSMUX paste-buffer -p -b b2 -t $SESSION
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -t $SESSION Enter
Start-Sleep -Seconds 2

$cap2 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap2 -match "TEST_2_WITH_DASH_P") {
    Write-Pass "paste-buffer -p delivered 'echo TEST_2_WITH_DASH_P' to pane"
} else {
    Write-Fail "paste-buffer -p did NOT deliver content. Captured: $($cap2.Trim())"
}

# === TEST 3: set-buffer + paste-buffer (default buffer, no -b) ===
Write-Host "`n[Test 3] set-buffer + paste-buffer (default buffer, no -b)" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "clear" Enter
Start-Sleep -Seconds 1

& $PSMUX set-buffer 'echo TEST_3_DEFAULT_BUFFER'
$showDef = & $PSMUX show-buffer 2>&1 | Out-String
Write-Host "  show-buffer (default): $($showDef.Trim())"

& $PSMUX paste-buffer -t $SESSION
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -t $SESSION Enter
Start-Sleep -Seconds 2

$cap3 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap3 -match "TEST_3_DEFAULT_BUFFER") {
    Write-Pass "paste-buffer (default) delivered content to pane"
} else {
    Write-Fail "paste-buffer (default) did NOT deliver content. Captured: $($cap3.Trim())"
}

# === TEST 4: load-buffer from stdin + paste-buffer -p (CAO pattern) ===
Write-Host "`n[Test 4] load-buffer from stdin + paste-buffer -p (CAO exact pattern)" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "clear" Enter
Start-Sleep -Seconds 1

# Pipe content to load-buffer stdin
"echo TEST_4_CAO_PATTERN" | & $PSMUX load-buffer -b b4 -
$showB4 = & $PSMUX show-buffer -b b4 2>&1 | Out-String
Write-Host "  show-buffer b4: $($showB4.Trim())"

& $PSMUX paste-buffer -p -b b4 -t $SESSION
Start-Sleep -Milliseconds 500
& $PSMUX send-keys -t $SESSION Enter
Start-Sleep -Seconds 2

$cap4 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap4 -match "TEST_4_CAO_PATTERN") {
    Write-Pass "load-buffer stdin + paste-buffer -p delivered content"
} else {
    Write-Fail "load-buffer stdin + paste-buffer -p did NOT deliver content. Captured: $($cap4.Trim())"
}

# === TEST 5: Sanity check send-keys -l works ===
Write-Host "`n[Test 5] Sanity: send-keys -l delivers content (baseline)" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "clear" Enter
Start-Sleep -Seconds 1

& $PSMUX send-keys -t $SESSION -l 'echo SEND_KEYS_LITERAL_WORKS'
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $SESSION Enter
Start-Sleep -Seconds 2

$cap5 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
if ($cap5 -match "SEND_KEYS_LITERAL_WORKS") {
    Write-Pass "send-keys -l delivered content (baseline OK)"
} else {
    Write-Fail "send-keys -l did NOT work. Captured: $($cap5.Trim())"
}

# === TEST 6: TCP path - paste-buffer via raw TCP ===
Write-Host "`n[Test 6] paste-buffer via raw TCP socket" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "clear" Enter
Start-Sleep -Seconds 1

& $PSMUX set-buffer -b b6 'echo TEST_6_TCP_PATH'

$portFile = "$psmuxDir\$SESSION.port"
$keyFile = "$psmuxDir\$SESSION.key"
if ((Test-Path $portFile) -and (Test-Path $keyFile)) {
    $port = (Get-Content $portFile -Raw).Trim()
    $key = (Get-Content $keyFile -Raw).Trim()
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)
        $writer.Write("AUTH $key`n"); $writer.Flush()
        $authResp = $reader.ReadLine()
        if ($authResp -eq "OK") {
            $writer.Write("paste-buffer -b b6`n"); $writer.Flush()
            $stream.ReadTimeout = 5000
            try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
            Write-Host "  TCP paste-buffer response: $resp"
            
            Start-Sleep -Seconds 1
            & $PSMUX send-keys -t $SESSION Enter
            Start-Sleep -Seconds 2
            
            $cap6 = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
            if ($cap6 -match "TEST_6_TCP_PATH") {
                Write-Pass "TCP paste-buffer delivered content to pane"
            } else {
                Write-Fail "TCP paste-buffer did NOT deliver content. Captured: $($cap6.Trim())"
            }
        } else {
            Write-Fail "TCP AUTH failed: $authResp"
        }
        $tcp.Close()
    } catch {
        Write-Fail "TCP connection failed: $_"
    }
} else {
    Write-Fail "Port/key files not found for TCP test"
}

# === TEST 7: Edge case - paste-buffer with non-existent buffer ===
Write-Host "`n[Test 7] Edge: paste-buffer with non-existent buffer" -ForegroundColor Yellow
$errOut = & $PSMUX paste-buffer -b nonexistent_buffer -t $SESSION 2>&1 | Out-String
Write-Host "  paste-buffer nonexistent exit: $LASTEXITCODE, output: $($errOut.Trim())"
if ($LASTEXITCODE -ne 0 -or $errOut -match "no buffer|not found|error") {
    Write-Pass "paste-buffer with bad buffer name handled gracefully"
} else {
    Write-Fail "paste-buffer with bad buffer name did not error"
}

# === TEARDOWN ===
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -eq 0) {
    Write-Host "`n  CONCLUSION: paste-buffer IS WORKING on psmux $((& $PSMUX -V 2>&1).Trim())" -ForegroundColor Green
    Write-Host "  The issue #264 claim that paste-buffer is a no-op is NOT REPRODUCIBLE." -ForegroundColor Green
} else {
    Write-Host "`n  CONCLUSION: paste-buffer has $($script:TestsFailed) failing scenario(s)" -ForegroundColor Red
}

exit $script:TestsFailed
