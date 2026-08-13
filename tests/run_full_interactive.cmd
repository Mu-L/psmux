@echo off
REM Launch the FULL psmux test suite in a dedicated console window.
REM
REM WHY A SEPARATE CONSOLE: many suites launch an ATTACHED psmux client and some
REM drive it with real keystrokes (WriteConsoleInput via AttachConsole). Those
REM need a real console of their own, and they will happily kill whatever console
REM they are attached to. Running them inside an agent/tool shell both breaks the
REM tests (no window to find, see test_config_exhaustive_tui) and can take the
REM caller's terminal down with it.
REM
REM WHY THE SINGLE-INSTANCE GUARD: the runner kills ALL psmux processes and wipes
REM ~/.psmux between every test. Two concurrent runs therefore destroy each
REM other's sessions mid-test and produce a stream of bogus failures that look
REM exactly like product bugs. This happened once and cost a full triage cycle,
REM so starting a second run is now refused rather than allowed to corrupt both.
REM
REM WHY THE ENVIRONMENT IS SCRUBBED: 22 suites shell out to claude.exe. Launched
REM from inside a Claude Code session, the child inherits CLAUDE_CODE_CHILD_SESSION
REM and is treated as a nested child with its teammate toolset suppressed. That is
REM the harness leaking its identity into the product under test.
REM
REM -IncludeInteractive : run the TUI suites instead of skipping them
REM -IncludeWSL         : run the tmux parity suites (WSL tmux present)
REM (no -SkipPerf)      : perf/stress suites run too
REM Test discovery is a glob over tests\test_*.ps1, so any NEW test file is
REM picked up automatically with no registration and nothing is filtered out.
title psmux FULL test suite (interactive)
cd /d "%~dp0\.."
set PSMUX_TEST_SANDBOX=1

pwsh -NoProfile -ExecutionPolicy Bypass -Command ^
  "$running = @(Get-CimInstance Win32_Process -Filter \"Name='pwsh.exe'\" | Where-Object { $_.CommandLine -match 'run_all_tests' -and $_.ProcessId -ne $PID });" ^
  "if ($running.Count -gt 0) {" ^
  "  Write-Host ''; Write-Host 'REFUSING TO START: a psmux test run is already active.' -ForegroundColor Red;" ^
  "  $running | ForEach-Object { Write-Host ('  existing run pid ' + $_.ProcessId + ' started ' + $_.CreationDate) -ForegroundColor Yellow };" ^
  "  Write-Host 'Two concurrent runs wipe each other''s sessions and produce bogus failures.' -ForegroundColor Yellow;" ^
  "  Write-Host 'Stop the existing run first, then relaunch.' -ForegroundColor Yellow;" ^
  "  exit 99 }" ^
  "Get-ChildItem env: | Where-Object { $_.Name -like 'CLAUDE*' -or $_.Name -like 'ANTHROPIC*' } | ForEach-Object { Write-Host ('  scrubbed env: ' + $_.Name) -ForegroundColor DarkGray; Remove-Item ('env:' + $_.Name) -EA SilentlyContinue };" ^
  "$env:PSMUX_TEST_SANDBOX='1';" ^
  "Write-Host ''; Write-Host '============================================================' -ForegroundColor Cyan;" ^
  "Write-Host '  psmux FULL TEST SUITE (interactive, dedicated window)' -ForegroundColor Cyan;" ^
  "Write-Host ('  Started: ' + (Get-Date)) -ForegroundColor Cyan;" ^
  "Write-Host '============================================================' -ForegroundColor Cyan; Write-Host '';" ^
  "& '.\tests\run_all_tests.ps1' -IncludeInteractive -IncludeWSL %*"

set RC=%ERRORLEVEL%
echo.
echo ============================================================
if "%RC%"=="99" (
  echo   NOT STARTED - another run was already active
) else (
  echo   RUN COMPLETE  -  exit code %RC%
)
echo   Finished: %DATE% %TIME%
echo ============================================================
echo This window stays open so the summary is readable.
pause
