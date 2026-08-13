# Issue #569: psmux runs one server per session and each allocates %N from its
# own counter starting at 1, so %1 exists in EVERY session simultaneously. An
# unqualified `-t %1` therefore has no single correct answer, and routing
# resolved it against whichever session was most recently used: silently, at
# exit 0, against the wrong pane. tmux makes these ids unique per server, which
# is what makes an unqualified -t %N meaningful there.
#
# The fix refuses an ambiguous unqualified pane id instead of guessing. Every
# invocation that resolves to exactly one session is unaffected, which is what
# the controls below pin down.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$L = 't569'
$script:Pass = 0; $script:Fail = 0
function Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

function Probe {
    param([string[]]$PsmuxArgs)
    $o = [System.IO.Path]::GetTempFileName(); $e = [System.IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $PSMUX -ArgumentList $PsmuxArgs -NoNewWindow -Wait -PassThru `
         -RedirectStandardOutput $o -RedirectStandardError $e
    $r = @{ rc=$p.ExitCode
            stdout=((Get-Content $o -Raw -EA SilentlyContinue) ?? '').Trim()
            stderr=((Get-Content $e -Raw -EA SilentlyContinue) ?? '').Trim() }
    Remove-Item $o,$e -Force -EA SilentlyContinue
    return $r
}

& $PSMUX -L $L kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

Write-Host "=== Issue #569: ambiguous unqualified pane id ===" -ForegroundColor Cyan

# --- CONTROL: with ONE session, a bare %1 is unambiguous and must still work.
& $PSMUX -L $L new-session -d -s solo 2>&1 | Out-Null
Start-Sleep -Seconds 4
$c = Probe @('-L', $L, 'display-message', '-p', '-t', '%1', '#{session_name}')
if ($c.rc -eq 0 -and $c.stdout -eq 'solo') { Pass "control: single session, bare %1 resolves (rc=0, '$($c.stdout)')" }
else { Fail "control broken: rc=$($c.rc) stdout=[$($c.stdout)] stderr=[$($c.stderr)]" }

# --- TEST: a second session also owns %1, so the bare form is now ambiguous.
& $PSMUX -L $L new-session -d -s second 2>&1 | Out-Null
Start-Sleep -Seconds 4

# Prove the precondition rather than assuming it: %1 really is in both sessions.
$panes = & $PSMUX -L $L list-panes -a -F '#{session_name} #{pane_id}' 2>&1 | Out-String
$dupes = ([regex]::Matches($panes, '%1')).Count
if ($dupes -ge 2) { Pass "precondition: %1 exists in $dupes sessions" }
else { Fail "precondition not met, %1 found $dupes times: $panes" }

$t = Probe @('-L', $L, 'display-message', '-p', '-t', '%1', '#{session_name}')
if ($t.rc -ne 0) { Pass "ambiguous bare %1 exits non-zero (rc=$($t.rc))" }
else { Fail "ambiguous bare %1 still exited 0 with [$($t.stdout)] (silently wrong pane)" }
if ($t.stderr -match 'ambiguous pane id') { Pass "diagnostic names the ambiguity" }
else { Fail "no ambiguity diagnostic: stderr=[$($t.stderr)]" }
# The message must name sessions the caller can actually type, not the
# "<ns>__<session>" registry base.
if ($t.stderr -match 'solo' -and $t.stderr -match 'second' -and $t.stderr -notmatch "${L}__") {
    Pass "diagnostic lists both sessions by their short names"
} else { Fail "session names wrong in: [$($t.stderr)]" }
if ([string]::IsNullOrWhiteSpace($t.stdout)) { Pass "stdout stayed clean" }
else { Fail "diagnostic leaked to stdout: [$($t.stdout)]" }

# --- CONTROL: fully qualified targets are unaffected and still address BOTH.
foreach ($s in @('solo','second')) {
    $q = Probe @('-L', $L, 'display-message', '-p', '-t', "${s}:0.0", '#{session_name}')
    if ($q.rc -eq 0 -and $q.stdout -eq $s) { Pass "qualified -t ${s}:0.0 still resolves" }
    else { Fail "qualified -t ${s}:0.0 broke: rc=$($q.rc) out=[$($q.stdout)] err=[$($q.stderr)]" }
}

& $PSMUX -L $L kill-server 2>&1 | Out-Null
Write-Host "`nPassed=$script:Pass Failed=$script:Fail"
exit $script:Fail
