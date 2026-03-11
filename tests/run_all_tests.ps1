# psmux Comprehensive Test Runner
# Runs ALL test suites sequentially with proper cleanup, captures results,
# and produces a full report including performance metrics.
#
# Usage: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run_all_tests.ps1

param(
    [switch]$SkipPerf,       # Skip long-running perf/stress tests
    [switch]$IncludeWSL,     # Include WSL-dependent tests
    [switch]$IncludeInteractive  # Include tests that need interactive TUI
)

$ErrorActionPreference = "Continue"
$startTime = Get-Date

# ── Binary discovery ──
$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -ErrorAction SilentlyContinue).Path
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -ErrorAction SilentlyContinue).Path }
if (-not $PSMUX) { $PSMUX = (Get-Command psmux -ErrorAction SilentlyContinue).Source }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }
Write-Host "Binary: $PSMUX" -ForegroundColor Cyan
Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host ""

# ── Categorize tests ──
# Tests requiring WSL
$wslTests = @(
    "test_wsl_in_pwsh_latency", "test_wsl_in_pwsh_latency2", "test_wsl_latency",
    "test_wsl_pwsh_latency3", "test_wsl_pwsh_latency4", "test_wsl_pwsh_latency5"
)
# Tests requiring interactive TUI / attached session / mouse
$interactiveTests = @(
    "test_claude_mouse", "test_conpty_mouse", "test_mouse_handling", "test_mouse_hover",
    "test_stress_attached", "test_tui_exit_cleanup", "test_claude_cursor_diag",
    "test_issue60_native_tui_mouse", "test_issue15_altgr", "test_cursor_fallback",
    "test_cursor_style", "test_issue52_cursor", "test_perf_vs_wt"
)
# Long-running stress/perf tests
$perfTests = @(
    "test_stress", "test_stress_50", "test_stress_aggressive", "test_extreme_perf",
    "test_e2e_latency", "test_pane_startup_perf", "test_startup_perf", "test_perf"
)

# Results tracking
$results = [System.Collections.ArrayList]::new()

