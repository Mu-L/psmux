# test_launch_to_prompt_gate.ps1: launch to usable prompt, psmux vs bare pwsh
#
# WHAT IT MEASURES
#   The only startup number a user feels: how long after launching until the
#   pane's shell is sitting at its first prompt. The shell itself writes the
#   finish line. marker.ps1 stamps QueryPerformanceCounter (system wide on
#   Windows, so it is directly comparable to the harness's Stopwatch) into a
#   file as the last thing it does before -NoExit drops it to a prompt. The
#   start line is a Stopwatch stamp taken immediately before Start-Process.
#
#   Two arms, interleaved so machine drift hits both equally:
#     bare   pwsh -NoLogo -NoProfile -NoExit -File marker.ps1 <out>
#     psmux  psmux -L <ns> new-session -s <n> <that same command line>
#
# WHY IT EXISTS
#   psmux used to route every multi-word pane command through
#   `<default-shell> -Command "<cmd>"`. On Windows the default shell is pwsh,
#   so that wrapper was a SECOND full PowerShell start (and, lacking
#   -NoProfile, it also sourced the user's profile the inner -NoProfile had
#   asked to skip): a measured 278ms of launch latency on top of a gap that was
#   already ~250ms. try_direct_spawn now execs a bare program name with
#   arguments directly, which is also what tmux does with a multi-argument
#   shell-command. This gate keeps that wrapper from coming back.
#
# THE MARGIN
#   What is left after the fix is psmux's irreducible cold-start work plus the
#   ConPTY tax, measured hop by hop with PSMUX_STARTUP_TRACE:
#     ~11ms  client argv parse and server spawn call
#     ~34ms  the server process (psmux.exe again) loading to main
#     ~25ms  session mutex, control listener bind, .key/.port/.sid writes
#     ~6ms   CreatePseudoConsole
#     ~114ms CreateProcess into the pseudoconsole (10ms without ConPTY)
#     ~68ms  the shell's own init is slower through ConPTY than a console
#   That sums to ~258ms and matches an end-to-end median delta of ~250ms. The
#   gate is set at 400ms: the measured ceiling plus room for a loaded machine
#   (these suites run alongside others) and for the warm pane / warm server
#   that psmux spawns during startup, which costs a further ~40-100ms of CPU
#   contention. A regression that reintroduces a whole shell start is ~280ms
#   and lands well outside it.
#
# Samples are written to %USERPROFILE%\.psmux-test-data\metrics\, never the repo.

param(
    [string]$Binary = "",
    [int]$N = 5,
    [int]$MaxDeltaMs = 400
)

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\perf_metrics_common.ps1"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0
function Write-Pass { param($msg) Write-Host "[PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip { param($msg) Write-Host "[SKIP] $msg" -ForegroundColor Yellow; $script:TestsSkipped++ }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Perf { param($msg) Write-Host "[PERF] $msg" -ForegroundColor Magenta }

if (-not $Binary -and $env:PSMUX_TEST_BIN) { $Binary = $env:PSMUX_TEST_BIN }
if (-not $Binary -and $env:PSMUX_TEST_BINARY) { $Binary = $env:PSMUX_TEST_BINARY }
if (-not $Binary) {
    $local = "$PSScriptRoot\..\target\release\psmux.exe"
    if (Test-Path $local) { $Binary = (Resolve-Path $local).Path }
    else {
        $cmd = Get-Command psmux -ErrorAction SilentlyContinue
        if ($cmd) { $Binary = $cmd.Source }
    }
}
if (-not $Binary -or -not (Test-Path $Binary)) {
    Write-Error "psmux binary not found. Pass -Binary <path> or run: cargo build --release"
    exit 1
}

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshCmd) {
    Write-Skip "pwsh (PowerShell 7) not installed, so the bare arm has nothing to compare against"
    Write-Host ""
    Write-Host "Passed: 0  Failed: 0  Skipped: 1"
    exit 0
}

# Isolated socket namespace so this never touches a real session.
$ns = "ltpgate$PID"
$work = Join-Path ([System.IO.Path]::GetTempPath()) "psmux_ltp_$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$marker = Join-Path $work 'marker.ps1'
@'
param([string]$Out)
$qpc = [System.Diagnostics.Stopwatch]::GetTimestamp()
[System.IO.File]::WriteAllText($Out, "$qpc $PID")
'@ | Set-Content -LiteralPath $marker -Encoding ascii

$freq = [System.Diagnostics.Stopwatch]::Frequency
Write-Info "Using: $Binary"
Write-Info "Namespace: $ns   iterations: $N   gate: psmux median <= bare median + $MaxDeltaMs ms"

function Stop-OnePid([int]$procId) {
    if ($procId -gt 0) { try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch { } }
}

function Wait-Marker([string]$path, [int]$timeoutMs = 30000) {
    $w = [System.Diagnostics.Stopwatch]::StartNew()
    while ($w.ElapsedMilliseconds -lt $timeoutMs) {
        if (Test-Path $path) {
            try {
                $txt = [System.IO.File]::ReadAllText($path)
                $parts = $txt.Trim() -split '\s+'
                if ($parts.Count -ge 2) { return @([int64]$parts[0], [int]$parts[1]) }
            } catch { }
        }
        Start-Sleep -Milliseconds 2
    }
    return $null
}

