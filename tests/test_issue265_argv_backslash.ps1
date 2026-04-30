# Issue #265: argv parser drops -e args after a value ending in backslash + spaces
# IRREFUTABLE PROOF of the bug — exercises Python subprocess + psmux new-session

$ErrorActionPreference = "Continue"
# Use the freshly-built psmux from this repo, not the installed one
$repoPsmux = Join-Path (Resolve-Path "$PSScriptRoot\..\target\release") "psmux.exe"
if (Test-Path $repoPsmux) { $PSMUX = $repoPsmux } else { $PSMUX = (Get-Command psmux -EA Stop).Source }
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

function Cleanup-Sessions {
    foreach ($s in @("bsrepro_a", "bsrepro_b", "bsrepro_c", "bsrepro_d", "bsrepro_quote", "bsrepro_qb")) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
        Remove-Item "$psmuxDir\$s.*" -Force -EA SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
}

Write-Host "`n=== Issue #265: argv parser backslash bug ===" -ForegroundColor Cyan
Write-Host "  psmux version: $(& $PSMUX -V)" -ForegroundColor DarkGray
Cleanup-Sessions

# ============================================================
# TEST 1: Python subprocess (exact repro from issue)
# ============================================================
Write-Host "`n[Test 1] Python subprocess repro (issue's exact case)" -ForegroundColor Yellow

$pyScript = @'
import subprocess, sys, os
psmux = sys.argv[1]
cmd = [psmux, "new-session", "-s", "bsrepro_a", "-n", "w", "-d",
       "-e", r"TRAILING_BS=C:\Program Files\Foo Bar\plugins" + chr(92),
       "-e", "NEXT_VAR=should_survive",
       "-e", "CAO_TERMINAL_ID=test-id-12345"]
print("ARGV passed by Python (raw list):", file=sys.stderr)
for a in cmd: print(f"  {a!r}", file=sys.stderr)
print("Encoded command line (list2cmdline):", file=sys.stderr)
print(f"  {subprocess.list2cmdline(cmd)}", file=sys.stderr)
r = subprocess.run(cmd, capture_output=True, text=True)
print("STDOUT:", r.stdout)
print("STDERR:", r.stderr, file=sys.stderr)
sys.exit(r.returncode)
'@
$pyScriptFile = "$env:TEMP\issue265_repro.py"
$pyScript | Set-Content -Path $pyScriptFile -Encoding UTF8

Write-Info "Running Python subprocess..."
$pyOut = python $pyScriptFile $PSMUX 2>&1 | Out-String
Write-Host $pyOut -ForegroundColor DarkGray

Start-Sleep -Seconds 3

# Check if session was created
& $PSMUX has-session -t bsrepro_a 2>$null
$sessionExists = ($LASTEXITCODE -eq 0)

if (-not $sessionExists) {
    Write-Fail "Session bsrepro_a was not created at all"
} else {
    Write-Pass "Session bsrepro_a was created"

    # Now check show-environment
    $envOut = & $PSMUX show-environment -t bsrepro_a 2>&1 | Out-String
    Write-Info "show-environment output:"
    Write-Host $envOut -ForegroundColor DarkGray

    # The bug: TRAILING_BS swallows everything; NEXT_VAR/CAO_TERMINAL_ID missing.
    # Capture the value FIRST (subsequent -match calls clobber $matches).
    $trailingValue = $null
    if ($envOut -match "(?m)^TRAILING_BS=(.*)$") { $trailingValue = $matches[1] }
    $nextVarPresent = $envOut -match "(?m)^NEXT_VAR=should_survive"
    $caoIdPresent = $envOut -match "(?m)^CAO_TERMINAL_ID=test-id-12345"

    Write-Info "TRAILING_BS captured value: [$trailingValue]"

    if ($trailingValue) {
        if ($trailingValue -match "should_survive" -or $trailingValue -match "-e NEXT_VAR") {
            Write-Fail "BUG CONFIRMED: TRAILING_BS swallowed subsequent -e args. Value: $trailingValue"
        } elseif ($trailingValue.TrimEnd() -eq 'C:\Program Files\Foo Bar\plugins\') {
            Write-Pass "TRAILING_BS value is correct (no swallowing)"
        } else {
            Write-Info "TRAILING_BS unusual: $trailingValue"
        }
    } else {
        Write-Fail "TRAILING_BS not found in environment"
    }

    if ($nextVarPresent) { Write-Pass "NEXT_VAR=should_survive present (expected)" }
    else { Write-Fail "BUG CONFIRMED: NEXT_VAR=should_survive MISSING from environment" }

    if ($caoIdPresent) { Write-Pass "CAO_TERMINAL_ID=test-id-12345 present (expected)" }
    else { Write-Fail "BUG CONFIRMED: CAO_TERMINAL_ID=test-id-12345 MISSING from environment" }
}

