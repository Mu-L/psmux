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
#   ConPTY tax. Measured hop by hop with PSMUX_STARTUP_TRACE, n=14 medians on a
#   32 core box that was busy with other builds at the time (so the absolute
#   numbers are high; the SHARES are what this list is for):
#     ~16ms  client argv parse, warm claim attempt, server spawn call
#     ~51ms  the server process (psmux.exe again) loading to main
#      ~2ms  panic hook, AppState, priority, the single-server mutex
#      ~2ms  TcpListener::bind
#     ~23ms  the session registry: .key .sid .pid, the namespace instance
#            token, the server marker, .port - six small files, several ms
#            apiece with realtime AV scanning, and their ORDER is load bearing
#            (#496, #509) so they are not free to move off the critical path
#      ~8ms  CreatePseudoConsole
#    ~173ms  CreateProcessW into the pseudoconsole. This is the console connect
#            handshake with conhost, not psmux code, and it is the single
#            largest hop; the warm pane pool exists because of it, which is why
#            a SPLIT is ~25ms and a cold new-session is not
#    ~540ms  pwsh's own init, which is slower through ConPTY than in a console
#   psmux therefore owns roughly 100ms of a cold launch (two exe loads plus the
#   registry); everything else is the shell and the operating system. The
#   gate is set at 400ms: the measured ceiling plus room for a loaded machine
#   (these suites run alongside others) and for the warm pane / warm server
#   that psmux spawns during startup, which costs a further ~40-100ms of CPU
#   contention. A regression that reintroduces a whole shell start is ~280ms
#   and lands well outside it.
#
# MEMORY AND CPU
#   A launch number on its own cannot tell a build that got there faster from a
#   build that got there by burning the machine, so the last psmux iteration is
#   also sampled: the working set, private bytes, CPU and thread count of the
#   server and of the attached client at the moment the pane's shell reached its
#   prompt, and then a quiet window with nothing driving the session, reported as
#   a percentage of one core. Same helpers and same field names as the creation
#   and keystroke gates (tests\perf_metrics_common.ps1), so a row from this file
#   lines up with a row from those. The server is found by its <ns>__<session>.pid
#   anchor, never by image name: this machine routinely has a dozen psmux servers
#   belonging to other sessions, and a warm standby shares this binary and this
#   namespace.
#
# Samples are written to %USERPROFILE%\.psmux-test-data\metrics\, never the repo.

param(
    [string]$Binary = "",
    [int]$N = 5,
    [int]$MaxDeltaMs = 400,
    # The quiet window used for the idle CPU sample on the last iteration.
    [int]$IdleSeconds = 3
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

function Measure-Psmux([int]$i, [switch]$Sample) {
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
    # The resource sample is taken here, with the pane's shell at its prompt and
    # the client still attached, and only on the iteration that asked for it, so
    # the timing samples are never charged for the sampling. A failed launch is
    # not sampled: there is no prompt to sample at.
    if ($Sample -and $m) {
        $srv = Get-PerfServerPid -Ns $ns -Session $sess
        $roles = [ordered]@{}
        if ($srv -gt 0) { $roles["server"] = $srv }
        $cliPid = Get-PerfClientPid -Binary $Binary -Ns $ns -ServerPid $srv
        if ($cliPid -le 0 -and $p -and -not $p.HasExited) { $cliPid = $p.Id }
        if ($cliPid -gt 0) { $roles["client"] = $cliPid }
        if ($roles.Count -gt 0) {
            $atPrompt = Get-PerfResourceSnapshot $roles
            $idle = Measure-PerfIdleCpu $roles $IdleSeconds
            $script:ResourceBlock = [ordered]@{
                iteration             = $i
                idle_window_seconds   = $IdleSeconds
                at_prompt             = (Get-PerfMemorySummary $atPrompt)
                idle_cpu_pct_of_core  = $idle.pct_of_one_core
                idle_measured_over_ms = $idle.window_ms
            }
            Write-Info (Format-PerfResourceLine $atPrompt "at prompt  ")
            Write-Info ("idle cpu, % of a core : " + (@($idle.pct_of_one_core.Keys | ForEach-Object { "{0} {1:F2}%" -f $_, $idle.pct_of_one_core[$_] }) -join "  "))
        } else {
            Write-Info "neither the server nor the client could be identified, so no resource sample was taken"
        }
    }
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

$script:ResourceBlock = $null
$bare = @(); $mux = @()
for ($i = 1; $i -le $N; $i++) {
    $b = Measure-Bare $i
    if ($null -eq $b) { $b = Measure-Bare $i }      # one retry: a shell that
    # Only the last iteration is sampled for memory and CPU, and the sampling
    # happens after its own stopwatch has stopped, so no timing sample pays for it.
    $sample = ($i -eq $N)
    $m = Measure-Psmux $i -Sample:$sample           # never reached its prompt
    if ($null -eq $m) { $m = Measure-Psmux $i -Sample:$sample }   # is a flake, not a datum
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
    resources    = $script:ResourceBlock
})
if ($jsonPath) { Write-Info "samples: $jsonPath" }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Passed: $script:TestsPassed  Failed: $script:TestsFailed  Skipped: $script:TestsSkipped"
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
