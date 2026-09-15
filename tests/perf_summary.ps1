# perf_summary.ps1 - what the perf gates have been recording, as a trend.
#
# The gates each write one JSON per run into %USERPROFILE%\.psmux-test-data\
# metrics. After a few hundred runs that folder answers every question worth
# asking about a regression, and nothing was reading it. This does.
#
#   pwsh -File tests\perf_summary.ps1              last 8 runs of every metric
#   pwsh -File tests\perf_summary.ps1 -Last 20     a longer window
#   pwsh -File tests\perf_summary.ps1 -Metric B    one section (A, B, C, D or all)
#   pwsh -File tests\perf_summary.ps1 -Csv out.csv the same rows, for a chart
#
# The four sections are the owner's four questions:
#
#   A  launch to a usable shell prompt, psmux against a bare pwsh, and against
#      Windows Terminal, WezTerm and Alacritty where a head to head run exists
#   B  keystroke to screen, p50 / p90 / p99, with the pwsh cell judged against
#      the ConPTY floor measured in the same run
#   C  creation latency for new-session, new-window and both splits, p50 / p90
#   D  memory (working set and private bytes) and CPU (per creation, per 100
#      keystrokes, at the first prompt of a fresh session, over an idle window,
#      and idle as a percentage of one core) for the server and the attached
#      client, from all five perf gates
#
# Every row carries the git sha of the tree the measured binary was built in, or
# "installed" when it was a cargo install copy, so two rows can be compared
# without guessing which build produced them. Files written before that envelope
# landed show a blank sha; they are still listed, because a number with an
# unknown provenance is still a number, and the point of this script is the
# shape of the line.

param(
    [int]$Last = 8,
    [ValidateSet("all", "A", "B", "C", "D")]
    [string]$Metric = "all",
    [string]$MetricsDir = "",
    [string]$Csv = ""
)

$ErrorActionPreference = "Continue"
if (-not $MetricsDir) { $MetricsDir = Join-Path $env:USERPROFILE ".psmux-test-data\metrics" }
if (-not (Test-Path $MetricsDir)) {
    Write-Host "no metrics folder at $MetricsDir; run a perf gate first" -ForegroundColor Yellow
    exit 0
}

$script:CsvRows = New-Object System.Collections.Generic.List[object]

function Head($t) {
    Write-Host ""
    Write-Host ("=" * 108) -ForegroundColor DarkGray
    Write-Host "  $t" -ForegroundColor White
    Write-Host ("=" * 108) -ForegroundColor DarkGray
}

function Note($t) { Write-Host "  $t" -ForegroundColor DarkGray }

# Newest first, capped at $Last. A pattern with no files is not an error: a
# machine that has never run test_perf_vs_terminals simply has no row for it.
function Get-Runs {
    param([string]$Pattern, [string[]]$Exclude = @())
    $files = @(Get-ChildItem -LiteralPath $MetricsDir -Filter $Pattern -File -ErrorAction SilentlyContinue |
        Where-Object { $n = $_.Name; -not ($Exclude | Where-Object { $n -like $_ }) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First $Last)
    $out = @()
    foreach ($f in $files) {
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            $out += [pscustomobject]@{ File = $f.Name; When = $f.LastWriteTime; Json = $j }
        } catch { }
    }
    return $out
}