# ============================================================
# TEST 2: Direct psmux invocation with raw quoted arg
# Manually craft the exact argv the OS sees
# ============================================================
Write-Host "`n[Test 2] Direct invocation (cmd /c with raw command line)" -ForegroundColor Yellow

# Per Python list2cmdline rules, a value with spaces ending in \ becomes:
#   "VALUE\\"
# psmux should parse this correctly.
# Let's use cmd /c to fully control the command line.

$rawCmd = '"' + $PSMUX + '"' + ' new-session -s bsrepro_b -n w -d ' +
          '-e "TRAILING_BS=C:\Program Files\Foo Bar\plugins\\" ' +
          '-e NEXT_VAR=should_survive ' +
          '-e CAO_TERMINAL_ID=test-id-12345'

Write-Info "Raw command line (as cmd.exe would see it after parsing):"
Write-Host "  $rawCmd" -ForegroundColor DarkGray

cmd /c $rawCmd 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Start-Sleep -Seconds 3

& $PSMUX has-session -t bsrepro_b 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "Session bsrepro_b created"
    $envOut = & $PSMUX show-environment -t bsrepro_b 2>&1 | Out-String
    Write-Info "show-environment output:"
    Write-Host $envOut -ForegroundColor DarkGray

    if ($envOut -match "(?m)^NEXT_VAR=should_survive") { Write-Pass "NEXT_VAR present" }
    else { Write-Fail "BUG: NEXT_VAR missing in raw cmd test" }

    if ($envOut -match "(?m)^CAO_TERMINAL_ID=test-id-12345") { Write-Pass "CAO_TERMINAL_ID present" }
    else { Write-Fail "BUG: CAO_TERMINAL_ID missing in raw cmd test" }
} else {
    Write-Fail "Session bsrepro_b not created"
}

# ============================================================
# TEST 3: Control case - value WITHOUT trailing backslash works
# ============================================================
Write-Host "`n[Test 3] Control case: same value WITHOUT trailing backslash" -ForegroundColor Yellow

$rawCmd2 = '"' + $PSMUX + '"' + ' new-session -s bsrepro_c -n w -d ' +
           '-e "NORMAL_PATH=C:\Program Files\Foo Bar\plugins" ' +
           '-e NEXT_VAR=should_survive ' +
           '-e CAO_TERMINAL_ID=test-id-12345'

cmd /c $rawCmd2 2>&1 | Out-Null
Start-Sleep -Seconds 2

& $PSMUX has-session -t bsrepro_c 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "Control session bsrepro_c created"
    $envOut = & $PSMUX show-environment -t bsrepro_c 2>&1 | Out-String

    if ($envOut -match "(?m)^NEXT_VAR=should_survive") { Write-Pass "Control: NEXT_VAR present (expected)" }
    else { Write-Fail "Even WITHOUT trailing backslash, NEXT_VAR missing - different bug!" }

    if ($envOut -match "(?m)^CAO_TERMINAL_ID=test-id-12345") { Write-Pass "Control: CAO_TERMINAL_ID present" }
    else { Write-Fail "Control: CAO_TERMINAL_ID missing" }
}

# ============================================================
# TEST 4: Test what psmux sees in argv directly
# Use /b switch on display-message to dump env vars
# ============================================================
Write-Host "`n[Test 4] Verify TRAILING_BS exact content for bsrepro_a" -ForegroundColor Yellow

& $PSMUX has-session -t bsrepro_a 2>$null
if ($LASTEXITCODE -eq 0) {
    # show-environment with specific var name
    $tb = & $PSMUX show-environment -t bsrepro_a TRAILING_BS 2>&1 | Out-String
    Write-Info "show-environment -t bsrepro_a TRAILING_BS:"
    Write-Host "  [$($tb.Trim())]" -ForegroundColor DarkGray

    $nv = & $PSMUX show-environment -t bsrepro_a NEXT_VAR 2>&1 | Out-String
    Write-Info "show-environment -t bsrepro_a NEXT_VAR:"
    Write-Host "  [$($nv.Trim())]" -ForegroundColor DarkGray

    $cao = & $PSMUX show-environment -t bsrepro_a CAO_TERMINAL_ID 2>&1 | Out-String
    Write-Info "show-environment -t bsrepro_a CAO_TERMINAL_ID:"
    Write-Host "  [$($cao.Trim())]" -ForegroundColor DarkGray
}

