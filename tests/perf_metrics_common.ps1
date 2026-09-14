# perf_metrics_common.ps1 - the pieces every perf gate needs, in one place.
#
# WHY THIS FILE EXISTS
# --------------------
# Four suites time psmux and every one of them wrote its own JSON with its own
# field names. A run recorded in one file could not be lined up against a run
# recorded in another, and none of the gate files recorded WHICH BUILD produced
# the number: two of the three gates default to the psmux on PATH, the third
# defaults to target\release, and the JSON said only "binary". Comparing a
# suspected regression against last week meant guessing.
#
# So every perf JSON now carries the same envelope:
#
#   schema        the envelope version, so a reader can tell old files apart
#   suite         the suite that wrote it
#   timestamp     round trip "o" format, local time with offset
#   binary        full path of the psmux under test
#   git_sha       short HEAD of the repository the binary was built in, found by
#                 walking up from the binary, or "installed" when the binary
#                 does not sit in a work tree (a cargo install copy does not)
#   machine       computer name
#   os / cpu / cpu_count / ram_gb
#
# and the same shapes for numbers: Get-PerfStats returns n/min/p50/p90/p99/max/
# mean, and the resource helpers return working set, private bytes and CPU in
# one shape for the server and the client alike.
#
# MEMORY AND CPU
# --------------
# The server is found by its <ns>__<session>.pid anchor file, never by image
# name: a warm standby shares the image and the namespace but never the anchor,
# and the owner's machine routinely has a dozen psmux servers belonging to other
# sessions. The anchor holds "<pid>:<creationtime>" so a recycled PID is
# rejected. Clients are the processes running THIS binary with this namespace on
# their command line that are not the server.
#
# Nothing in this file kills anything. It only reads.
#
# Dot source it:  . "$PSScriptRoot\perf_metrics_common.ps1"

$script:PerfSchema = 2

# ── percentiles ───────────────────────────────────────────────────────────
# Nearest rank on the sorted sample, which is the rule the keystroke gate
# already used, so numbers recorded before and after this helper landed stay
# comparable.
function Get-PerfPercentile {
    param([object[]]$Values, [double]$P)
    $v = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $i = [Math]::Floor(($P / 100.0) * ($v.Count - 1))
    if ($i -lt 0) { $i = 0 }
    if ($i -gt $v.Count - 1) { $i = $v.Count - 1 }
    return [double]$v[[int]$i]
}

function Get-PerfStats {
    param([object[]]$Values, [int]$Round = 2)
    $v = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($v.Count -eq 0) {
        return [ordered]@{ n = 0; min = $null; p50 = $null; p90 = $null; p99 = $null; max = $null; mean = $null }
    }
    $r = { param($x) if ($null -eq $x) { $null } else { [math]::Round([double]$x, $Round) } }
    return [ordered]@{
        n    = $v.Count
        min  = & $r (Get-PerfPercentile $v 0)
        p50  = & $r (Get-PerfPercentile $v 50)
        p90  = & $r (Get-PerfPercentile $v 90)
        p99  = & $r (Get-PerfPercentile $v 99)
        max  = & $r (Get-PerfPercentile $v 100)
        mean = & $r (($v | Measure-Object -Average).Average)
    }
}

# ── which build is this ───────────────────────────────────────────────────
# A binary inside a work tree gets that tree's short HEAD. A binary that is not
# (C:\Users\<user>\.cargo\bin\psmux.exe, an installer copy) is honestly labelled
# "installed" rather than being tagged with whatever the current directory's
# HEAD happens to be, which would be a lie in exactly the case that matters:
# comparing a fresh build against the installed one.
function Get-PerfGitSha {
    param([string]$Binary)
    if (-not $Binary) { return "unknown" }
    $dir = try { Split-Path -Parent (Resolve-Path -LiteralPath $Binary -ErrorAction Stop).Path } catch { return "unknown" }
    $probe = $dir
    for ($i = 0; $i -lt 8 -and $probe; $i++) {
        if (Test-Path (Join-Path $probe ".git")) {
            try {
                $sha = (& git -C $probe rev-parse --short HEAD 2>$null | Select-Object -First 1)
                if ($sha) { return $sha.Trim() }
            } catch { }
            return "unknown"
        }
        $parent = Split-Path -Parent $probe
        if ($parent -eq $probe) { break }
        $probe = $parent
    }
    return "installed"
}