function Measure-Bare([int]$i) {
    $out = Join-Path $work "bare_$i.txt"
    if (Test-Path $out) { Remove-Item -LiteralPath $out -Force }
    $t0 = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $p = Start-Process -FilePath $pwshCmd.Source `
         -ArgumentList @('-NoLogo','-NoProfile','-NoExit','-File',$marker,$out) -PassThru
    $m = Wait-Marker $out
    $ms = $null
    if ($m) { $ms = [math]::Round((($m[0] - $t0) / $freq) * 1000, 1); Stop-OnePid $m[1] }
    Stop-OnePid $p.Id
    return $ms
}

function Measure-Psmux([int]$i) {
    $out = Join-Path $work "psmux_$i.txt"
    if (Test-Path $out) { Remove-Item -LiteralPath $out -Force }
    $sess = "g$i"
    $argv = @('-L',$ns,'new-session','-s',$sess,
              'pwsh','-NoLogo','-NoProfile','-NoExit','-File',$marker,$out)
    $t0 = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $p = Start-Process -FilePath $Binary -ArgumentList $argv -PassThru
    $m = Wait-Marker $out
    $ms = $null
    if ($m) { $ms = [math]::Round((($m[0] - $t0) / $freq) * 1000, 1) }
    # Namespace-scoped teardown: never a kill by image name (other psmux
    # servers, including the user's own sessions, must not be touched).
    & $Binary -L $ns kill-server 2>$null | Out-Null
    Start-Sleep -Milliseconds 150
    if ($m) { Stop-OnePid $m[1] }
    Stop-OnePid $p.Id
    return $ms
}

function Median($a) {
    $v = @($a | Where-Object { $null -ne $_ } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    if ($v.Count % 2 -eq 1) { return $v[[int](($v.Count - 1) / 2)] }
    return [math]::Round(($v[$v.Count / 2 - 1] + $v[$v.Count / 2]) / 2, 1)
}

& $Binary -L $ns kill-server 2>$null | Out-Null

$bare = @(); $mux = @()
for ($i = 1; $i -le $N; $i++) {
    $b = Measure-Bare $i
    if ($null -eq $b) { $b = Measure-Bare $i }      # one retry: a shell that
    $m = Measure-Psmux $i                           # never reached its prompt
    if ($null -eq $m) { $m = Measure-Psmux $i }     # is a flake, not a datum
    $bare += $b; $mux += $m
    Write-Host ("       iter {0}: bare {1} ms | psmux {2} ms" -f $i, $b, $m)
}
& $Binary -L $ns kill-server 2>$null | Out-Null

$bareMed = Median $bare
$muxMed  = Median $mux

if ($null -eq $bareMed -or $null -eq $muxMed) {
    Write-Fail "launch to prompt: a shell never reached its prompt (bare=$($bare -join ',') psmux=$($mux -join ','))"
} else {
    $delta = [math]::Round($muxMed - $bareMed, 1)
    $bareStats = Get-PerfStats $bare 1
    $muxStats  = Get-PerfStats $mux 1
    Write-Perf ("bare  median: {0} ms  (p90 {1}, max {2})" -f $bareMed, $bareStats.p90, $bareStats.max)
    Write-Perf ("psmux median: {0} ms  (p90 {1}, max {2})" -f $muxMed, $muxStats.p90, $muxStats.max)
    Write-Perf ("delta       : {0} ms (gate {1} ms)" -f $delta, $MaxDeltaMs)
    if ($delta -le $MaxDeltaMs) {
        Write-Pass "launch to prompt: psmux adds $delta ms over bare pwsh (<= $MaxDeltaMs ms)"
    } else {
        Write-Fail "launch to prompt: psmux adds $delta ms over bare pwsh (> $MaxDeltaMs ms)  a shell wrapper around the pane command is the usual cause"
    }
}

# Samples land outside the repo, under the shared test-data root, carrying the
# shared envelope (git sha of the binary's tree, machine, CPU) so a run can be
# lined up against another run of another build. The median fields are kept as
# they were so files written before the envelope landed still compare; the
# percentile blocks are the new part, and they are what tests/perf_summary.ps1
# reads.
$jsonPath = Write-PerfMetrics -Suite "test_launch_to_prompt_gate" -Binary $Binary -FileStem "launch-to-prompt" -Data ([ordered]@{
    iterations   = $N
    gate_ms      = $MaxDeltaMs
    bare_ms      = $bare
    psmux_ms     = $mux
    bare_median  = $bareMed
    psmux_median = $muxMed
    bare_stats   = (Get-PerfStats $bare 1)
    psmux_stats  = (Get-PerfStats $mux 1)
    delta_ms     = $(if ($null -ne $bareMed -and $null -ne $muxMed) { [math]::Round($muxMed - $bareMed, 1) } else { $null })
})
if ($jsonPath) { Write-Info "samples: $jsonPath" }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Passed: $script:TestsPassed  Failed: $script:TestsFailed  Skipped: $script:TestsSkipped"
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
