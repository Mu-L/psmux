# Issue #573: mouse stopped working after upgrading 3.3.6 -> 3.3.7
#
# Reported on Windows Server 2022 (build 20348) in Alacritty and WezTerm: no
# click-to-switch-pane, no wheel, while `show-options -g -v mouse` still reads
# `on`. Downgrading to 3.3.6 restored it.
#
# Root cause: c92aec0 (#457) gates send_mouse_enable() on build >= 22523.  That
# call is the only thing that writes the mouse-enable DECSET via a raw WriteFile
# on the console handle, deliberately bypassing ConPTY, and on builds whose
# ConPTY swallows the DECSET instead of forwarding it that bypass was the only
# way the terminal ever entered mouse reporting.  Server 2022 sits below the
# threshold, so 3.3.7 left it with no mouse-enable at all.  5415fd8 (#468) then
# widened the blast radius by routing local WezTerm through the same VT path,
# so this reaches users who never touch SSH.
#
# The gate is NOT being removed: on Win10 19045 an SGR mouse report fast-fails
# conhost (0xc0000409) and kills the pane process, which is strictly worse than
# a dead mouse.  What this fix adds is PSMUX_FORCE_MOUSE, so a user whose
# conhost does handle mouse can get it back without downgrading.
#
# This suite proves the byte-level behaviour by hosting a real `psmux attach`
# inside a ConPTY and dumping every outward byte, then looking for the enable
# block. `\e[?1000h` is the marker: it appears ONLY in the bypass write, so its
# presence or absence is an exact read of whether the gate fired.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SESSION = "t573mouse"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [info] $msg" -ForegroundColor DarkGray }