# `psmux -V` answers with the tmux compatibility line first and its own build
# line second ("psmux 3.3.8 (<sha> <date>)"), and it is the second one that
# identifies the build, so it is preferred when present.
function Get-PerfBinaryVersion {
    param([string]$Binary)
    try {
        $lines = @(& $Binary -V 2>$null)
        $own = $lines | Where-Object { $_ -match '^psmux ' } | Select-Object -First 1
        if ($own) { return ([string]$own).Trim() }
        if ($lines.Count -gt 0) { return ([string]$lines[0]).Trim() }
    } catch { }
    return ""
}

# ── the envelope every perf JSON carries ──────────────────────────────────
function Get-PerfEnvelope {
    param([string]$Suite, [string]$Binary)
    $cpu = ""
    try { $cpu = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Name) } catch { }
    $ram = 0
    try { $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1GB, 1) } catch { }
    return [ordered]@{
        schema    = $script:PerfSchema
        suite     = $Suite
        timestamp = (Get-Date).ToString("o")
        binary    = $Binary
        git_sha   = (Get-PerfGitSha $Binary)
        version   = (Get-PerfBinaryVersion $Binary)
        machine   = $env:COMPUTERNAME
        os        = [System.Environment]::OSVersion.VersionString
        cpu       = ($cpu -replace '\s+$', '')
        cpu_count = [Environment]::ProcessorCount
        ram_gb    = $ram
    }
}

function Get-PerfMetricsDir {
    param([string]$MetricsDir = "")
    if (-not $MetricsDir) { $MetricsDir = Join-Path $env:USERPROFILE ".psmux-test-data\metrics" }
    if (-not (Test-Path $MetricsDir)) { New-Item -ItemType Directory -Force -Path $MetricsDir | Out-Null }
    return $MetricsDir
}

# Envelope + payload, written OUTSIDE the repo. Returns the path, or $null if
# the write failed; a perf suite must never die because a disk was full.
function Write-PerfMetrics {
    param(
        [string]$Suite,
        [string]$Binary,
        [System.Collections.IDictionary]$Data,
        [string]$FileStem = "",
        [string]$MetricsDir = "",
        [string]$Stamp = "",
        [int]$Depth = 8
    )
    try {
        $dir = Get-PerfMetricsDir $MetricsDir
        if (-not $FileStem) { $FileStem = $Suite }
        if (-not $Stamp) { $Stamp = Get-Date -Format "yyyyMMdd-HHmmss" }
        $payload = Get-PerfEnvelope $Suite $Binary
        foreach ($k in $Data.Keys) { $payload[$k] = $Data[$k] }
        $path = Join-Path $dir "$FileStem-$Stamp.json"
        ($payload | ConvertTo-Json -Depth $Depth) | Set-Content -LiteralPath $path -Encoding UTF8
        return $path
    } catch {
        Write-Host "[WARN] could not write the metrics JSON: $_" -ForegroundColor Yellow
        return $null
    }
}

