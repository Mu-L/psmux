# test_creation_latency_gate.ps1 - the regression gate on how long it takes to
# get a usable pane.
#
# WHAT THIS PINS
#
# Creating a window or a split used to be bimodal: about 15ms when a spare shell
# was claimed and 470 to 630ms when the spare pool had been drained and not yet
# refilled. Measured on master (8615957), ten back to back `new-window` calls
# came out
#
#   15, 470, 15, 476, 31, 488, 15, 520, 31, 504 ms
#
# which averages to a forgettable 257ms and feels like a stutter every other
# time you press the key. An average hides that completely, so this gate asserts
# the SHAPE of the distribution, not its centre: HOW MANY of the ten creations
# are slow (see $SlowBudget), with p90 and max as backstops.
#
# WHY IT IS MEASURED THIS WAY
#
#   - "Ready" means a PROMPT IS VISIBLE in the new pane, not that the command
#     returned. `new-window` returns in well under a millisecond while the pane
#     behind it can still be blank for half a second; timing the command would
#     score the defect as perfect.
#   - Readiness also requires THE ACTIVE PANE ID TO HAVE CHANGED. A split that
#     is refused for lack of room leaves the old pane active with its prompt
#     already on screen, so a prompt match on its own would record a refusal as
#     a 16ms creation. Every sample here is proof a pane was really created.
#   - Commands and polls go over one short lived TCP connection each (~1ms round
#     trip) rather than through the CLI (~30ms of process spawn per poll), so
#     the numbers are the server's behaviour and not the client's.
#   - Splits kill the pane they just created before the next one, because a
#     30 row window has room for only three vertical splits and every later one
#     would be refused.
#
# Runs in its own `-L` namespace and kills only that namespace, so it cannot
# disturb sessions the developer is using.
param(
    # Defaults to this checkout's target\release build, then PSMUX_TEST_BIN,
    # then the psmux on PATH. Point it at a build to compare two of them. The
    # name must stay one the server recognises as its own image
    # (psmux / pmux / tmux): session.rs gates the warm server claim on it, so a
    # differently named copy silently loses the fast path and the run would be
    # measuring the rename.
    [string]$Binary = "",
    [int]$Count = 10,
    [int]$SettleMs = 2000,
    # What counts as a creation the user notices, and how many of ten are allowed
    # to be one.
    #
    # Two, not one, and counted rather than read off p90. A run of ten rapid
    # creations cannot all be instant: the pool holds `warm-pool-size` settled
    # spares, and everything past them is served by shells that were all started
    # at about the same moment and therefore mature in a staircase. Measured here,
    # that is one creation waiting out most of a shell startup (~470 ms) and one
    # waiting out part of another (~150 ms), with the remaining eight at 14 to
    # 30 ms.
    #
    # p90 over ten samples is the SECOND WORST, so it fails on that second,
    # partial wait and says nothing about the eight instant ones: it read 132 to
    # 159 ms against a 150 ms budget on identical behaviour, passing or failing on
    # noise. The count is the statistic that matches what a user feels, and it
    # still rejects the defect this gate exists for: before the spare pool, ten
    # new-windows were [27, 416, 15, 396, 14, 412, 15, 428, 15, 457], five slow of
    # ten, and split-window was eight of ten.
    [int]$SlowMs = 150,
    [int]$SlowBudget = 2,
    # Kept as a backstop on how bad that second wait may get.
    [int]$P90LimitMs = 300,
    # max only catches a blow-up. The floor for one creation in a run of ten is
    # a whole shell startup, because no pool can produce a booted shell faster
    # than a shell boots, and a pwsh cold start measures 600 to 900ms on this
    # machine. A budget at 800ms flaked on exactly that; 1500ms is above the
    # floor with headroom and still far below anything pathological.
    [int]$MaxLimitMs = 1500,
    [int]$PollMs = 10,
    # The resource cell: how many windows and splits are stacked up before the
    # second memory sample is taken, and how long the quiet windows are.
    [int]$ResourceWindows = 20,
    [int]$ResourceSplits = 3,
    [int]$IdleSeconds = 3,
    [switch]$SkipResources,
    [string]$MetricsDir = ""
)

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\perf_metrics_common.ps1"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass { param($msg) Write-Host "[PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Test { param($msg) Write-Host "[TEST] $msg" -ForegroundColor White }
function Write-Perf { param($msg) Write-Host "[PERF] $msg" -ForegroundColor Magenta }

# ── binary ────────────────────────────────────────────────────────────────
# The BUILD IN THE TREE comes first, ahead of the installed copy on PATH.
# run_all_tests.ps1 announces target\release\psmux.exe as the binary under test,
# and a gate that quietly timed the installed psmux instead would report a green
# sweep for a build nobody measured. -Binary or PSMUX_TEST_BINARY override,
# which is how two builds are compared against each other.
if (-not $Binary -and $env:PSMUX_TEST_BIN) { $Binary = $env:PSMUX_TEST_BIN }
if (-not $Binary -and $env:PSMUX_TEST_BINARY) { $Binary = $env:PSMUX_TEST_BINARY }
if (-not $Binary) {
    foreach ($n in @("psmux.exe", "pmux.exe", "tmux.exe")) {
        $c = Join-Path $PSScriptRoot "..\target\release\$n"
        if (Test-Path $c) { $Binary = $c; break }
    }
}
if (-not $Binary) {
    $cmd = Get-Command psmux -ErrorAction SilentlyContinue
    if ($cmd) { $Binary = $cmd.Source }
}
if (-not $Binary -or -not (Test-Path $Binary)) {
    Write-Fail "no psmux binary found (not on PATH, nothing in target\release)"
    Write-Host "`nTests passed: 0, failed: 1"
    exit 1
}
$Binary = (Resolve-Path $Binary).Path
$imgName = [IO.Path]::GetFileNameWithoutExtension($Binary).ToLower()
if ($imgName -notin @("psmux", "pmux", "tmux")) {
    Write-Fail "'$imgName' is not a recognised server image name; the warm server claim would be off and every timing here would be wrong"
    Write-Host "`nTests passed: 0, failed: 1"
    exit 1
}
Write-Info "Using: $Binary"

$DataDir = if ($env:PSMUX_DATA_DIR) { $env:PSMUX_DATA_DIR.TrimEnd('\', '/') } else { "$env:USERPROFILE\.psmux" }
if (-not $MetricsDir) { $MetricsDir = "$env:USERPROFILE\.psmux-test-data\metrics" }
# Routing env vars would retarget every command at whatever session happens to
# host the shell this suite was started from.
$env:PSMUX_SESSION_NAME = $null
$env:PSMUX_SESSION = $null

$Ns = "clg$PID"
$Sess = "gate"
$PromptRe = 'PS [A-Z]:\\'

function Remove-Namespace {
    try { & $Binary -L $Ns kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 400
    Get-ChildItem "$DataDir\$($Ns)__*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

# One authenticated round trip. Returns @{ ok; lines }: a hashtable and never a
# bare collection, because PowerShell unrolls an empty collection to $null and
# `new-window` answers with no output at all.
function Invoke-Psmux {
    param([int]$Port, [string]$Key, [string]$Cmd)
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.NoDelay = $true
    try {
        $tcp.Connect("127.0.0.1", $Port)
        $st = $tcp.GetStream(); $st.ReadTimeout = 20000
        $wr = New-Object System.IO.StreamWriter($st); $wr.AutoFlush = $false
        $rd = New-Object System.IO.StreamReader($st)
        $wr.WriteLine("AUTH $Key"); $wr.Flush()
        if ($rd.ReadLine() -ne "OK") { return @{ ok = $false; lines = @() } }
        $wr.WriteLine("TARGET $Sess")
        $wr.WriteLine($Cmd)
        $wr.Flush()
        $acc = New-Object System.Collections.Generic.List[string]
        while ($true) {
            $l = $rd.ReadLine()
            if ($null -eq $l -or $l -eq "") { break }
            $acc.Add($l)
        }
        return @{ ok = $true; lines = $acc.ToArray() }
    } catch {
        return @{ ok = $false; lines = @() }
    } finally { $tcp.Close() }
}

function Get-Text { param($r) if ($null -eq $r -or -not $r.ok) { return "" } return ($r.lines -join "`n") }

function Wait-Registered {
    param([int]$TimeoutMs = 20000)
    $pf = "$DataDir\$($Ns)__$Sess.port"
    $kf = "$DataDir\$($Ns)__$Sess.key"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Test-Path $pf) -and (Test-Path $kf)) {
            try {
                $p = [int](Get-Content $pf -Raw).Trim()
                $k = (Get-Content $kf -Raw).Trim()
                if ($p -gt 0 -and $k.Length -gt 0) { return @{ Port = $p; Key = $k } }
            } catch {}
        }
        Start-Sleep -Milliseconds 10
    }
    return $null
}

function Get-ActivePaneId {
    param([int]$Port, [string]$Key)
    (Get-Text (Invoke-Psmux $Port $Key "display-message -p '#{pane_id}'")).Trim().Trim("'")
}

function Wait-FirstPrompt {
    param([int]$Port, [string]$Key, [int]$TimeoutMs = 25000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Get-Text (Invoke-Psmux $Port $Key "capture-pane -p")) -match $PromptRe) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

# Issue one creation and return ms until the NEW pane shows a prompt, or -1.
function Measure-Creation {
    param([int]$Port, [string]$Key, [string]$Cmd, [string]$OldId, [int]$TimeoutMs = 25000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Psmux $Port $Key $Cmd
    if (-not $r.ok) { return -1 }
    $msg = ($r.lines -join " ")
    if ($msg -match 'too small|no space|error|unknown command') {
        Write-Info "  creation refused: $msg"
        return -1
    }
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $id = Get-ActivePaneId $Port $Key
        if ($id -and $id -ne $OldId) {
            if ((Get-Text (Invoke-Psmux $Port $Key "capture-pane -p -t $id")) -match $PromptRe) {
                return $sw.Elapsed.TotalMilliseconds
            }
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return -1
}

# ── the gate ──────────────────────────────────────────────────────────────
$allSamples = [ordered]@{}

function Test-Cell {
    param([string]$Label, [string]$Cmd, [switch]$KillAfter)
    Write-Test "$Label x$Count back to back after a ${SettleMs}ms settle"
    Remove-Namespace
    Start-Process -FilePath $Binary -ArgumentList "-L", $Ns, "new-session", "-d", "-s", $Sess -WindowStyle Hidden | Out-Null
    $inf = Wait-Registered
    if ($null -eq $inf) {
        Write-Fail "$Label - the test session never registered"
        $allSamples[$Label] = @()
        return
    }
    if (-not (Wait-FirstPrompt $inf.Port $inf.Key)) {
        Write-Fail "$Label - the test session's first pane never reached a prompt"
        $allSamples[$Label] = @()
        Remove-Namespace
        return
    }
    # Settle: let the spare pool fill AND let those shells finish starting. A
    # spare is worth nothing until its prompt is up.
    Start-Sleep -Milliseconds $SettleMs

    $t = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $old = Get-ActivePaneId $inf.Port $inf.Key
        $ms = Measure-Creation $inf.Port $inf.Key $Cmd $old
        if ($ms -ge 0) { $t += $ms } else { Write-Info "  creation $($i + 1) produced no pane" }
        if ($KillAfter) {
            # Keep room in the window: a 30 row pane allows only three vertical
            # splits, and every later one would be refused rather than slow.
            Invoke-Psmux $inf.Port $inf.Key "kill-pane" | Out-Null
            Start-Sleep -Milliseconds 120
        }
    }
    $allSamples[$Label] = @($t | ForEach-Object { [math]::Round($_, 1) })
    Remove-Namespace

    if ($t.Count -lt $Count) {
        Write-Fail "$Label - only $($t.Count) of $Count creations produced a pane"
        return
    }
    $s = @($t | Sort-Object)
    $median = $s[[int][Math]::Floor(($s.Count - 1) / 2)]
    $p90 = $s[[Math]::Min($s.Count - 1, [int][Math]::Ceiling(0.9 * $s.Count) - 1)]
    $max = $s[-1]
    $slow = @($t | Where-Object { $_ -gt $SlowMs }).Count
    $list = (($t | ForEach-Object { [int]$_ }) -join ', ')
    Write-Perf ("{0,-18} med={1,6:N0} p90={2,6:N0} max={3,6:N0} ms  slow={4}/{5}  [{6}]" -f $Label, $median, $p90, $max, $slow, $t.Count, $list)

    # HOW MANY creations are slow, which is the thing the user feels, and not the
    # 2nd worst of ten. See $SlowBudget for why p90 alone was the wrong statistic.
    if ($slow -le $SlowBudget) {
        Write-Pass ("$Label {0} of {1} creations over {2}ms (budget {3})" -f $slow, $t.Count, $SlowMs, $SlowBudget)
    } else {
        Write-Fail ("$Label {0} of {1} creations over {2}ms, budget {3} - creations are waiting out a shell startup  [{4}]" -f $slow, $t.Count, $SlowMs, $SlowBudget, $list)
    }
    if ($p90 -le $P90LimitMs) {
        Write-Pass ("$Label p90 {0:N0}ms is within {1}ms" -f $p90, $P90LimitMs)
    } else {
        Write-Fail ("$Label p90 {0:N0}ms exceeds {1}ms  [{2}]" -f $p90, $P90LimitMs, $list)
    }
    if ($max -le $MaxLimitMs) {
        Write-Pass ("$Label max {0:N0}ms is within {1}ms" -f $max, $MaxLimitMs)
    } else {
        Write-Fail ("$Label max {0:N0}ms exceeds {1}ms  [{2}]" -f $max, $MaxLimitMs, $list)
    }
}

# ── memory and CPU, the cost of holding a session open ────────────────────
#
# The latency cells above run DETACHED, so they have a server and no client.
# This cell attaches one, because "what does psmux cost" is a question about
# both processes, and takes four samples:
#
#   at prompt            one window, one pane, prompt up, nothing typed
#   idle after prompt    CPU over a quiet window, as a percentage of ONE core.
#                        This is the busy polling detector: a 1 ms sleep loop
#                        that Windows rounds up to a 15.6 ms timer tick is
#                        invisible in every latency number and obvious here.
#   after N windows      working set and private bytes once $ResourceWindows
#                        windows and $ResourceSplits splits are stacked up, ie
#                        what a real working session costs, plus the CPU those
#                        creations consumed
#   idle after N windows the same quiet window again, with everything open. A
#                        per pane poll shows up as a number that grew with the
#                        pane count while the first idle sample looked fine.
#
# RECORDED, NOT GATED. The thresholds on these numbers live in
# test_perf_vs_terminals (T6 memory, T7 idle CPU, T8 keystroke CPU); inventing a
# second set here would mean two places to argue with. The one assertion is that
# the section produced data, because a JSON full of nulls that still says PASS
# is worse than a failure.
$script:ResourceBlock = $null

function Test-Resources {
    Write-Test "memory and CPU of the server and an attached client"
    Remove-Namespace
    $client = $null
    try {
        $client = Start-Process -FilePath $Binary -ArgumentList "-L", $Ns, "new-session", "-s", $Sess -PassThru
    } catch {
        Write-Fail "resources - could not launch an attached client: $_"
        return
    }
    try {
        $inf = Wait-Registered
        if ($null -eq $inf) { Write-Fail "resources - the session never registered"; return }
        if (-not (Wait-FirstPrompt $inf.Port $inf.Key)) { Write-Fail "resources - the first pane never reached a prompt"; return }
        Start-Sleep -Milliseconds $SettleMs

        $srv = Get-PerfServerPid -Ns $Ns -Session $Sess -DataDir $DataDir
        $roles = [ordered]@{}
        if ($srv -gt 0) { $roles["server"] = $srv }
        if ($client -and -not $client.HasExited) { $roles["client"] = $client.Id }
        if ($roles.Count -eq 0) {
            Write-Fail "resources - neither the server nor the client could be identified, so nothing was sampled"
            return
        }

        $atPrompt = Get-PerfResourceSnapshot $roles
        Write-Info (Format-PerfResourceLine $atPrompt "at prompt      ")
        $idle1 = Measure-PerfIdleCpu $roles $IdleSeconds

        # A wall clock budget on the whole fill, so a machine that has gone slow
        # cannot turn this section into a suite timeout. Whatever was opened by
        # the time the budget runs out is what gets measured, and the count is
        # recorded, so the sample is still honest.
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $budgetMs = 120000
        $made = 0
        for ($i = 0; $i -lt $ResourceWindows -and $sw.ElapsedMilliseconds -lt $budgetMs; $i++) {
            $old = Get-ActivePaneId $inf.Port $inf.Key
            if ((Measure-Creation $inf.Port $inf.Key "new-window" $old) -ge 0) { $made++ }
        }
        for ($i = 0; $i -lt $ResourceSplits -and $sw.ElapsedMilliseconds -lt $budgetMs; $i++) {
            $old = Get-ActivePaneId $inf.Port $inf.Key
            if ((Measure-Creation $inf.Port $inf.Key "split-window -v" $old) -ge 0) { $made++ }
        }
        $sw.Stop()
        $afterOpen = Get-PerfResourceSnapshot $roles
        Write-Info (Format-PerfResourceLine $afterOpen ("after {0} panes " -f $made))
        $openCpu = Get-PerfCpuDelta $atPrompt $afterOpen ([double][Math]::Max($made, 1)) 1.0
        $idle2 = Measure-PerfIdleCpu $roles $IdleSeconds
        Write-Info ("idle cpu at one pane  : " + (@($idle1.pct_of_one_core.Keys | ForEach-Object { "{0} {1:F2}%" -f $_, $idle1.pct_of_one_core[$_] }) -join "  "))
        Write-Info ("idle cpu at $made panes: " + (@($idle2.pct_of_one_core.Keys | ForEach-Object { "{0} {1:F2}%" -f $_, $idle2.pct_of_one_core[$_] }) -join "  "))

        $script:ResourceBlock = [ordered]@{
            panes_opened            = $made
            windows_requested       = $ResourceWindows
            splits_requested        = $ResourceSplits
            open_elapsed_ms         = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
            idle_window_seconds     = $IdleSeconds
            at_prompt               = (Get-PerfMemorySummary $atPrompt)
            after_panes             = (Get-PerfMemorySummary $afterOpen)
            cpu_ms_per_creation     = $openCpu
            idle_cpu_pct_one_pane   = $idle1.pct_of_one_core
            idle_cpu_pct_many_panes = $idle2.pct_of_one_core
        }
        $srvWs = if ($atPrompt.Contains("server")) { $atPrompt.server.ws_mb } else { 0 }
        $srvWs2 = if ($afterOpen.Contains("server")) { $afterOpen.server.ws_mb } else { 0 }
        Write-Perf ("{0,-18} server ws {1} -> {2} MB over {3} panes" -f "resources", $srvWs, $srvWs2, $made)
        Write-Pass ("memory and CPU collected for the server and the client, one pane and $made panes")
    } finally {
        Remove-Namespace
        try { if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue } } catch { }
        Start-Sleep -Milliseconds 300
    }
}

Write-Host ""
Write-Host ("=" * 76)
Write-Host " Creation latency gate - time to a VISIBLE PROMPT, $Count back to back"
Write-Host (" at most {0} of {1} creations over {2}ms; p90 budget {3}ms, max budget {4}ms" -f $SlowBudget, $Count, $SlowMs, $P90LimitMs, $MaxLimitMs)
Write-Host ("=" * 76)

Test-Cell -Label "new-window"      -Cmd "new-window"
Test-Cell -Label "split-window -v" -Cmd "split-window -v" -KillAfter
Test-Cell -Label "split-window -h" -Cmd "split-window -h" -KillAfter
if (-not $SkipResources) { Test-Resources }

# ── samples on disk, never in the repo ────────────────────────────────────
# Percentiles are computed here rather than left to the reader: p50 and p90 per
# cell are what tests/perf_summary.ps1 plots, and the raw samples stay alongside
# them so a suspicious percentile can always be checked against the run it came
# from.
$stats = [ordered]@{}
foreach ($k in @($allSamples.Keys)) { $stats[$k] = (Get-PerfStats $allSamples[$k] 1) }
$outFile = Write-PerfMetrics -Suite "test_creation_latency_gate" -Binary $Binary `
    -FileStem "creation_latency_gate" -MetricsDir $MetricsDir -Data ([ordered]@{
    count = $Count
    settle_ms = $SettleMs
    slow_ms = $SlowMs
    slow_budget = $SlowBudget
    p90_limit_ms = $P90LimitMs
    max_limit_ms = $MaxLimitMs
    poll_ms = $PollMs
    samples_ms = $allSamples
    stats_ms = $stats
    resources = $script:ResourceBlock
    passed = $script:TestsPassed
    failed = $script:TestsFailed
})
if ($outFile) { Write-Info "samples written to $outFile" }

Remove-Namespace
Write-Host ""
Write-Host ("Tests passed: {0}, failed: {1}" -f $script:TestsPassed, $script:TestsFailed) -ForegroundColor $(if ($script:TestsFailed -eq 0) { "Green" } else { "Red" })
if ($script:TestsFailed -gt 0) { exit 1 }
exit 0