function Clean-Server {
    # Gracefully ask all servers to exit
    try { & $PSMUX kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 500
    # Force-kill any lingering processes
    Get-Process psmux -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # Wait for OS to release TCP ports and file handles
    Start-Sleep -Seconds 3
    # Remove stale port/key files
    Remove-Item "$env:USERPROFILE\.psmux\*.port" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:USERPROFILE\.psmux\*.key" -Force -ErrorAction SilentlyContinue
    # Remove any test config files (tests should restore originals but may fail)
    Remove-Item "$env:USERPROFILE\.psmux.conf" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:USERPROFILE\.psmuxrc" -Force -ErrorAction SilentlyContinue
    # Verify no psmux processes remain
    $remaining = Get-Process psmux -ErrorAction SilentlyContinue
    if ($remaining) {
        Start-Sleep -Seconds 2
        Get-Process psmux -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
}

function Run-TestFile {
    param([string]$FilePath)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $baseName = $name

    # Check skip categories
    if ($wslTests -contains $baseName -and -not $IncludeWSL) {
        return @{ Name = $baseName; Status = "SKIP"; Reason = "WSL required"; Passed = 0; Failed = 0; Duration = 0 }
    }
    if ($interactiveTests -contains $baseName -and -not $IncludeInteractive) {
        return @{ Name = $baseName; Status = "SKIP"; Reason = "Interactive TUI required"; Passed = 0; Failed = 0; Duration = 0 }
    }
    if ($perfTests -contains $baseName -and $SkipPerf) {
        return @{ Name = $baseName; Status = "SKIP"; Reason = "Perf test (use -SkipPerf to skip)"; Passed = 0; Failed = 0; Duration = 0 }
    }

    Clean-Server

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "`n$('=' * 60)" -ForegroundColor DarkGray
    Write-Host "  RUNNING: $baseName" -ForegroundColor White
    Write-Host "$('=' * 60)" -ForegroundColor DarkGray

    try {
        $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $FilePath 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        $sw.Stop()

        # Count PASS/FAIL from output (multiple patterns used by different test scripts)
        $passCount = ([regex]::Matches($output, '\[PASS\]')).Count
        $passCount += ([regex]::Matches($output, '(?m)^PASS\s')).Count
        $passCount += ([regex]::Matches($output, '=> PASS$', [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count
        $failCount = ([regex]::Matches($output, '\[FAIL\]')).Count
        $failCount += ([regex]::Matches($output, '(?m)^FAIL\s')).Count
        $failCount += ([regex]::Matches($output, '=> FAIL$', [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count
        $skipCount = ([regex]::Matches($output, '\[SKIP\]')).Count

        # Show output
        Write-Host $output

        $status = if ($exitCode -eq 0 -and $failCount -eq 0) { "PASS" } else { "FAIL" }

        return @{
            Name = $baseName
            Status = $status
            ExitCode = $exitCode
            Passed = $passCount
            Failed = $failCount
            Skipped = $skipCount
            Duration = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            Output = $output
        }
    } catch {
        $sw.Stop()
        Write-Host "  ERROR: $_" -ForegroundColor Red
        return @{
            Name = $baseName
            Status = "ERROR"
            Passed = 0
            Failed = 1
            Duration = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            Output = $_.ToString()
        }
    }
}

# ── Collect all test files ──
$allTests = Get-ChildItem "$PSScriptRoot\test_*.ps1" | Sort-Object Name
Write-Host "Found $($allTests.Count) test files" -ForegroundColor Cyan

# ── Run each test ──
foreach ($testFile in $allTests) {
    $result = Run-TestFile -FilePath $testFile.FullName
    [void]$results.Add($result)
}

# ── Final cleanup ──
Clean-Server

# ── Generate Report ──
$endTime = Get-Date
$totalDuration = ($endTime - $startTime).TotalSeconds

Write-Host "`n"
Write-Host ("=" * 80) -ForegroundColor White
Write-Host "  COMPREHENSIVE TEST REPORT" -ForegroundColor White
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host ("=" * 80) -ForegroundColor White

$passed = @($results | Where-Object { $_.Status -eq "PASS" })
$failed = @($results | Where-Object { $_.Status -eq "FAIL" -or $_.Status -eq "ERROR" })
$skipped = @($results | Where-Object { $_.Status -eq "SKIP" })

$totalTests = 0; $totalPassed = 0; $totalFailed = 0
foreach ($r in $results) { $totalTests += ($r.Passed + $r.Failed); $totalPassed += $r.Passed; $totalFailed += $r.Failed }

Write-Host "`n  SUITE SUMMARY:" -ForegroundColor Cyan
Write-Host "  -------------------------------------------------------"
Write-Host ("  Suites PASSED:  {0}" -f $passed.Count) -ForegroundColor Green
Write-Host ("  Suites FAILED:  {0}" -f $failed.Count) -ForegroundColor $(if ($failed.Count -gt 0) { "Red" } else { "Green" })
Write-Host ("  Suites SKIPPED: {0}" -f $skipped.Count) -ForegroundColor Yellow
Write-Host ""
Write-Host "  INDIVIDUAL TEST SUMMARY:" -ForegroundColor Cyan
Write-Host "  -------------------------------------------------------"
Write-Host ("  Tests PASSED:   {0}" -f $totalPassed) -ForegroundColor Green
Write-Host ("  Tests FAILED:   {0}" -f $totalFailed) -ForegroundColor $(if ($totalFailed -gt 0) { "Red" } else { "Green" })
Write-Host ("  Total Duration: {0:F1}s ({1:F1} min)" -f $totalDuration, ($totalDuration / 60))

if ($passed.Count -gt 0) {
    Write-Host "`n  PASSED SUITES:" -ForegroundColor Green
    foreach ($r in $passed) {
        Write-Host ("    [PASS] {0,-45} {1,3}P/{2}F  ({3}s)" -f $r.Name, $r.Passed, $r.Failed, $r.Duration) -ForegroundColor Green
    }
}

if ($failed.Count -gt 0) {
    Write-Host "`n  FAILED SUITES:" -ForegroundColor Red
    foreach ($r in $failed) {
        Write-Host ("    [FAIL] {0,-45} {1,3}P/{2}F  ({3}s)" -f $r.Name, $r.Passed, $r.Failed, $r.Duration) -ForegroundColor Red
    }
}

if ($skipped.Count -gt 0) {
    Write-Host "`n  SKIPPED SUITES:" -ForegroundColor Yellow
    foreach ($r in $skipped) {
        Write-Host ("    [SKIP] {0,-45} {1}" -f $r.Name, $r.Reason) -ForegroundColor Yellow
    }
}

# Performance report from test outputs
Write-Host "`n"
Write-Host ("=" * 80) -ForegroundColor White
Write-Host "  PERFORMANCE METRICS (suite timings, top 15 slowest)" -ForegroundColor White
Write-Host ("=" * 80) -ForegroundColor White
Write-Host ""
$perfResults = $results | Where-Object { $_.Status -ne "SKIP" } | Sort-Object { $_.Duration } -Descending | Select-Object -First 15
foreach ($r in $perfResults) {
    $barLen = [math]::Min([math]::Max([int]($r.Duration / 3), 1), 40)
    $bar = "#" * $barLen
    $color = if ($r.Status -eq "PASS") { "Green" } elseif ($r.Status -eq "FAIL") { "Red" } else { "Yellow" }
    Write-Host ("  {0,-45} {1,6:F1}s {2}" -f $r.Name, $r.Duration, $bar) -ForegroundColor $color
}

Write-Host "`n"
Write-Host ("=" * 80) -ForegroundColor White
if ($totalFailed -gt 0) {
    Write-Host "  RESULT: FAILURES DETECTED ($totalFailed tests failed)" -ForegroundColor Red
    exit 1
} else {
    Write-Host "  RESULT: ALL TESTS PASSED ($totalPassed tests across $($passed.Count) suites)" -ForegroundColor Green
    exit 0
}
