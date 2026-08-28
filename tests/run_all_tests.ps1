# psmux Comprehensive Test Runner
# Runs ALL test suites sequentially with proper cleanup, captures results,
# and produces a full report including performance metrics.
#
# Usage: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run_all_tests.ps1

param(
    [switch]$SkipPerf,       # Skip long-running perf/stress tests
    [switch]$IncludeWSL,     # Include WSL-dependent tests
    [switch]$IncludeInteractive, # Include tests that need interactive TUI
    [int]$DefaultTimeoutSec = 240,  # Per-suite timeout (normal suites)
    [int]$LongTimeoutSec = 900,     # Per-suite timeout (perf/stress/latency suites)
    [string]$Only,           # Regex filter: run only suites whose name matches
    [switch]$Resume,         # Continue the latest run: skip suites that already have a result
    [string]$TestDir         # Override test directory (default: this script's folder)
)

# ── Safety gate: this runner is DESTRUCTIVE to a live psmux ──────────────────
# Before every test it kills ALL psmux processes (by image name) and deletes
# ~/.psmux\*.port, *.key and ~/.psmux.conf / ~/.psmuxrc. That is fine in a
# throwaway sandbox (the Docker dev image / CI) but would wipe a real user's
# running sessions and config. Refuse to run unless the caller has explicitly
# confirmed a sandbox by setting PSMUX_TEST_SANDBOX=1.
if ($env:PSMUX_TEST_SANDBOX -ne '1') {
    Write-Host ''
    Write-Host 'REFUSING TO RUN: this test runner is destructive to a live psmux.' -ForegroundColor Red
    Write-Host 'Between tests it kills ALL psmux processes and deletes' -ForegroundColor Yellow
    Write-Host '~/.psmux\*.port, *.key and ~/.psmux.conf / ~/.psmuxrc.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Run it only in a throwaway/sandbox environment (e.g. the Docker dev' -ForegroundColor Yellow
    Write-Host 'image, which sets this automatically). To confirm a sandbox and run:' -ForegroundColor Yellow
    Write-Host '    $env:PSMUX_TEST_SANDBOX = "1"; pwsh -File tests\run_all_tests.ps1' -ForegroundColor Cyan
    Write-Host ''
    exit 2
}

$ErrorActionPreference = "Continue"
$startTime = Get-Date

# NO_COLOR poisons every color assertion in the tree: psmux honors it and
# strips SGR, so a runner launched from a shell that sets it (AI agent tool
# shells do) fakes a machine-wide "psmux drops all colour" regression across
# the issue2/263/425/451 families. Proven 2026-08-05: 12 suites red with it,
# all green without, identical binary. Scrub it for this process and every
# suite we spawn.
Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue

# Suppress Windows hard-error popups for this process and EVERYTHING it
# spawns (the error mode is inherited through CreateProcess). The runner and
# the suites kill whole process trees constantly, and a console child caught
# mid-initialization while its console/job is being torn down dies with
# STATUS_DLL_INIT_FAILED (0xc0000142). Without this, each such death posts a
# MODAL "pwsh.exe - Application Error" dialog to the desktop; Windows queues
# them, so they keep resurfacing one OK-click at a time for hours after a
# sweep. Measured 2026-08-21: every 0xc0000142 popup in a 7-day window fell
# inside a full-sweep run (bursts of 10-12 around the codex-suite tree
# kills), zero outside them.
#   SEM_FAILCRITICALERRORS (0x1) | SEM_NOGPFAULTERRORBOX (0x2) |
#   SEM_NOOPENFILEERRORBOX (0x8000)
Add-Type -Name ErrMode -Namespace PsmuxRunner -MemberDefinition `
    '[DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint uMode);'
[void][PsmuxRunner.ErrMode]::SetErrorMode(0x1 -bor 0x2 -bor 0x8000)

# ── Abort channel: stop a run WITHOUT needing the runner window ──────────────
#
# WHY A FILE AND NOT JUST Ctrl+C: the suites launch attached psmux clients in
# their own consoles, and those windows TAKE THE FOREGROUND within seconds of a
# run starting. Measured 2026-08-26 by sampling GetForegroundWindow every 300ms
# across a -Only tui_proof run: the runner console held focus for 2 seconds, a
# psmux.exe window took it, and the runner never got it back. Ctrl+C is only
# delivered to the console that HAS focus, so for most of a multi-hour run the
# runner console is simply not reachable from the keyboard. The only exit left
# was killing pwsh from Task Manager, which skips the summary and strands every
# psmux server the in-flight suite had started (measured: 3 orphans).
#
# So the abort signal is a FILE any other shell can create:
#     tests\stop_tests.cmd     (or: New-Item $env:TEMP\psmux-teststop.flag)
# It is polled once a second inside the per-suite wait loop and again before
# each suite starts, so an abort lands within ~1s even in the middle of a 900s
# perf suite, and nothing further is started.
#
# Ctrl+C still works when the window IS reachable, but it is now routed through
# the same flag instead of killing the process. The native handler installed
# here runs BEFORE PowerShell's own (handlers fire in reverse registration
# order) and returns TRUE to swallow the event, so the runner survives long
# enough to kill the suite's process tree, tear down psmux and print the report
# for everything that did run.
$script:StopFile = Join-Path $env:TEMP "psmux-teststop.flag"

# A stop flag left behind by a previous abort would kill this run on its first
# poll. Clear it before the handler can ever look at it.
Remove-Item $script:StopFile -Force -ErrorAction SilentlyContinue

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;

public static class PsmuxTestAbort {
    delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    // The delegate MUST stay rooted. Windows calls it from a thread it injects
    // into this process; if the GC collects it first the call lands on freed
    // memory and the runner dies with an access violation instead of aborting.
    static HandlerRoutine _handler;
    static string _flagFile;

    public static volatile bool Requested;
    public static string Reason = "";

    public static void Install(string flagFile) {
        _flagFile = flagFile;
        _handler = new HandlerRoutine(OnCtrl);
        SetConsoleCtrlHandler(_handler, true);
    }

    static bool OnCtrl(uint t) {
        // 0 = CTRL_C, 1 = CTRL_BREAK, 2 = CTRL_CLOSE, 5 = LOGOFF, 6 = SHUTDOWN
        Reason = (t == 1) ? "Ctrl+Break" : "Ctrl+C";
        Requested = true;
        // Mirror to the flag file so the abort survives even if this handler
        // races the main thread, and so a watcher can see the run is stopping.
        try { File.WriteAllText(_flagFile, Reason); } catch { }
        // Swallow C/BREAK so the runner can clean up. CLOSE/LOGOFF/SHUTDOWN are
        // not ours to veto: Windows kills us shortly after regardless.
        return (t == 0 || t == 1);
    }
}
'@ -ErrorAction SilentlyContinue

[PsmuxTestAbort]::Install($script:StopFile)

$script:AbortReason = $null

# Returns the abort reason, or $null when the run should continue.
function Test-AbortRequested {
    if ($script:AbortReason) { return $script:AbortReason }
    if ([PsmuxTestAbort]::Requested) { return [PsmuxTestAbort]::Reason }
    if (Test-Path $script:StopFile) {
        $why = ""
        try { $why = (Get-Content $script:StopFile -Raw -ErrorAction SilentlyContinue) } catch {}
        if ($why) { $why = $why.Trim() }
        if (-not $why) { $why = "stop file" }
        return $why
    }
    return $null
}

# ── Logging setup ──────────────────────────────────────────────
# All logs go to $env:TEMP\psmux-test-logs\ (never inside the repo).
# Each run gets a timestamped folder with:
#   progress.log   – one-line-per-suite result, flushed immediately (crash-safe)
#   summary.log    – final report (written at end)
#   suites\<name>.log – full stdout/stderr captured from each test file
$script:LogRoot = Join-Path $env:TEMP "psmux-test-logs"
$script:RunId   = $startTime.ToString("yyyy-MM-dd_HH-mm-ss")
$latestFile = Join-Path $script:LogRoot "latest_run.txt"

# -Resume: continue the most recent run instead of starting a new one.
# Suites that already have a line in results.jsonl are skipped.
$script:CompletedSuites = @{}
if ($Resume -and (Test-Path $latestFile)) {
    $prevId = (Get-Content $latestFile -Raw).Trim()
    $prevDir = Join-Path $script:LogRoot $prevId
    if (Test-Path (Join-Path $prevDir "results.jsonl")) {
        $script:RunId = $prevId
        foreach ($line in (Get-Content (Join-Path $prevDir "results.jsonl"))) {
            try {
                $r = $line | ConvertFrom-Json
                $script:CompletedSuites[$r.Name] = $r
            } catch {}
        }
    }
}

$script:RunDir  = Join-Path $script:LogRoot $script:RunId
$script:SuiteDir = Join-Path $script:RunDir "suites"
New-Item -ItemType Directory -Path $script:SuiteDir -Force | Out-Null

$script:ProgressLog = Join-Path $script:RunDir "progress.log"
$script:SummaryLog  = Join-Path $script:RunDir "summary.log"
$script:ResultsJsonl = Join-Path $script:RunDir "results.jsonl"

Set-Content -Path $latestFile -Value $script:RunId -Encoding UTF8

function Write-Log {
    param([string]$Message, [string]$File = $script:ProgressLog)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "[$ts] $Message"
    # Append + flush immediately so partial results survive crashes/power loss
    [System.IO.File]::AppendAllText($File, "$line`r`n")
}

Write-Log "=== psmux test run started ==="
Write-Log "Run ID: $script:RunId"
Write-Log "Log directory: $script:RunDir"
if ($script:CompletedSuites.Count -gt 0) {
    Write-Log "Resuming: $($script:CompletedSuites.Count) suites already have results and will be skipped"
}

# ── Windows Job Object: guarantees the WHOLE process tree of a test dies ─────
# Why: the old Start-Job pattern hung FOREVER when a test left behind a child
# that inherited stdout (Stop-Job blocks on the pipe), and orphaned children
# survived across suites. A job object with KILL_ON_JOB_CLOSE kills every
# descendant (even orphans whose parent already exited) in one call.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PsmuxTestJob {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpInfo, uint cbInfoLength);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferBytes;
        public ulong WriteTransferBytes;
        public ulong OtherTransferBytes;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    const int  JobObjectExtendedLimitInformation  = 9;
    const uint PROCESS_SET_QUOTA_AND_TERMINATE    = 0x0100 | 0x0001;

    public static IntPtr Create() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return IntPtr.Zero;
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int len = Marshal.SizeOf(info);
        IntPtr buf = Marshal.AllocHGlobal(len);
        try {
            Marshal.StructureToPtr(info, buf, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buf, (uint)len)) {
                CloseHandle(job);
                return IntPtr.Zero;
            }
        } finally { Marshal.FreeHGlobal(buf); }
        return job;
    }

    public static bool Assign(IntPtr job, int pid) {
        IntPtr h = OpenProcess(PROCESS_SET_QUOTA_AND_TERMINATE, false, pid);
        if (h == IntPtr.Zero) return false;
        bool ok = AssignProcessToJobObject(job, h);
        CloseHandle(h);
        return ok;
    }

    // Terminate every process in the job, then release it.
    public static void Kill(IntPtr job) {
        if (job == IntPtr.Zero) return;
        TerminateJobObject(job, 0xDEAD);
        CloseHandle(job);
    }
}
'@ -ErrorAction SilentlyContinue

function Get-SuiteTimeout {
    param([string]$Name)
    # Perf/stress/latency suites legitimately run long; everything else gets the default.
    if ($Name -match 'perf|stress|latency|benchmark|extreme|battle|install_speed|e2e|sustained|exhaustive|nsis|installer|realistic_typing|robust_|win32_tui_flag_parity|issue615_wsl_pane_path') { return $LongTimeoutSec }
    return $DefaultTimeoutSec
}

# ── Binary discovery ──
$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -ErrorAction SilentlyContinue).Path
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -ErrorAction SilentlyContinue).Path }
if (-not $PSMUX) { $PSMUX = (Get-Command psmux -ErrorAction SilentlyContinue).Source }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

Write-Log "Binary: $PSMUX"
Write-Log "Params: SkipPerf=$SkipPerf IncludeWSL=$IncludeWSL IncludeInteractive=$IncludeInteractive DefaultTimeoutSec=$DefaultTimeoutSec LongTimeoutSec=$LongTimeoutSec Only='$Only' Resume=$Resume"

Write-Host "Binary: $PSMUX" -ForegroundColor Cyan
Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "Logs:    $script:RunDir" -ForegroundColor Cyan
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

# ── Live dashboard state ──
$script:LivePass = 0; $script:LiveFail = 0; $script:LiveSkip = 0
$script:LivePassTests = 0; $script:LiveFailTests = 0
$script:SuiteDurations = [System.Collections.ArrayList]::new()  # rolling avg for ETA

function Get-Category {
    param([string]$Name)
    if ($wslTests -contains $Name) { return "WSL" }
    if ($interactiveTests -contains $Name) { return "Interactive" }
    if ($perfTests -contains $Name) { return "Perf/Stress" }
    if ($Name -match 'test_issue') { return "Issue Fixes" }
    if ($Name -match 'test_config|test_plugin|test_theme') { return "Config/Plugin" }
    if ($Name -match 'test_copy_mode|test_pane|test_layout|test_split|test_zoom') { return "UI/Layout" }
    if ($Name -match 'test_session|test_kill|test_warm') { return "Session Mgmt" }
    return "General"
}

function Show-ProgressDashboard {
    param([int]$Current, [int]$Total, [string]$SuiteName, [string]$Status)
    $pct = if ($Total -gt 0) { [math]::Round(($Current / $Total) * 100) } else { 0 }
    $elapsed = ((Get-Date) - $startTime).TotalSeconds

    # ETA calculation from rolling average
    $eta = "--:--"
    if ($script:SuiteDurations.Count -gt 0) {
        $avgTime = ($script:SuiteDurations | Measure-Object -Average).Average
        $remaining = ($Total - $Current) * $avgTime
        if ($remaining -gt 3600) {
            $eta = "{0:F0}h {1:F0}m" -f [math]::Floor($remaining/3600), [math]::Floor(($remaining%3600)/60)
        } elseif ($remaining -gt 60) {
            $eta = "{0:F0}m {1:F0}s" -f [math]::Floor($remaining/60), [math]::Floor($remaining%60)
        } else {
            $eta = "{0:F0}s" -f $remaining
        }
    }

    # Progress bar (40 chars wide)
    $barWidth = 40
    $filled = [math]::Max([math]::Round($pct / 100 * $barWidth), 0)
    $empty  = $barWidth - $filled
    $barFill  = [char]0x2588  # full block
    $barEmpty = [char]0x2591  # light shade
    $bar = ($barFill.ToString() * $filled) + ($barEmpty.ToString() * $empty)

    $barColor = if ($script:LiveFail -gt 0) { "Red" } elseif ($pct -ge 80) { "Green" } else { "Yellow" }

    # Status badge
    $badge = switch ($Status) {
        "PASS"    { "[PASS]" }
        "FAIL"    { "[FAIL]" }
        "TIMEOUT" { "[TIME]" }
        "SKIP"    { "[SKIP]" }
        "ERROR"   { "[ERR!]" }
        default   { "[....]" }
    }
    $badgeColor = switch ($Status) {
        "PASS"    { "Green" }
        "FAIL"    { "Red" }
        "TIMEOUT" { "Red" }
        "SKIP"    { "Yellow" }
        "ERROR"   { "Magenta" }
        default   { "DarkGray" }
    }

    Write-Host ""
    Write-Host ("  {0} " -f $bar) -ForegroundColor $barColor -NoNewline
    Write-Host ("{0,3}%" -f $pct) -ForegroundColor White -NoNewline
    Write-Host ("  [{0}/{1}]" -f $Current, $Total) -ForegroundColor DarkGray -NoNewline
    Write-Host ("  ETA: {0}" -f $eta) -ForegroundColor Cyan

    # Live counters
    Write-Host "  " -NoNewline
    Write-Host ("Pass:{0}" -f $script:LivePass) -ForegroundColor Green -NoNewline
    Write-Host " | " -ForegroundColor DarkGray -NoNewline
    Write-Host ("Fail:{0}" -f $script:LiveFail) -ForegroundColor $(if ($script:LiveFail -gt 0) { "Red" } else { "Green" }) -NoNewline
    Write-Host " | " -ForegroundColor DarkGray -NoNewline
    Write-Host ("Skip:{0}" -f $script:LiveSkip) -ForegroundColor Yellow -NoNewline
    Write-Host " | " -ForegroundColor DarkGray -NoNewline
    Write-Host "Tests: " -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0}" -f $script:LivePassTests) -ForegroundColor Green -NoNewline
    Write-Host "/" -ForegroundColor DarkGray -NoNewline
    $fColor = if ($script:LiveFailTests -gt 0) { "Red" } else { "Green" }
    Write-Host ("{0}" -f $script:LiveFailTests) -ForegroundColor $fColor -NoNewline
    $elapsedFmt = if ($elapsed -gt 3600) { "{0:F0}h{1:F0}m" -f [math]::Floor($elapsed/3600),[math]::Floor(($elapsed%3600)/60) } elseif ($elapsed -gt 60) { "{0:F0}m{1:F0}s" -f [math]::Floor($elapsed/60),[math]::Floor($elapsed%60) } else { "{0:F0}s" -f $elapsed }
    Write-Host ("  Elapsed: {0}" -f $elapsedFmt) -ForegroundColor DarkGray

    # Last suite result
    if ($SuiteName) {
        Write-Host "  " -NoNewline
        Write-Host $badge -ForegroundColor $badgeColor -NoNewline
        Write-Host (" {0}" -f $SuiteName) -ForegroundColor White
    }
}

function Clean-Server {
    # If no psmux processes exist there is nothing to tear down; just clear files.
    $alive = @(Get-Process psmux -ErrorAction SilentlyContinue)
    if ($alive.Count -gt 0) {
        # Gracefully ask all servers to exit, but BOUNDED: a wedged server must not
        # hang the runner (the old unbounded `& $PSMUX kill-server` could block forever).
        try {
            $ks = Start-Process -FilePath $PSMUX -ArgumentList "kill-server" -PassThru -NoNewWindow `
                    -RedirectStandardOutput (Join-Path $script:RunDir "ks_out.tmp") `
                    -RedirectStandardError  (Join-Path $script:RunDir "ks_err.tmp")
            if (-not $ks.WaitForExit(5000)) { try { $ks.Kill() } catch {} }
        } catch {}
        # Force-kill any lingering processes, then poll (up to 3s) instead of fixed sleeps
        Get-Process psmux -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $deadline = [DateTime]::Now.AddSeconds(3)
        while ([DateTime]::Now -lt $deadline) {
            if (-not (Get-Process psmux -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 150
        }
        Get-Process psmux -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        # Brief settle so the OS releases TCP ports/file handles of killed servers
        Start-Sleep -Milliseconds 500
    }
    # Remove stale port/key files
    Remove-Item "$env:USERPROFILE\.psmux\*.port" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:USERPROFILE\.psmux\*.key" -Force -ErrorAction SilentlyContinue
    # Remove any test config files (tests should restore originals but may fail)
    Remove-Item "$env:USERPROFILE\.psmux.conf" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:USERPROFILE\.psmuxrc" -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $script:RunDir "ks_*.tmp") -Force -ErrorAction SilentlyContinue
}

function Run-TestFile {
    param([string]$FilePath)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $baseName = $name
    $suiteLog = Join-Path $script:SuiteDir "$baseName.log"

    # Check skip categories
    if ($wslTests -contains $baseName -and -not $IncludeWSL) {
        Write-Log "SKIP  $baseName  (WSL required)"
        return @{ Name = $baseName; Status = "SKIP"; Reason = "WSL required"; Passed = 0; Failed = 0; Duration = 0 }
    }
    if ($interactiveTests -contains $baseName -and -not $IncludeInteractive) {
        Write-Log "SKIP  $baseName  (Interactive TUI required)"
        return @{ Name = $baseName; Status = "SKIP"; Reason = "Interactive TUI required"; Passed = 0; Failed = 0; Duration = 0 }
    }
    if ($perfTests -contains $baseName -and $SkipPerf) {
        Write-Log "SKIP  $baseName  (Perf test, -SkipPerf active)"
        return @{ Name = $baseName; Status = "SKIP"; Reason = "Perf test (use -SkipPerf to skip)"; Passed = 0; Failed = 0; Duration = 0 }
    }

    Clean-Server

    Write-Log "START $baseName"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "`n$('=' * 60)" -ForegroundColor DarkGray
    Write-Host "  RUNNING: $baseName" -ForegroundColor White
    Write-Host "$('=' * 60)" -ForegroundColor DarkGray

    try {
        # Run the test as a real child process inside a Windows Job Object.
        #  - stdout/stderr go straight to files: nothing ever blocks on a pipe,
        #    and the log is tail-able in real time while the test runs.
        #  - On timeout (or after completion) the job object kills the ENTIRE
        #    process tree, including orphans whose parent already exited.
        $timeoutSec = Get-SuiteTimeout $baseName
        $outFile = Join-Path $script:SuiteDir "$baseName.out.tmp"
        $errFile = Join-Path $script:SuiteDir "$baseName.err.tmp"
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue

        $job = [PsmuxTestJob]::Create()
        # Pin the suite's working directory to the repo root: several suites
        # resolve `.\target\release\psmux.exe` relative to CWD, so inheriting
        # whatever directory the runner was launched from silently breaks them.
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        $proc = Start-Process -FilePath "pwsh" `
            -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File",$FilePath `
            -PassThru -NoNewWindow -WorkingDirectory $repoRoot `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $inJob = $false
        if ($job -ne [IntPtr]::Zero) { $inJob = [PsmuxTestJob]::Assign($job, $proc.Id) }

        # Wait with a heartbeat so long/hung tests are visible while they run.
        # The same 1s tick polls the abort channel, so a stop request lands
        # within a second even inside a 900s perf suite.
        $timedOut = $false
        $aborted = $false
        $lastBeat = [DateTime]::Now
        while (-not $proc.WaitForExit(1000)) {
            $why = Test-AbortRequested
            if ($why) { $aborted = $true; $script:AbortReason = $why; break }
            if ($sw.Elapsed.TotalSeconds -ge $timeoutSec) { $timedOut = $true; break }
            if (([DateTime]::Now - $lastBeat).TotalSeconds -ge 10) {
                $lastBeat = [DateTime]::Now
                $lastLine = ""
                try { $lastLine = (Get-Content $outFile -Tail 1 -ErrorAction SilentlyContinue) } catch {}
                if ($lastLine) { $lastLine = ($lastLine | Out-String).Trim() }
                if ($lastLine.Length -gt 80) { $lastLine = $lastLine.Substring(0, 80) }
                Write-Host ("  ... {0,4:F0}s / {1}s  {2}" -f $sw.Elapsed.TotalSeconds, $timeoutSec, $lastLine) -ForegroundColor DarkGray
                Write-Log ("HEARTBEAT $baseName {0:F0}s/{1}s" -f $sw.Elapsed.TotalSeconds, $timeoutSec)
            }
        }

        # A real Ctrl+C reaches the suite as well as the runner: the child was
        # started -NoNewWindow so it shares this console, and it dies at the same
        # instant we are signalled. The wait loop then exits NORMALLY, and
        # without this re-check the half-executed suite gets scored on its
        # truncated output - exit code 0, no assertions printed, therefore
        # "PASS". Measured 2026-08-26: test_fake_1 was killed 8s into a 15s body
        # and recorded PASS 0P/0F exit=0, and that bogus pass went into
        # results.jsonl where -Resume would skip the suite as already done.
        if (-not $aborted -and -not $timedOut) {
            $why = Test-AbortRequested
            # Deliberately biased towards calling it an abort: re-running a suite
            # that had genuinely just finished costs one suite, whereas trusting
            # a truncated pass loses coverage silently.
            if ($why) { $aborted = $true; $script:AbortReason = $why }
        }

        if ($aborted) {
            # Same teardown as a timeout: the job object kills the whole tree,
            # including the psmux servers the suite started, so an abort does not
            # strand processes the way a Task Manager kill of the runner did.
            Write-Host "`n  [ABORT] Stop requested ($script:AbortReason). Killing $baseName process tree." -ForegroundColor Yellow
            Write-Log "ABORT $baseName - stop requested ($script:AbortReason), killing process tree"
            if ($inJob) {
                [PsmuxTestJob]::Kill($job)
            } else {
                & taskkill /F /T /PID $proc.Id 2>&1 | Out-Null
            }
            try { $proc.WaitForExit(5000) | Out-Null } catch {}
            $sw.Stop()
            Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
            return @{
                Name = $baseName
                Status = "ABORT"
                ExitCode = -3
                Passed = 0; Failed = 0; Skipped = 0
                Duration = [math]::Round($sw.Elapsed.TotalSeconds, 1)
                Reason = "interrupted ($script:AbortReason)"
                Output = ""
            }
        }

        if ($timedOut) {
            Write-Host "  [TIMEOUT] Killing $baseName process tree after ${timeoutSec}s" -ForegroundColor Red
            Write-Log "TIMEOUT $baseName after ${timeoutSec}s, killing process tree"
            if ($inJob) {
                [PsmuxTestJob]::Kill($job)   # kills every descendant, even orphans
            } else {
                # Fallback: taskkill the tree if job-object assignment failed
                & taskkill /F /T /PID $proc.Id 2>&1 | Out-Null
            }
            try { $proc.WaitForExit(5000) | Out-Null } catch {}
            $exitCode = -2
        } else {
            try { $proc.WaitForExit() } catch {}  # ensure ExitCode is available
            $exitCode = $proc.ExitCode
            # Suite finished: reap anything it left behind (leaked children would
            # otherwise accumulate across 541 suites and poison later tests)
            if ($inJob) { [PsmuxTestJob]::Kill($job) }
        }
        $sw.Stop()

        # Collect output from the redirect files (out first, then err)
        $output = ""
        try { $output = [System.IO.File]::ReadAllText($outFile) } catch {}
        try {
            $errText = [System.IO.File]::ReadAllText($errFile)
            if ($errText.Trim()) { $output += "`r`n--- STDERR ---`r`n$errText" }
        } catch {}
        if ($timedOut) {
            $output += "`r`n[TIMEOUT] Test $baseName exceeded $timeoutSec seconds; process tree was killed`r`n"
        }
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue

        # Write full output to per-suite log file
        $suiteHeader = "Suite: $baseName`r`nFile:  $FilePath`r`nStart: $(($startTime + $sw.Elapsed - $sw.Elapsed).ToString('yyyy-MM-dd HH:mm:ss'))`r`nEnd:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`nExit:  $exitCode`r`nDuration: $([math]::Round($sw.Elapsed.TotalSeconds,1))s`r`n$('=' * 70)`r`n"
        [System.IO.File]::WriteAllText($suiteLog, "$suiteHeader$output", [System.Text.Encoding]::UTF8)

        # Count PASS/FAIL from output (multiple patterns used by different test scripts).
        # The colon form ("  PASS: msg" / "FAIL: msg") is used by the agent-teams
        # suites; without it their results recorded as 0P/0F despite real outcomes.
        $passCount = ([regex]::Matches($output, '\[PASS\]')).Count
        $passCount += ([regex]::Matches($output, '(?m)^PASS\s')).Count
        $passCount += ([regex]::Matches($output, '(?m)^\s*PASS:(?!\s*\d+\s*$)')).Count
        $passCount += ([regex]::Matches($output, '=> PASS$', [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count
        $failCount = ([regex]::Matches($output, '\[FAIL\]')).Count
        $failCount += ([regex]::Matches($output, '(?m)^FAIL\s')).Count
        # Negative lookahead: a bare number after the colon is a summary line
        # ("FAIL: 0"), not an assertion result, and must not be counted.
        $failCount += ([regex]::Matches($output, '(?m)^\s*FAIL:(?!\s*\d+\s*$)')).Count
        $failCount += ([regex]::Matches($output, '=> FAIL$', [System.Text.RegularExpressions.RegexOptions]::Multiline)).Count
        $skipCount = ([regex]::Matches($output, '\[SKIP\]')).Count

        # Show output
        Write-Host $output

        $status = if ($timedOut) { "TIMEOUT" }
                  elseif ($exitCode -eq 0 -and $failCount -eq 0) { "PASS" }
                  else { "FAIL" }

        Write-Log ("{0,-7} {1,-45} {2}P/{3}F  exit={4}  {5}s" -f $status, $baseName, $passCount, $failCount, $exitCode, [math]::Round($sw.Elapsed.TotalSeconds,1))

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
        [System.IO.File]::WriteAllText($suiteLog, "Suite: $baseName`r`nERROR: $_`r`n", [System.Text.Encoding]::UTF8)
        Write-Log "ERROR $baseName  $_"
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
$testRoot = if ($TestDir) { $TestDir } else { $PSScriptRoot }
$allTests = Get-ChildItem "$testRoot\test_*.ps1" | Sort-Object Name
if ($Only) {
    $allTests = @($allTests | Where-Object { $_.BaseName -match $Only })
    Write-Log "Filter -Only '$Only' matched $($allTests.Count) suites"
}
$totalSuites = $allTests.Count
Write-Host ""
Write-Host ("  {0} test suites discovered" -f $totalSuites) -ForegroundColor Cyan
Write-Log "Found $totalSuites test files"

# Category header
$catGroups = @{}
foreach ($t in $allTests) {
    $cat = Get-Category $t.BaseName
    if (-not $catGroups.ContainsKey($cat)) { $catGroups[$cat] = 0 }
    $catGroups[$cat]++
}
Write-Host "  Categories: " -ForegroundColor DarkGray -NoNewline
$catNames = ($catGroups.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "{0}({1})" -f $_.Key,$_.Value })
Write-Host ($catNames -join "  ") -ForegroundColor DarkGray
Write-Host ""

# ── Run each test ──
$suiteIndex = 0
$script:RunAborted = $false
$script:NotRunCount = 0
foreach ($testFile in $allTests) {
    $suiteIndex++

    # Abort check BEFORE anything is started, so a stop request never launches
    # one more suite. Covers the Clean-Server gap between suites too.
    $why = Test-AbortRequested
    if ($why) {
        $script:AbortReason = $why
        $script:RunAborted = $true
        $script:NotRunCount = $totalSuites - $suiteIndex + 1
        Write-Log "ABORT requested ($why) before [$suiteIndex/$totalSuites] $($testFile.BaseName); $script:NotRunCount suites not run"
        break
    }

    # Resume: skip suites that already completed in the run being resumed
    if ($script:CompletedSuites.ContainsKey($testFile.BaseName)) {
        $prev = $script:CompletedSuites[$testFile.BaseName]
        $result = @{
            Name = $prev.Name; Status = $prev.Status
            Passed = [int]$prev.Passed; Failed = [int]$prev.Failed
            Duration = [double]$prev.Duration; Reason = "already completed (resume)"
        }
        [void]$results.Add($result)
        Write-Host ("  [RESUME] {0,-45} {1} (from previous run)" -f $testFile.BaseName, $prev.Status) -ForegroundColor DarkCyan
        switch ($result.Status) {
            "PASS"    { $script:LivePass++ }
            "FAIL"    { $script:LiveFail++ }
            "TIMEOUT" { $script:LiveFail++ }
            "ERROR"   { $script:LiveFail++ }
            "SKIP"    { $script:LiveSkip++ }
        }
        $script:LivePassTests += $result.Passed
        $script:LiveFailTests += $result.Failed
        continue
    }

    Write-Log "--- [$suiteIndex/$totalSuites] Queuing $($testFile.BaseName) ---"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Run-TestFile -FilePath $testFile.FullName
    $sw.Stop()
    [void]$results.Add($result)
    [void]$script:SuiteDurations.Add($sw.Elapsed.TotalSeconds)

    # An interrupted suite has NO verdict: it was killed part way through, so its
    # pass/fail counts are meaningless. Deliberately skip the results.jsonl
    # record here - that file is what -Resume replays, and writing an ABORT into
    # it would make the resumed run treat a half-executed suite as done and
    # silently skip it forever.
    if ($result.Status -eq "ABORT") {
        $script:RunAborted = $true
        $script:NotRunCount = $totalSuites - $suiteIndex
        Write-Log "ABORT during [$suiteIndex/$totalSuites] $($testFile.BaseName); $script:NotRunCount further suites not run"
        break
    }

    # Crash-safe per-suite result record (also powers -Resume)
    $rec = @{ Name=$result.Name; Status=$result.Status; Passed=$result.Passed;
              Failed=$result.Failed; Duration=$result.Duration; ExitCode=$result.ExitCode } | ConvertTo-Json -Compress
    [System.IO.File]::AppendAllText($script:ResultsJsonl, "$rec`r`n")

    # Update live counters
    switch ($result.Status) {
        "PASS"    { $script:LivePass++ }
        "FAIL"    { $script:LiveFail++ }
        "TIMEOUT" { $script:LiveFail++ }
        "ERROR"   { $script:LiveFail++ }
        "SKIP"    { $script:LiveSkip++ }
    }
    $script:LivePassTests += $result.Passed
    $script:LiveFailTests += $result.Failed

    Show-ProgressDashboard -Current $suiteIndex -Total $totalSuites -SuiteName $testFile.BaseName -Status $result.Status
}

# ── Final cleanup ──
# Runs on the abort path too: this is what stops an interrupted run from leaving
# live psmux servers behind.
Clean-Server

# The flag has been consumed. Clear it so the next run is not aborted on its
# first poll by a stale file.
Remove-Item $script:StopFile -Force -ErrorAction SilentlyContinue

# ── Generate Report ──
$endTime = Get-Date
$totalDuration = ($endTime - $startTime).TotalSeconds

$bullet = [char]0x25CF  # ●

Write-Host "`n"
if ($script:RunAborted) {
    Write-Host ("=" * 80) -ForegroundColor Yellow
    Write-Host "  RUN INTERRUPTED ($script:AbortReason)" -ForegroundColor Yellow
    Write-Host ("  {0} suites did not run. Results below cover only what completed." -f $script:NotRunCount) -ForegroundColor Yellow
    Write-Host "  Resume where this left off:  tests\run_full_interactive.cmd -Resume" -ForegroundColor Yellow
    Write-Host ("=" * 80) -ForegroundColor Yellow
}
Write-Host ("=" * 80) -ForegroundColor White
Write-Host "  COMPREHENSIVE TEST REPORT" -ForegroundColor White
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host ("=" * 80) -ForegroundColor White

$passed = @($results | Where-Object { $_.Status -eq "PASS" })
$failed = @($results | Where-Object { $_.Status -in @("FAIL","ERROR","TIMEOUT") })
$skipped = @($results | Where-Object { $_.Status -eq "SKIP" })

$totalTests = 0; $totalPassed = 0; $totalFailed = 0
foreach ($r in $results) { $totalTests += ($r.Passed + $r.Failed); $totalPassed += $r.Passed; $totalFailed += $r.Failed }

# ── Suite & Test Counters ──
Write-Host ""
Write-Host "  SUITE SUMMARY" -ForegroundColor Cyan
Write-Host "  -------------------------------------------------------"
Write-Host ("  $bullet Suites PASSED:  {0}" -f $passed.Count) -ForegroundColor Green
Write-Host ("  $bullet Suites FAILED:  {0}" -f $failed.Count) -ForegroundColor $(if ($failed.Count -gt 0) { "Red" } else { "Green" })
Write-Host ("  $bullet Suites SKIPPED: {0}" -f $skipped.Count) -ForegroundColor Yellow
Write-Host ""
Write-Host "  INDIVIDUAL TEST SUMMARY" -ForegroundColor Cyan
Write-Host "  -------------------------------------------------------"
Write-Host ("  $bullet Tests PASSED:   {0}" -f $totalPassed) -ForegroundColor Green
Write-Host ("  $bullet Tests FAILED:   {0}" -f $totalFailed) -ForegroundColor $(if ($totalFailed -gt 0) { "Red" } else { "Green" })
Write-Host ("  $bullet Total Duration: {0:F1}s ({1:F1} min)" -f $totalDuration, ($totalDuration / 60))

# ── Category-Wise Breakdown ──
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor White
Write-Host "  CATEGORY BREAKDOWN" -ForegroundColor White
Write-Host ("=" * 80) -ForegroundColor White
Write-Host ""
Write-Host ("  {0,-16} {1,6} {2,6} {3,6} {4,10}" -f "Category", "Pass", "Fail", "Skip", "Time") -ForegroundColor White
Write-Host ("  " + ("-" * 50)) -ForegroundColor DarkGray

$catStats = @{}
foreach ($r in $results) {
    $cat = Get-Category $r.Name
    if (-not $catStats.ContainsKey($cat)) {
        $catStats[$cat] = @{ Pass=0; Fail=0; Skip=0; Time=[double]0 }
    }
    switch ($r.Status) {
        "PASS"    { $catStats[$cat].Pass++ }
        "FAIL"    { $catStats[$cat].Fail++ }
        "TIMEOUT" { $catStats[$cat].Fail++ }
        "ERROR"   { $catStats[$cat].Fail++ }
        "SKIP"    { $catStats[$cat].Skip++ }
    }
    $catStats[$cat].Time += $r.Duration
}

foreach ($kv in ($catStats.GetEnumerator() | Sort-Object { $_.Value.Fail } -Descending)) {
    $c = $kv.Value
    $catColor = if ($c.Fail -gt 0) { "Red" } elseif ($c.Skip -gt 0 -and $c.Pass -eq 0) { "Yellow" } else { "Green" }
    $timeFmt = if ($c.Time -ge 60) { "{0:F0}m{1:F0}s" -f [math]::Floor($c.Time/60),[math]::Floor($c.Time%60) } else { "{0:F1}s" -f $c.Time }
    Write-Host ("  {0,-16} {1,6} {2,6} {3,6} {4,10}" -f $kv.Key, $c.Pass, $c.Fail, $c.Skip, $timeFmt) -ForegroundColor $catColor
}

# ── Failures first, then passed, then skipped ──
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host ("  " + ("-" * 55)) -ForegroundColor Red
    Write-Host "  FAILED SUITES" -ForegroundColor Red
    foreach ($r in $failed) {
        Write-Host ("    $bullet [{0}] {1,-42} {2,3}P/{3}F  ({4}s)" -f $r.Status, $r.Name, $r.Passed, $r.Failed, $r.Duration) -ForegroundColor Red
    }
}

if ($passed.Count -gt 0) {
    Write-Host ""
    Write-Host "  PASSED SUITES" -ForegroundColor Green
    foreach ($r in $passed) {
        Write-Host ("    $bullet [PASS] {0,-42} {1,3}P/{2}F  ({3}s)" -f $r.Name, $r.Passed, $r.Failed, $r.Duration) -ForegroundColor Green
    }
}

if ($skipped.Count -gt 0) {
    Write-Host ""
    Write-Host "  SKIPPED SUITES" -ForegroundColor Yellow
    foreach ($r in $skipped) {
        Write-Host ("    $bullet [SKIP] {0,-42} {1}" -f $r.Name, $r.Reason) -ForegroundColor Yellow
    }
}

# ── Performance chart (top 15 slowest, visual bar) ──
Write-Host "`n"
Write-Host ("=" * 80) -ForegroundColor White
Write-Host "  PERFORMANCE METRICS (top 15 slowest suites)" -ForegroundColor White
Write-Host ("=" * 80) -ForegroundColor White
Write-Host ""
$perfResults = $results | Where-Object { $_.Status -ne "SKIP" } | Sort-Object { $_.Duration } -Descending | Select-Object -First 15
$maxDur = ($perfResults | Measure-Object -Property Duration -Maximum).Maximum
if ($maxDur -lt 1) { $maxDur = 1 }
$barBlock = [char]0x2588
foreach ($r in $perfResults) {
    $barLen = [math]::Max([math]::Round(($r.Duration / $maxDur) * 30), 1)
    $bar = $barBlock.ToString() * $barLen
    $color = if ($r.Status -eq "PASS") { "Green" } elseif ($r.Status -eq "FAIL") { "Red" } else { "Yellow" }
    Write-Host ("  {0,-42} {1,7:F1}s " -f $r.Name, $r.Duration) -ForegroundColor DarkGray -NoNewline
    Write-Host $bar -ForegroundColor $color
}

Write-Host "`n"
Write-Host ("=" * 80) -ForegroundColor White
# An interrupted run has no verdict. Reporting "ALL TESTS PASSED" here because
# nothing had failed yet at the moment of the abort would be a lie in the one
# place people grep for a result.
if ($script:RunAborted) {
    Write-Host "  RESULT: INTERRUPTED ($script:AbortReason) - $script:NotRunCount suites did not run" -ForegroundColor Yellow
    Write-Log "=== FINAL RESULT: INTERRUPTED ($script:AbortReason) - $script:NotRunCount of $totalSuites suites did not run ==="
} elseif ($totalFailed -gt 0 -or $failed.Count -gt 0) {
    Write-Host "  RESULT: FAILURES DETECTED ($totalFailed tests failed, $($failed.Count) suites failed/timed out)" -ForegroundColor Red
    Write-Log "=== FINAL RESULT: FAILURES DETECTED ($totalFailed tests failed across $($failed.Count) suites) ==="
} else {
    Write-Host "  RESULT: ALL TESTS PASSED ($totalPassed tests across $($passed.Count) suites)" -ForegroundColor Green
    Write-Log "=== FINAL RESULT: ALL TESTS PASSED ($totalPassed tests across $($passed.Count) suites) ==="
}

# ── Write comprehensive summary.log ──────────────────────────────
$summaryLines = [System.Collections.ArrayList]::new()
[void]$summaryLines.Add("psmux Test Run Summary")
[void]$summaryLines.Add("Run ID:   $script:RunId")
[void]$summaryLines.Add("Started:  $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))")
[void]$summaryLines.Add("Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$summaryLines.Add("Duration: $([math]::Round($totalDuration,1))s ($([math]::Round($totalDuration/60,1)) min)")
[void]$summaryLines.Add("Binary:   $PSMUX")
[void]$summaryLines.Add("Params:   SkipPerf=$SkipPerf IncludeWSL=$IncludeWSL IncludeInteractive=$IncludeInteractive")
[void]$summaryLines.Add("")
[void]$summaryLines.Add("Suites PASSED:  $($passed.Count)")
[void]$summaryLines.Add("Suites FAILED:  $($failed.Count)")
[void]$summaryLines.Add("Suites SKIPPED: $($skipped.Count)")
[void]$summaryLines.Add("Tests PASSED:   $totalPassed")
[void]$summaryLines.Add("Tests FAILED:   $totalFailed")
[void]$summaryLines.Add("")
[void]$summaryLines.Add("=" * 70)
foreach ($r in $results) {
    $line = "[{0,-5}] {1,-45} {2,3}P/{3}F  {4,7:F1}s" -f $r.Status, $r.Name, $r.Passed, $r.Failed, $r.Duration
    if ($r.Reason) { $line += "  ($($r.Reason))" }
    [void]$summaryLines.Add($line)
}
[void]$summaryLines.Add("=" * 70)
if ($script:RunAborted) {
    [void]$summaryLines.Add("RESULT: INTERRUPTED ($script:AbortReason) - $script:NotRunCount suites did not run")
    [void]$summaryLines.Add("Resume with: tests\run_full_interactive.cmd -Resume")
} elseif ($totalFailed -gt 0 -or $failed.Count -gt 0) {
    [void]$summaryLines.Add("RESULT: FAILURES DETECTED")
} else {
    [void]$summaryLines.Add("RESULT: ALL TESTS PASSED")
}
[System.IO.File]::WriteAllText($script:SummaryLog, ($summaryLines -join "`r`n"), [System.Text.Encoding]::UTF8)

Write-Log "Summary written to: $script:SummaryLog"
Write-Log "Suite logs in:      $script:SuiteDir"
Write-Log "=== Run finished ==="

Write-Host ""
Write-Host "  Logs saved to: $script:RunDir" -ForegroundColor Cyan

# 130 is the conventional "terminated by SIGINT" code. It is deliberately NOT 1:
# an interrupted run has no verdict, and reporting it as a failure would make an
# aborted sweep look like a red one in any wrapper that keys off the exit code.
if ($script:RunAborted) {
    Write-Host ""
    Write-Host "  RUN INTERRUPTED - $script:NotRunCount suites did not run." -ForegroundColor Yellow
    Write-Host "  Resume with: tests\run_full_interactive.cmd -Resume" -ForegroundColor Yellow
    exit 130
} elseif ($totalFailed -gt 0 -or $failed.Count -gt 0) {
    exit 1
} else {
    exit 0
}