# ---- build the ConPTY capture harness -------------------------------------
$capExe = "$env:TEMP\psmux_conptycap_573.exe"
$capSrc = Join-Path $PSScriptRoot "conptycap.cs"
if (-not (Test-Path $capSrc)) {
    Write-Fail "harness source missing: $capSrc"
    exit 1
}
if (-not (Test-Path $capExe)) {
    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    if (-not (Test-Path $csc)) { $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" }
    & $csc /nologo /optimize /out:$capExe $capSrc 2>&1 | Out-Null
}
if (-not (Test-Path $capExe)) {
    Write-Fail "could not compile the ConPTY capture harness"
    exit 1
}

function Reset-All {
    & $PSMUX kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Get-Process psmux, tmux, pmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 400
    Get-ChildItem $psmuxDir -EA SilentlyContinue |
        Where-Object { $_.Extension -in '.port', '.key', '.pid', '.sid', '.spawnlock' } |
        Remove-Item -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 300
}

# Host `psmux attach` under a real ConPTY with the given environment and return
# the outward byte stream as a latin-1 string (one char per byte, so escape
# matching is exact and never mangled by UTF-8 decoding).
function Measure-MouseEnable {
    param([string]$Tag, [string]$FakeBuild, [string]$ForceMouse, [string]$TermProgram = "WezTerm")

    Reset-All

    $env:PSMUX_NO_WARM = "1"
    Remove-Item Env:\PSMUX_FAKE_WIN_BUILD -EA SilentlyContinue
    Remove-Item Env:\PSMUX_FORCE_MOUSE    -EA SilentlyContinue
    Remove-Item Env:\TERM_PROGRAM         -EA SilentlyContinue
    Remove-Item Env:\WEZTERM_PANE         -EA SilentlyContinue
    Remove-Item Env:\SSH_TTY              -EA SilentlyContinue
    Remove-Item Env:\SSH_CONNECTION       -EA SilentlyContinue
    if ($FakeBuild)   { $env:PSMUX_FAKE_WIN_BUILD = $FakeBuild }
    if ($ForceMouse)  { $env:PSMUX_FORCE_MOUSE = $ForceMouse }
    if ($TermProgram) { $env:TERM_PROGRAM = $TermProgram }

    & $PSMUX new-session -d -s $SESSION 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    & $PSMUX set-option -g mouse on 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400

    $mouseOpt = ((& $PSMUX show-options -g -v mouse 2>&1) -join "").Trim()

    $out = "$env:TEMP\psmux_573_$Tag.bin"
    if (Test-Path $out) { Remove-Item $out -Force -EA SilentlyContinue }
    $env:CONPTYCAP_DRAIN_MS = "9000"
    $p = Start-Process -FilePath $capExe `
        -ArgumentList @($out, "120", "30", "0", "`"$PSMUX`"", "attach", "-t", $SESSION) -PassThru
    $null = $p.WaitForExit(40000)
    if (-not $p.HasExited) { try { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } catch {} }

    $bytes = @()
    if (Test-Path $out) { $bytes = [System.IO.File]::ReadAllBytes($out) }
    $text = -join ($bytes | ForEach-Object { [char]$_ })

    Reset-All
    Remove-Item Env:\PSMUX_FAKE_WIN_BUILD -EA SilentlyContinue
    Remove-Item Env:\PSMUX_FORCE_MOUSE    -EA SilentlyContinue
    Remove-Item Env:\TERM_PROGRAM         -EA SilentlyContinue
    Remove-Item Env:\PSMUX_NO_WARM        -EA SilentlyContinue

    return [pscustomobject]@{
        Tag        = $Tag
        Bytes      = $bytes.Count
        MouseOpt   = $mouseOpt
        # The bypass-only marker. crossterm / conhost emit the coalesced
        # "\e[?1003;1006h" in every condition, so matching on 1003 or 1006 alone
        # would report a pass even when the gate suppressed everything.
        HasEnable  = $text.Contains("$([char]27)[?1000h")
    }
}

Write-Host "`n=== Issue #573: the ConPTY mouse gate needs an escape hatch ===" -ForegroundColor Cyan
Write-Host "psmux: $PSMUX" -ForegroundColor DarkGray
Write-Host "build: $((& $PSMUX -V 2>&1 | Out-String).Trim())" -ForegroundColor DarkGray

# ------------------------------------------------------------------ Test 1 --
# The reporter's condition. This must still suppress: #457's crash safety is
# the default and this fix does not weaken it.
Write-Host "`n[Test 1] Gated build 20348 on the VT path still suppresses by default" -ForegroundColor Yellow
$r1 = Measure-MouseEnable -Tag "gated" -FakeBuild "20348" -ForceMouse ""
Write-Info "$($r1.Tag): bytes=$($r1.Bytes) mouse='$($r1.MouseOpt)' enableBlock=$($r1.HasEnable)"
if ($r1.MouseOpt -eq "on") {
    Write-Pass "the mouse option itself reads 'on' (matches the reporter's screenshot)"
} else {
    Write-Fail "setup: mouse option is '$($r1.MouseOpt)', expected 'on'"
}
if (-not $r1.HasEnable) {
    Write-Pass "no mouse-enable bypass emitted on a gated build (issue #457 safety intact)"
} else {
    Write-Fail "the #457 gate no longer suppresses on build 20348"
}

# ------------------------------------------------------------------ Test 2 --
# The fix. Same gated build, override set: the bypass must come back.
Write-Host "`n[Test 2] PSMUX_FORCE_MOUSE=1 restores the mouse-enable on that same build" -ForegroundColor Yellow
$r2 = Measure-MouseEnable -Tag "forced" -FakeBuild "20348" -ForceMouse "1"
Write-Info "$($r2.Tag): bytes=$($r2.Bytes) mouse='$($r2.MouseOpt)' enableBlock=$($r2.HasEnable)"
if ($r2.HasEnable) {
    Write-Pass "mouse-enable emitted with the override (issue #573 fixed)"
} else {
    Write-Fail "PSMUX_FORCE_MOUSE=1 did not restore the mouse-enable (issue #573 NOT fixed)"
}

# ------------------------------------------------------------------ Test 3 --
# Control: a modern build must be untouched by all of this.
Write-Host "`n[Test 3] A modern build still enables mouse with no override" -ForegroundColor Yellow
$r3 = Measure-MouseEnable -Tag "modern" -FakeBuild "26200" -ForceMouse ""
Write-Info "$($r3.Tag): bytes=$($r3.Bytes) mouse='$($r3.MouseOpt)' enableBlock=$($r3.HasEnable)"
if ($r3.HasEnable) {
    Write-Pass "modern build unaffected by the fix"
} else {
    Write-Fail "REGRESSION: a modern build stopped emitting the mouse-enable"
}

# ------------------------------------------------------------------ Test 4 --
# The other direction, for a modern host whose conhost misbehaves.
Write-Host "`n[Test 4] PSMUX_FORCE_MOUSE=0 pins mouse off on a modern build" -ForegroundColor Yellow
$r4 = Measure-MouseEnable -Tag "pinnedoff" -FakeBuild "26200" -ForceMouse "0"
Write-Info "$($r4.Tag): bytes=$($r4.Bytes) mouse='$($r4.MouseOpt)' enableBlock=$($r4.HasEnable)"
if (-not $r4.HasEnable) {
    Write-Pass "override suppresses on demand"
} else {
    Write-Fail "PSMUX_FORCE_MOUSE=0 did not suppress the mouse-enable"
}

# ---------------------------------------------------------------------------
Write-Host "`n--- matrix ---" -ForegroundColor DarkGray
foreach ($r in @($r1, $r2, $r3, $r4)) {
    Write-Host ("  {0,-10} enableBlock={1}" -f $r.Tag, $r.HasEnable) -ForegroundColor DarkGray
}

Reset-All
Remove-Item "$env:TEMP\psmux_573_*.bin*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
