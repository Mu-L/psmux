# Issue #510: a psmux invocation resolving one data dir must never terminate
# servers belonging to another.
#
# The startup reaper enumerates candidates machine-wide but drew its authority
# from a single ~/.psmux resolved from USERPROFILE/HOME, so anything that
# registry did not account for was killed as an "orphan". Any invocation under a
# different home therefore destroyed every other instance's live sessions.
#
# WHAT THIS TEST DOES: stands up a victim server under home A, then runs a
# read-only psmux command under home B and proves the victim survives. Both
# homes are throwaway temp dirs, so the real ~/.psmux and any live user or agent
# sessions are never in scope either way.
#
# WHY IT IS GATED: it starts real psmux servers. Get-PsmuxExe resolves the
# locally BUILT binary (PSMUX_EXE, then target\release, then target\debug) and
# never PATH, so it cannot accidentally exercise an installed build - which
# matters here, because running this scenario against a pre-fix binary is
# precisely the operation that kills the user's sessions.

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot 'psmux_test_helpers.ps1')

$isDisposable = $env:PSMUX_ALLOW_DESTRUCTIVE_TESTS -or $env:CI -or $env:GITHUB_ACTIONS
if (-not $isDisposable) {
    Write-Host "[SKIP] test_issue510_foreign_server_survives.ps1 starts real psmux servers." -ForegroundColor DarkYellow
    Write-Host "       Set PSMUX_ALLOW_DESTRUCTIVE_TESTS=1 to run (CI sets CI/GITHUB_ACTIONS)." -ForegroundColor DarkYellow
    exit 0
}

$script:Passed = 0
$script:Failed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Passed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Failed++ }

function Is-PidAlive($procId) {
    if (-not ("$procId" -match '^\d+$')) { return $false }
    $p = Get-Process -Id ([int]$procId) -EA SilentlyContinue
    return ($null -ne $p -and -not $p.HasExited)
}

Write-Host "`n=== Issue #510: a foreign data dir must not reap our servers ===" -ForegroundColor Cyan

$exe = Get-PsmuxExe
Write-Host "    binary under test: $exe" -ForegroundColor DarkGray

$victim = $null
$intruderHome = $null
$savedProfile = $env:USERPROFILE
$savedHome = $env:HOME

try {
    # ---- Home A: the victim, a perfectly healthy server ---------------------
    $victim = New-PsmuxTestEnv -Tag 'i510victim' -Exe $exe
    $ns = Register-PsmuxNamespace -Ctx $victim -Namespace 'i510victim'
    & $exe -L $ns new-session -d -s survivor 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    $pidFile = Join-Path $victim.PsmuxDir "${ns}__survivor.pid"
    if (-not (Test-Path $pidFile)) {
        Write-Fail "victim server did not register a .pid ($pidFile); cannot run the scenario"
        throw "setup failed"
    }
    $victimPid = ((Get-Content $pidFile -Raw).Trim() -split ':')[0]
    if (Is-PidAlive $victimPid) { Write-Pass "victim server $victimPid is live under home A" }
    else { Write-Fail "victim server $victimPid is not alive"; throw "setup failed" }

    # The reaper spares anything inside its 10s grace window, so a young victim
    # would survive even a buggy build. Age past the grace to make this real.
    Write-Host "    aging victim past the 10s reap grace window..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 12
    if (-not (Is-PidAlive $victimPid)) { Write-Fail "victim died while aging"; throw "setup failed" }

    # ---- Home B: an unrelated invocation that must keep its hands off -------
    # A fresh, EMPTY data dir is the harness/MSYS2/second-account case: it can
    # account for nothing on this machine, so it must claim nothing.
    $intruderHome = Join-Path $env:TEMP ("psmux_i510intruder_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $intruderHome '.psmux') -Force | Out-Null
    $env:USERPROFILE = $intruderHome
    $env:HOME = $intruderHome

    & $exe -L i510intruder list-sessions 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    if (Is-PidAlive $victimPid) {
        Write-Pass "victim server $victimPid SURVIVED a foreign-home invocation"
    } else {
        Write-Fail "victim server $victimPid was reaped by a foreign-home invocation (#510)"
    }

    # Repeat: the reaper runs on EVERY invocation, so one survival could be luck.
    for ($i = 0; $i -lt 3; $i++) {
        & $exe -L i510intruder list-sessions 2>&1 | Out-Null
        Start-Sleep -Milliseconds 400
    }
    if (Is-PidAlive $victimPid) { Write-Pass "victim survived repeated foreign-home reaper passes" }
    else { Write-Fail "victim was reaped by a later foreign-home reaper pass" }

    # ---- The intruder's own view stays correct -----------------------------
    # Not seeing another home's sessions is right; killing them is not.
    $seen = (& $exe -L i510intruder list-sessions 2>&1 | Out-String).Trim()
    if ($seen -notmatch 'survivor') { Write-Pass "intruder correctly does not see home A's session" }
    else { Write-Fail "intruder unexpectedly listed home A's session: $seen" }

    $env:USERPROFILE = $savedProfile
    $env:HOME = $savedHome
}
finally {
    $env:USERPROFILE = $savedProfile
    $env:HOME = $savedHome
    if ($intruderHome) { Remove-Item -Recurse -Force $intruderHome -EA SilentlyContinue }
    if ($victim) { Remove-PsmuxTestEnv -Ctx $victim }
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Passed)" -ForegroundColor Green
Write-Host "  Failed: $($script:Failed)" -ForegroundColor $(if ($script:Failed -gt 0) { "Red" } else { "Green" })
exit $script:Failed