# ── finding the processes of one session ──────────────────────────────────
function Get-PerfDataDir {
    if ($env:PSMUX_DATA_DIR) { return $env:PSMUX_DATA_DIR.TrimEnd('\', '/') }
    return "$env:USERPROFILE\.psmux"
}

# The server for one session, from its <ns>__<session>.pid anchor. Never by
# image name: a warm standby shares the image and the namespace but never this
# file.
function Get-PerfServerPid {
    param([string]$Ns, [string]$Session, [string]$DataDir = "")
    if (-not $DataDir) { $DataDir = Get-PerfDataDir }
    $f = Join-Path $DataDir "${Ns}__$Session.pid"
    if (-not (Test-Path $f)) { return 0 }
    $txt = ""
    try { $txt = (Get-Content -LiteralPath $f -Raw).Trim() } catch { return 0 }
    $first = ($txt -split ':')[0]
    $out = 0
    if (-not [int]::TryParse($first, [ref]$out)) { return 0 }
    if (-not (Get-Process -Id $out -ErrorAction SilentlyContinue)) { return 0 }
    return $out
}

# Every process running THIS binary with this namespace on its command line.
# ExecutablePath is matched exactly, so a differently built psmux belonging to
# another agent or to the user's own session is never sampled.
function Get-PerfNamespacePids {
    param([string]$Binary, [string]$Ns)
    $name = [IO.Path]::GetFileName($Binary)
    $out = @()
    try {
        $out = @(Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -eq $Binary -and $_.CommandLine -and $_.CommandLine -match ("(?i)-L\s+" + [regex]::Escape($Ns) + "(\s|$)") } |
            Select-Object -ExpandProperty ProcessId)
    } catch { }
    return @($out | ForEach-Object { [int]$_ })
}

# The attached client of one session: this binary, this namespace, not the
# server. There is normally exactly one; the first is taken when a suite has
# attached more than once.
function Get-PerfClientPid {
    param([string]$Binary, [string]$Ns, [int]$ServerPid = 0)
    foreach ($p in (Get-PerfNamespacePids -Binary $Binary -Ns $Ns)) {
        if ($p -ne $ServerPid) { return $p }
    }
    return 0
}

# ── one sample of one process ─────────────────────────────────────────────
function Get-PerfProcSample {
    param([int]$ProcId, [string]$Role)
    if ($ProcId -le 0) { return $null }
    $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $cpu = 0.0
    try { $cpu = $p.TotalProcessorTime.TotalMilliseconds } catch { }
    return [pscustomobject]@{
        role       = $Role
        pid        = $ProcId
        name       = $p.ProcessName
        ws_mb      = [math]::Round($p.WorkingSet64 / 1MB, 2)
        private_mb = [math]::Round($p.PrivateMemorySize64 / 1MB, 2)
        cpu_ms     = [math]::Round($cpu, 1)
        threads    = $p.Threads.Count
    }
}

# $Roles is role name -> pid. Returns role -> sample, missing roles dropped.
function Get-PerfResourceSnapshot {
    param([System.Collections.IDictionary]$Roles)
    $o = [ordered]@{}
    foreach ($r in @($Roles.Keys)) {
        $s = Get-PerfProcSample ([int]$Roles[$r]) $r
        if ($s) { $o[$r] = $s }
    }
    return $o
}

# CPU consumed between two snapshots of the same roles. $Div turns raw ms into
# the reported unit and $Mul scales it: (elapsed ms, 100) gives percent of one
# core, (key count, 100) gives ms of CPU per 100 keystrokes. A role whose PID
# changed between the two snapshots is dropped: that is not a delta.
function Get-PerfCpuDelta {
    param($A, $B, [double]$Div, [double]$Mul = 1.0)
    $o = [ordered]@{}
    if (-not $A -or -not $B -or $Div -le 0) { return $o }
    foreach ($r in @($A.Keys)) {
        if (-not $B.Contains($r)) { continue }
        if ($A[$r].pid -ne $B[$r].pid) { continue }
        $d = [double]($B[$r].cpu_ms - $A[$r].cpu_ms)
        if ($d -lt 0) { $d = 0 }
        $o[$r] = [math]::Round(($d / $Div) * $Mul, 2)
    }
    return $o
}

# Sit still for $Seconds with nothing driving the session and report each role's
# CPU as a percentage of ONE core. This is the busy polling detector: a 1 ms
# sleep loop that Windows rounds to a 15.6 ms timer tick is invisible in every
# latency number and obvious here. Resolution is one scheduler tick (15.6 ms)
# over the window, ie 0.52 percent of a core for a 3 s window.
function Measure-PerfIdleCpu {
    param([System.Collections.IDictionary]$Roles, [int]$Seconds = 3)
    $a = Get-PerfResourceSnapshot $Roles
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds ($Seconds * 1000)
    $sw.Stop()
    $b = Get-PerfResourceSnapshot $Roles
    return [ordered]@{
        window_ms      = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
        pct_of_one_core = (Get-PerfCpuDelta $a $b ([double]$sw.Elapsed.TotalMilliseconds) 100.0)
    }
}

# Working set / private bytes of a snapshot, flattened for the JSON, plus the
# server+client totals that are the number the owner actually reads.
function Get-PerfMemorySummary {
    param($Snapshot)
    $o = [ordered]@{}
    $wsTotal = 0.0; $privTotal = 0.0
    foreach ($r in @($Snapshot.Keys)) {
        $o[$r] = [ordered]@{
            pid        = $Snapshot[$r].pid
            ws_mb      = $Snapshot[$r].ws_mb
            private_mb = $Snapshot[$r].private_mb
            cpu_ms     = $Snapshot[$r].cpu_ms
            threads    = $Snapshot[$r].threads
        }
        if ($r -in @("server", "client")) {
            $wsTotal += [double]$Snapshot[$r].ws_mb
            $privTotal += [double]$Snapshot[$r].private_mb
        }
    }
    $o["psmux_total_ws_mb"] = [math]::Round($wsTotal, 2)
    $o["psmux_total_private_mb"] = [math]::Round($privTotal, 2)
    return $o
}

function Format-PerfResourceLine {
    param($Snapshot, [string]$Label)
    $parts = @()
    foreach ($r in @($Snapshot.Keys)) {
        $parts += ("{0} ws {1}MB priv {2}MB cpu {3}ms" -f $r, $Snapshot[$r].ws_mb, $Snapshot[$r].private_mb, $Snapshot[$r].cpu_ms)
    }
    if ($parts.Count -eq 0) { return "$Label : no process found" }
    return ("{0} : {1}" -f $Label, ($parts -join "  |  "))
}