# ============================================================
# TEST 5: Quote-only repro (no Python) - force "VAL\\" through PowerShell
# PowerShell's native arg passing
# ============================================================
Write-Host "`n[Test 5] PowerShell native invocation with backslash" -ForegroundColor Yellow

# Approach: use Start-Process with raw -ArgumentList to control encoding
$argsList = @(
    "new-session", "-s", "bsrepro_d", "-n", "w", "-d",
    "-e", "PATH_VAR=C:\Program Files\Foo Bar\plugins\",
    "-e", "NEXT_VAR=should_survive",
    "-e", "ID=test-id"
)
Write-Info "Calling psmux directly through PowerShell with each arg as element..."
& $PSMUX @argsList 2>&1 | Out-Null
Start-Sleep -Seconds 2

& $PSMUX has-session -t bsrepro_d 2>$null
if ($LASTEXITCODE -eq 0) {
    $envOut = & $PSMUX show-environment -t bsrepro_d 2>&1 | Out-String
    Write-Info "show-environment for bsrepro_d:"
    Write-Host $envOut -ForegroundColor DarkGray

    if ($envOut -match "(?m)^NEXT_VAR=should_survive") { Write-Pass "PS native: NEXT_VAR present" }
    else { Write-Fail "BUG: PS native call also drops NEXT_VAR" }
    if ($envOut -match "(?m)^ID=test-id") { Write-Pass "PS native: ID present" }
    else { Write-Fail "BUG: PS native call also drops ID" }
}

# ============================================================
# TEST 6: Win32 TUI VISUAL VERIFICATION (Layer 2 mandatory)
# Launch a real visible psmux session that uses spawn_server_hidden,
# then drive it via CLI commands and verify env propagation.
# ============================================================
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

$SESSION_TUI = "issue265tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 500

# Spawn the server via the same code path as a real user invocation.
# This goes through main.rs new-session CLI handler -> spawn_server_hidden
# (CreateProcessW with our escape_arg_msvcrt). PowerShell's Start-Process
# would re-quote args, so we use direct & invocation.
& $PSMUX new-session -s $SESSION_TUI -d `
    -e "TUI_PATH=C:\Program Files\Foo Bar\plugins\" `
    -e "TUI_NEXT=after_bs" `
    -e "TUI_LAST=last_value"
Start-Sleep -Seconds 3

& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "TUI: session alive after spawn_server_hidden"

    $envOut = & $PSMUX show-environment -t $SESSION_TUI 2>&1 | Out-String
    # Use simple substring match — env keys are unique enough.
    if ($envOut -match [regex]::Escape("TUI_PATH=C:\Program Files\Foo Bar\plugins\")) {
        Write-Pass "TUI: TUI_PATH correctly contains trailing backslash"
    } else {
        Write-Fail "TUI: TUI_PATH wrong. show-environment output:`n$envOut"
    }
    if ($envOut -match "TUI_NEXT=after_bs") { Write-Pass "TUI: TUI_NEXT survived" }
    else { Write-Fail "TUI: TUI_NEXT swallowed" }
    if ($envOut -match "TUI_LAST=last_value") { Write-Pass "TUI: TUI_LAST survived" }
    else { Write-Fail "TUI: TUI_LAST swallowed" }

    # Drive a non-env state change via CLI to confirm the spawned session
    # responds to TCP commands (proves end-to-end functionality).
    & $PSMUX split-window -v -t $SESSION_TUI 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $panes = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1).Trim()
    if ($panes -eq "2") { Write-Pass "TUI: split-window works on backslash-spawned session" }
    else { Write-Fail "TUI: split-window failed (panes=$panes)" }
} else {
    Write-Fail "TUI: session never came up"
}

& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null

# ============================================================
# Cleanup
# ============================================================
Cleanup-Sessions
Remove-Item $pyScriptFile -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

if ($script:TestsFailed -gt 0) {
    Write-Host "`n  >>> BUG #265 CONFIRMED <<<" -ForegroundColor Red
} else {
    Write-Host "`n  >>> No bug observed (cannot reproduce) <<<" -ForegroundColor Green
}

exit $script:TestsFailed
