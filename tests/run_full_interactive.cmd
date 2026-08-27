@echo off
REM Thin launcher for the FULL psmux test suite in a dedicated console window.
REM
REM All of the logic (single instance guard, environment scrub, banner, exit code
REM reporting) lives in run_full_interactive.ps1. It used to be inlined here as
REM one pwsh -Command with caret continuations and nested escaped quotes, which
REM was unreadable and made the guard hard to get right. It is a script now.
REM
REM Any extra arguments (for example -Resume, or -Only <name>) are forwarded
REM straight through to run_all_tests.ps1.
title psmux FULL test suite (interactive)
cd /d "%~dp0\.."

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_full_interactive.ps1" %*

set RC=%ERRORLEVEL%
echo.
echo ============================================================
if "%RC%"=="99" (
  echo   NOT STARTED - another run was already active
) else if "%RC%"=="130" (
  echo   RUN INTERRUPTED - stopped on request, remaining suites did not run
  echo   Resume with: tests\run_full_interactive.cmd -Resume
) else (
  echo   RUN COMPLETE  -  exit code %RC%
)
echo   Finished: %DATE% %TIME%
echo ============================================================
echo This window stays open so the summary is readable.
pause