function Prop {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Sha($j) {
    $s = Prop $j "git_sha" ""
    if (-not $s) { return "" }
    if ($s.Length -gt 7 -and $s -notmatch '[^0-9a-f]') { return $s.Substring(0, 7) }
    if ($s.Length -gt 11) { return $s.Substring(0, 11) }
    return $s
}

function Num($v, [int]$d = 1) {
    if ($null -eq $v) { return "-" }
    try { return ([math]::Round([double]$v, $d)).ToString() } catch { return "-" }
}

function Emit($section, $row) {
    $row | Add-Member -NotePropertyName section -NotePropertyValue $section -Force
    $script:CsvRows.Add($row)
}

# ── A: launch to prompt ───────────────────────────────────────────────────
function Show-A {
    Head "A  LAUNCH TO A USABLE PROMPT (ms)"
    $runs = Get-Runs "launch-to-prompt-*.json"
    if ($runs.Count -eq 0) { Note "no test_launch_to_prompt_gate runs recorded" }
    else {
        Write-Host ("  {0,-17} {1,-11} {2,7} {3,7} {4,7} {5,7} {6,7}  {7}" -f "when", "sha", "bareP50", "muxP50", "muxP90", "delta", "gate", "binary") -ForegroundColor DarkCyan
        foreach ($r in $runs) {
            $j = $r.Json
            $bs = Prop $j "bare_stats"; $ps = Prop $j "psmux_stats"
            $row = [pscustomobject]@{
                when   = $r.When.ToString("MM-dd HH:mm")
                sha    = (Sha $j)
                bare_p50 = (Prop $j "bare_median")
                psmux_p50 = (Prop $j "psmux_median")
                psmux_p90 = (Prop $ps "p90")
                delta_ms = (Prop $j "delta_ms")
                gate_ms  = (Prop $j "gate_ms")
                binary   = (Prop $j "binary" "")
            }
            $over = ($null -ne $row.delta_ms -and $null -ne $row.gate_ms -and [double]$row.delta_ms -gt [double]$row.gate_ms)
            Write-Host ("  {0,-17} {1,-11} {2,7} {3,7} {4,7} {5,7} {6,7}  {7}" -f `
                $row.when, $row.sha, (Num $row.bare_p50), (Num $row.psmux_p50), (Num $row.psmux_p90),
                (Num $row.delta_ms), (Num $row.gate_ms), (Split-Path -Leaf $row.binary)) `
                -ForegroundColor $(if ($over) { "Red" } else { "Gray" })
            Emit "A_launch_gate" $row
        }
        Note "delta is psmux median minus bare pwsh median; a red row is over the gate"
    }

    $vt = Get-Runs "perf_vs_terminals-*.json"
    if ($vt.Count -eq 0) { Note "no test_perf_vs_terminals runs recorded, so there is no head to head against WT / WezTerm / Alacritty" ; return }
    Write-Host ""
    Write-Host ("  head to head, launch median per host (ms)") -ForegroundColor DarkCyan
    Write-Host ("  {0,-17} {1,-11} {2,9} {3,9} {4,9} {5,10} {6,10} {7,10}" -f "when", "sha", "bare", "wt", "wezterm", "alacritty", "psmux", "psmux+wt") -ForegroundColor DarkCyan
    foreach ($r in $vt) {
        $t = Prop $r.Json "summary_table" @()
        $get = { param($h) ($t | Where-Object { $_.host -eq $h } | Select-Object -First 1) }
        $row = [pscustomobject]@{
            when      = $r.When.ToString("MM-dd HH:mm")
            sha       = (Sha $r.Json)
            bare      = (Prop (& $get "bare_pwsh") "launch_median")
            wt        = (Prop (& $get "wt_pwsh") "launch_median")
            wezterm   = (Prop (& $get "wezterm_pwsh") "launch_median")
            alacritty = (Prop (& $get "alacritty_pwsh") "launch_median")
            psmux     = (Prop (& $get "psmux_attached") "launch_median")
            psmux_wt  = (Prop (& $get "psmux_in_wt") "launch_median")
        }
        Write-Host ("  {0,-17} {1,-11} {2,9} {3,9} {4,9} {5,10} {6,10} {7,10}" -f `
            $row.when, $row.sha, (Num $row.bare), (Num $row.wt), (Num $row.wezterm),
            (Num $row.alacritty), (Num $row.psmux), (Num $row.psmux_wt))
        Emit "A_vs_terminals" $row
    }
}

# ── B: keystroke to screen ────────────────────────────────────────────────
function Show-B {
    Head "B  KEYSTROKE TO SCREEN (ms)"
    $runs = Get-Runs "keystroke-latency-*.json" @("keystroke-latency-pwsh-*")
    if ($runs.Count -eq 0) { Note "no test_keystroke_latency_gate runs recorded" }
    else {
        Write-Host ("  {0,-17} {1,-11} {2,6} {3,7} {4,7} {5,7} {6,7} {7,7}  {8}" -f "when", "sha", "n", "p50", "p90", "p99", "gateP50", "gateP99", "binary") -ForegroundColor DarkCyan
        foreach ($r in $runs) {
            $j = $r.Json; $p = Prop $j "pooled"
            $row = [pscustomobject]@{
                when = $r.When.ToString("MM-dd HH:mm"); sha = (Sha $j)
                n = (Prop $p "n"); p50 = (Prop $p "median"); p90 = (Prop $p "p90"); p99 = (Prop $p "p99")
                gate_p50 = (Prop $j "medianMaxMs"); gate_p99 = (Prop $j "p99MaxMs")
                binary = (Prop $j "binary" "")
            }
            $over = ($null -ne $row.p50 -and $null -ne $row.gate_p50 -and [double]$row.p50 -ge [double]$row.gate_p50) -or
                    ($null -ne $row.p99 -and $null -ne $row.gate_p99 -and [double]$row.p99 -ge [double]$row.gate_p99)
            Write-Host ("  {0,-17} {1,-11} {2,6} {3,7} {4,7} {5,7} {6,7} {7,7}  {8}" -f `
                $row.when, $row.sha, $row.n, (Num $row.p50 2), (Num $row.p90 2), (Num $row.p99 2),
                (Num $row.gate_p50 1), (Num $row.gate_p99 1), (Split-Path -Leaf $row.binary)) `
                -ForegroundColor $(if ($over) { "Red" } else { "Gray" })
            Emit "B_echo_cell" $row
        }
        Note "echo child in the pane: this is psmux's own path, no shell redraw in it"
    }

    $pw = Get-Runs "keystroke-latency-pwsh-*.json"
    if ($pw.Count -eq 0) { return }
    Write-Host ""
    Write-Host ("  pwsh in the pane, against the ConPTY floor measured in the same run") -ForegroundColor DarkCyan
    Write-Host ("  {0,-17} {1,-11} {2,7} {3,7} {4,7} {5,9} {6,9}" -f "when", "sha", "p50", "p90", "p99", "floorP50", "overFloor") -ForegroundColor DarkCyan
    foreach ($r in $pw) {
        $p = Prop $r.Json "pwsh"
        $row = [pscustomobject]@{
            when = $r.When.ToString("MM-dd HH:mm"); sha = (Sha $r.Json)
            p50 = (Prop $p "median"); p90 = (Prop $p "p90"); p99 = (Prop $p "p99")
            floor_p50 = (Prop $p "floorMedian"); over_floor = (Prop $p "medianDelta")
        }
        Write-Host ("  {0,-17} {1,-11} {2,7} {3,7} {4,7} {5,9} {6,9}" -f `
            $row.when, $row.sha, (Num $row.p50 2), (Num $row.p90 2), (Num $row.p99 2), (Num $row.floor_p50 2), (Num $row.over_floor 2))
        Emit "B_pwsh_cell" $row
    }
    Note "overFloor is the part psmux owns; the floor is conhost's pseudoconsole serializer and every ConPTY consumer pays it"
}

# ── C: creation latency ───────────────────────────────────────────────────
function Show-C {
    Head "C  CREATION LATENCY, TIME TO A VISIBLE PROMPT (ms)"
    $runs = Get-Runs "creation_latency_gate-*.json"
    if ($runs.Count -eq 0) { Note "no test_creation_latency_gate runs recorded" }
    else {
        Write-Host ("  {0,-17} {1,-11} {2,17} {3,17} {4,17} {5,6}  {6}" -f "when", "sha", "new-window p50/p90", "split -v p50/p90", "split -h p50/p90", "slow", "binary") -ForegroundColor DarkCyan
        foreach ($r in $runs) {
            $j = $r.Json
            $s = Prop $j "stats_ms"
            $raw = Prop $j "samples_ms"
            $cell = {
                param($name)
                $st = Prop $s $name
                if ($st) { return @((Prop $st "p50"), (Prop $st "p90")) }
                # A file written before stats_ms existed still has the samples.
                $v = @(Prop $raw $name @())
                if ($v.Count -eq 0) { return @($null, $null) }
                $sorted = @($v | ForEach-Object { [double]$_ } | Sort-Object)
                return @($sorted[[math]::Floor(0.5 * ($sorted.Count - 1))], $sorted[[math]::Floor(0.9 * ($sorted.Count - 1))])
            }
            $nw = & $cell "new-window"; $sv = & $cell "split-window -v"; $sh = & $cell "split-window -h"
            $slowMs = Prop $j "slow_ms" 150
            $slow = 0
            foreach ($k in @("new-window", "split-window -v", "split-window -h")) {
                foreach ($v in @(Prop $raw $k @())) { if ([double]$v -gt [double]$slowMs) { $slow++ } }
            }
            $row = [pscustomobject]@{
                when = $r.When.ToString("MM-dd HH:mm"); sha = (Sha $j)
                new_window_p50 = $nw[0]; new_window_p90 = $nw[1]
                split_v_p50 = $sv[0]; split_v_p90 = $sv[1]
                split_h_p50 = $sh[0]; split_h_p90 = $sh[1]
                slow_count = $slow; binary = (Prop $j "binary" "")
            }
            Write-Host ("  {0,-17} {1,-11} {2,17} {3,17} {4,17} {5,6}  {6}" -f `
                $row.when, $row.sha,
                ("{0} / {1}" -f (Num $nw[0] 0), (Num $nw[1] 0)),
                ("{0} / {1}" -f (Num $sv[0] 0), (Num $sv[1] 0)),
                ("{0} / {1}" -f (Num $sh[0] 0), (Num $sh[1] 0)),
                $slow, (Split-Path -Leaf $row.binary))
            Emit "C_creation_gate" $row
        }
        Note "slow is how many of the 30 creations took longer than the gate's slow_ms; the pool cannot beat a cold shell start"
    }

    $ps = Get-Runs "pane_startup_perf-*.json"
    if ($ps.Count -eq 0) { return }
    Write-Host ""
    Write-Host ("  test_pane_startup_perf, warm pool and first session") -ForegroundColor DarkCyan
    Write-Host ("  {0,-17} {1,-11} {2,12} {3,12} {4,12} {5,12}" -f "when", "sha", "newSess p50", "newWin p50", "splitV p50", "splitH p50") -ForegroundColor DarkCyan
    foreach ($r in $ps) {
        $j = $r.Json
        $med = {
            param($name)
            $v = @(Prop $j $name @())
            if ($v.Count -eq 0) { return $null }
            $s = @($v | ForEach-Object { [double]$_ } | Sort-Object)
            return $s[[math]::Floor(0.5 * ($s.Count - 1))]
        }
        $row = [pscustomobject]@{
            when = $r.When.ToString("MM-dd HH:mm"); sha = (Sha $j)
            new_session_p50 = (& $med "new_session_ms")
            new_window_p50  = (& $med "new_window_ms")
            split_v_p50     = (& $med "pool_depth5_split_v_ms")
            split_h_p50     = (& $med "pool_depth5_split_h_ms")
        }
        Write-Host ("  {0,-17} {1,-11} {2,12} {3,12} {4,12} {5,12}" -f `
            $row.when, $row.sha, (Num $row.new_session_p50 0), (Num $row.new_window_p50 0),
            (Num $row.split_v_p50 0), (Num $row.split_h_p50 0))
        Emit "C_pane_startup" $row
    }
}

# ── D: memory and CPU ─────────────────────────────────────────────────────
function Show-D {
    Head "D  MEMORY AND CPU OF THE SERVER AND THE CLIENT"

    $runs = Get-Runs "creation_latency_gate-*.json"
    $any = $false
    $rows = @()
    foreach ($r in $runs) {
        $res = Prop $r.Json "resources"
        if (-not $res) { continue }
        $any = $true
        $ap = Prop $res "at_prompt"; $af = Prop $res "after_panes"
        $i1 = Prop $res "idle_cpu_pct_one_pane"; $i2 = Prop $res "idle_cpu_pct_many_panes"
        $idleSum = { param($m) if (-not $m) { $null } else { ((Prop $m "server" 0) + (Prop $m "client" 0)) } }
        $rows += [pscustomobject]@{
            when = $r.When.ToString("MM-dd HH:mm"); sha = (Sha $r.Json)
            panes = (Prop $res "panes_opened")
            srv_ws_1 = (Prop (Prop $ap "server") "ws_mb"); srv_priv_1 = (Prop (Prop $ap "server") "private_mb")
            cli_ws_1 = (Prop (Prop $ap "client") "ws_mb"); cli_priv_1 = (Prop (Prop $ap "client") "private_mb")
            srv_ws_n = (Prop (Prop $af "server") "ws_mb"); cli_ws_n = (Prop (Prop $af "client") "ws_mb")
            idle_pct_1 = (& $idleSum $i1); idle_pct_n = (& $idleSum $i2)
        }
    }
    if (-not $any) { Note "no creation gate run has a resources block yet (it was added with the metrics envelope)" }
    else {
        Write-Host ("  one pane, then after a session is filled up  (MB, and CPU as % of one core)") -ForegroundColor DarkCyan
        Write-Host ("  {0,-17} {1,-11} {2,6} {3,9} {4,9} {5,9} {6,9} {7,9} {8,9}" -f `
            "when", "sha", "panes", "srvWS/1", "srvPriv", "cliWS/1", "srvWS/n", "idle%/1", "idle%/n") -ForegroundColor DarkCyan
        foreach ($row in $rows) {
            Write-Host ("  {0,-17} {1,-11} {2,6} {3,9} {4,9} {5,9} {6,9} {7,9} {8,9}" -f `
                $row.when, $row.sha, $row.panes, (Num $row.srv_ws_1 1), (Num $row.srv_priv_1 1),
                (Num $row.cli_ws_1 1), (Num $row.srv_ws_n 1), (Num $row.idle_pct_1 2), (Num $row.idle_pct_n 2))
            Emit "D_creation_resources" $row
        }
        Note "srvWS/n is the server's working set once the session is full; idle% is server plus client with nothing typed"
    }

    $k = Get-Runs "keystroke-latency-*.json" @("keystroke-latency-pwsh-*")
    $krows = @()
    foreach ($r in $k) {
        $res = Prop $r.Json "resources"
        if (-not $res) { continue }
        $ap = Prop $res "at_prompt"; $af = Prop $res "after_key_burst"
        $cpu = Prop $res "cpu_ms_per_100_keys"; $idle = Prop $res "idle_cpu_pct_of_core"
        $krows += [pscustomobject]@{
            when = $r.When.ToString("MM-dd HH:mm"); sha = (Sha $r.Json)
            srv_ws = (Prop (Prop $ap "server") "ws_mb"); cli_ws = (Prop (Prop $ap "client") "ws_mb")
            srv_ws_after = (Prop (Prop $af "server") "ws_mb"); cli_ws_after = (Prop (Prop $af "client") "ws_mb")
            cpu_srv_100k = (Prop $cpu "server"); cpu_cli_100k = (Prop $cpu "client")
            idle_srv = (Prop $idle "server"); idle_cli = (Prop $idle "client")
        }
    }
    if ($krows.Count -eq 0) { Note "no keystroke gate run has a resources block yet" }
    else {
        Write-Host ""
        Write-Host ("  around a typing burst  (MB, ms of CPU per 100 keystrokes, idle % of one core)") -ForegroundColor DarkCyan
        Write-Host ("  {0,-17} {1,-11} {2,8} {3,8} {4,9} {5,9} {6,10} {7,10} {8,8} {9,8}" -f `
            "when", "sha", "srvWS", "cliWS", "srvWSaft", "cliWSaft", "srvCPU100", "cliCPU100", "idleSrv", "idleCli") -ForegroundColor DarkCyan
        foreach ($row in $krows) {
            Write-Host ("  {0,-17} {1,-11} {2,8} {3,8} {4,9} {5,9} {6,10} {7,10} {8,8} {9,8}" -f `
                $row.when, $row.sha, (Num $row.srv_ws 1), (Num $row.cli_ws 1), (Num $row.srv_ws_after 1),
                (Num $row.cli_ws_after 1), (Num $row.cpu_srv_100k 0), (Num $row.cpu_cli_100k 0),
                (Num $row.idle_srv 2), (Num $row.idle_cli 2))
            Emit "D_keystroke_resources" $row
        }
    }

    # The launch gate samples one iteration at its prompt, so its row is the
    # cheapest "what does a session cost the moment it is up" number there is.
    $lt = Get-Runs "launch-to-prompt-*.json"
    $lrows = @()
    foreach ($r in $lt) {
        $res = Prop $r.Json "resources"
        if (-not $res) { continue }
        $ap = Prop $res "at_prompt"; $idle = Prop $res "idle_cpu_pct_of_core"
        $lrows += [pscustomobject]@{
            when = $r.When.ToString("MM-dd HH:mm"); sha = (Sha $r.Json)
            srv_ws = (Prop (Prop $ap "server") "ws_mb"); srv_priv = (Prop (Prop $ap "server") "private_mb")
            cli_ws = (Prop (Prop $ap "client") "ws_mb"); cli_priv = (Prop (Prop $ap "client") "private_mb")
            idle_srv = (Prop $idle "server"); idle_cli = (Prop $idle "client")
        }
    }
    if ($lrows.Count -eq 0) { Note "no launch gate run has a resources block yet" }
    else {
        Write-Host ""
        Write-Host ("  at the first prompt of a freshly launched session  (MB, idle % of one core)") -ForegroundColor DarkCyan
        Write-Host ("  {0,-17} {1,-11} {2,9} {3,9} {4,9} {5,9} {6,9} {7,9}" -f `
            "when", "sha", "srvWS", "srvPriv", "cliWS", "cliPriv", "idleSrv", "idleCli") -ForegroundColor DarkCyan
        foreach ($row in $lrows) {
            Write-Host ("  {0,-17} {1,-11} {2,9} {3,9} {4,9} {5,9} {6,9} {7,9}" -f `
                $row.when, $row.sha, (Num $row.srv_ws 1), (Num $row.srv_priv 1), (Num $row.cli_ws 1),
                (Num $row.cli_priv 1), (Num $row.idle_srv 2), (Num $row.idle_cli 2))
            Emit "D_launch_resources" $row
        }
    }

    # An idle attached pair: the line rate it was gated on, and what it cost.
    $idl = Get-Runs "idle-socket-traffic-*.json"
    $irows = @()
    foreach ($r in $idl) {
        $cells = Prop $r.Json "cells"
        if (-not $cells) { continue }
        foreach ($cn in @($cells.PSObject.Properties.Name)) {
            $c = $cells.$cn
            $ie = Prop $c "idle_end"; $ic = Prop $c "idle_cpu_pct_of_core"
            $irows += [pscustomobject]@{
                when = $r.When.ToString("MM-dd HH:mm"); sha = (Sha $r.Json); cell = $cn
                lines_per_sec = (Prop $c "lines_per_sec")
                srv_ws = (Prop (Prop $ie "server") "ws_mb"); cli_ws = (Prop (Prop $ie "client") "ws_mb")
                idle_srv = (Prop $ic "server"); idle_cli = (Prop $ic "client")
            }
        }
    }
    if ($irows.Count -eq 0) { Note "no test_idle_socket_traffic run has a metrics file yet" }
    else {
        Write-Host ""
        Write-Host ("  an idle attached pair, over the window the line count was taken on") -ForegroundColor DarkCyan
        Write-Host ("  {0,-17} {1,-11} {2,-8} {3,10} {4,9} {5,9} {6,9} {7,9}" -f `
            "when", "sha", "cell", "lines/sec", "srvWS", "cliWS", "idleSrv", "idleCli") -ForegroundColor DarkCyan
        foreach ($row in $irows) {
            Write-Host ("  {0,-17} {1,-11} {2,-8} {3,10} {4,9} {5,9} {6,9} {7,9}" -f `
                $row.when, $row.sha, $row.cell, (Num $row.lines_per_sec 1), (Num $row.srv_ws 1),
                (Num $row.cli_ws 1), (Num $row.idle_srv 2), (Num $row.idle_cli 2))
            Emit "D_idle_socket" $row
        }
        Note "lines/sec is the gated number; the CPU beside it says whether a quiet socket was bought by spinning elsewhere"
    }

    $vt = Get-Runs "perf_vs_terminals-*.json"
    if ($vt.Count -eq 0) { return }
    Write-Host ""
    Write-Host ("  test_perf_vs_terminals, psmux attached cell") -ForegroundColor DarkCyan
    Write-Host ("  {0,-17} {1,-11} {2,9} {3,9} {4,11} {5,11}" -f "when", "sha", "srvWS", "cliWS", "cpu/100keys", "idle % core") -ForegroundColor DarkCyan
    foreach ($r in $vt) {
        $t = Prop $r.Json "summary_table" @()
        $cell = ($t | Where-Object { $_.host -eq "psmux_attached" } | Select-Object -First 1)
        if (-not $cell) { continue }
        $row = [pscustomobject]@{
            when = $r.When.ToString("MM-dd HH:mm"); sha = (Sha $r.Json)
            srv_ws = (Prop $cell "server_ws_mb"); cli_ws = (Prop $cell "client_ws_mb")
            cpu_100k = (Prop $cell "cpu_per_100_keys_psmux"); idle_pct = (Prop $cell "idle_cpu_pct_psmux")
        }
        Write-Host ("  {0,-17} {1,-11} {2,9} {3,9} {4,11} {5,11}" -f `
            $row.when, $row.sha, (Num $row.srv_ws 1), (Num $row.cli_ws 1), (Num $row.cpu_100k 0), (Num $row.idle_pct 2))
        Emit "D_vs_terminals" $row
    }
}

Write-Host ""
Write-Host "psmux performance metrics, last $Last runs per metric" -ForegroundColor Cyan
Write-Host "from $MetricsDir" -ForegroundColor DarkGray

if ($Metric -in @("all", "A")) { Show-A }
if ($Metric -in @("all", "B")) { Show-B }
if ($Metric -in @("all", "C")) { Show-C }
if ($Metric -in @("all", "D")) { Show-D }

if ($Csv) {
    try {
        $script:CsvRows | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
        Write-Host ""
        Write-Host "  $($script:CsvRows.Count) rows written to $Csv" -ForegroundColor Green
    } catch {
        Write-Host "  could not write $Csv : $_" -ForegroundColor Yellow
    }
}
Write-Host ""
