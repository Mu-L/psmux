# Issue #434: Ghost-client leak + attached_clients over-decrement.
#
# Proves the invariant `session_attached` tracks the real client_registry across
# abnormal teardown paths:
#   - reader-EOF teardown (plain abnormal kill)
#   - writer-only teardown (client frozen/suspended so it stops reading its
#     socket while the server floods frames -> writer write-timeout path)
#   - reconnect churn (rapid attach/kill, some mid-handshake)
# In every case: no ghost record lingers and the attached counter never desyncs
# below the number of real clients.
#
# Requires a suspend/resume helper (NtSuspendProcess) to freeze a real attach
# client's socket reader and force the writer-only teardown path.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$dir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

# ---- build suspend helper ----
$suspSrc = "$env:TEMP\psmux_suspend434.cs"
@'
using System;
using System.Runtime.InteropServices;
class P {
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int a, bool i, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    static void Main(string[] a){
        int pid = int.Parse(a[0]);
        bool resume = a.Length > 1 && a[1] == "resume";
        IntPtr h = OpenProcess(0x1F0FFF, false, pid);
        if(h == IntPtr.Zero){ Console.WriteLine("open failed"); return; }
        int r = resume ? NtResumeProcess(h) : NtSuspendProcess(h);
        CloseHandle(h);
    }
}
'@ | Set-Content -Path $suspSrc -Encoding UTF8
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$susp = "$env:TEMP\psmux_suspend434.exe"
& $csc /nologo /optimize /out:$susp $suspSrc 2>&1 | Out-Null

function RealClientCount($s){
  @(& $PSMUX list-clients -t $s 2>&1 | Where-Object { $_ -match '/dev/pts/([1-9]\d*):' }).Count
}
function Attached($s){ (& $PSMUX display-message -t $s -p '#{session_attached}' 2>&1).Trim() }
function Cleanup($s){ & $PSMUX kill-session -t $s 2>&1 | Out-Null; Start-Sleep -Milliseconds 500; Remove-Item "$dir\$s.*" -Force -EA SilentlyContinue }

Write-Host "`n=== Issue #434: ghost-client / attached-count consistency ===" -ForegroundColor Cyan

# ============================================================
# TEST 1: writer-only teardown (suspend + flood) must not ghost/desync
# ============================================================
Write-Host "`n[Test 1] Writer-only teardown (frozen client + flood)" -ForegroundColor Yellow
$S = "iss434_writer"
Cleanup $S
& $PSMUX new-session -d -s $S; Start-Sleep -Seconds 3
$p = Start-Process -FilePath $PSMUX -ArgumentList "attach-session","-t",$S -PassThru -WindowStyle Minimized
Start-Sleep -Seconds 4
if ((Attached $S) -eq "1" -and (RealClientCount $S) -ge 1) { Write-Pass "client attached (attached=1)" }
else { Write-Fail "attach did not register (attached=$(Attached $S), clients=$(RealClientCount $S))" }

& $susp $p.Id | Out-Null           # freeze socket reader -> force writer path
Start-Sleep -Seconds 1
& $PSMUX send-keys -t $S "1..300000 | ForEach-Object { 'FLOOD_' + `$_ + '_' + ('x'*80) }" Enter
# wait for writer teardown to take effect
$desync = $false
for ($i=0; $i -lt 12; $i++) {
  Start-Sleep -Seconds 2
  $a = Attached $S; $rc = RealClientCount $S
  # DESYNC = attached reads 0 while a real (pts>=1) client record still lingers = ghost
  if ($a -eq "0" -and $rc -ge 1) { $desync = $true; break }
}
if (-not $desync) { Write-Pass "no ghost/desync during writer teardown (counter tracks registry)" }
else { Write-Fail "GHOST/DESYNC: attached=0 while a real client record lingers" }

# reconnect after resume must yield a counted client again
& $susp $p.Id resume | Out-Null
Start-Sleep -Seconds 3
if ((Attached $S) -eq "1" -and (RealClientCount $S) -ge 1) { Write-Pass "client reconnected & counted after resume" }
else { Write-Fail "reconnect failed (attached=$(Attached $S), clients=$(RealClientCount $S))" }
Stop-Process -Id $p.Id -Force -EA SilentlyContinue
Cleanup $S

# ============================================================
# TEST 2: abnormal kill (reader-EOF path) reaps cleanly
# ============================================================
Write-Host "`n[Test 2] Abnormal kill reaps cleanly (reader-EOF path)" -ForegroundColor Yellow
$S = "iss434_kill"
Cleanup $S
& $PSMUX new-session -d -s $S; Start-Sleep -Seconds 3
$p = Start-Process -FilePath $PSMUX -ArgumentList "attach-session","-t",$S -PassThru -WindowStyle Minimized
Start-Sleep -Seconds 4
$before = Attached $S
Stop-Process -Id $p.Id -Force -EA SilentlyContinue
Start-Sleep -Seconds 4
$after = Attached $S; $rc = RealClientCount $S
if ($before -eq "1" -and $after -eq "0" -and $rc -eq 0) { Write-Pass "1 -> 0 attached, 0 ghost records" }
else { Write-Fail "unexpected: before=$before after=$after ghosts=$rc" }
Cleanup $S

# ============================================================
# TEST 3: reconnect churn must not accumulate ghosts / desync
# ============================================================
Write-Host "`n[Test 3] 30x reconnect churn (some mid-handshake kills)" -ForegroundColor Yellow
$S = "iss434_churn"
Cleanup $S
& $PSMUX new-session -d -s $S; Start-Sleep -Seconds 3
$rng = [Random]::new(777)
for ($i=0; $i -lt 30; $i++) {
  $p = Start-Process -FilePath $PSMUX -ArgumentList "attach-session","-t",$S -PassThru -WindowStyle Minimized
  Start-Sleep -Milliseconds $rng.Next(40,1200)
  Stop-Process -Id $p.Id -Force -EA SilentlyContinue
}
Start-Sleep -Seconds 3
$a = Attached $S; $rc = RealClientCount $S
if ($a -eq "0" -and $rc -eq 0) { Write-Pass "no ghosts after churn (attached=0, 0 real records)" }
else { Write-Fail "churn left residue: attached=$a real_records=$rc" }

# sanity: a fresh attach after churn counts correctly (counter not stuck below 0)
$p = Start-Process -FilePath $PSMUX -ArgumentList "attach-session","-t",$S -PassThru -WindowStyle Minimized
Start-Sleep -Seconds 4
if ((Attached $S) -eq "1") { Write-Pass "fresh attach after churn counts to 1 (no stuck counter)" }
else { Write-Fail "post-churn attach shows attached=$(Attached $S)" }
Stop-Process -Id $p.Id -Force -EA SilentlyContinue
Cleanup $S

# ============================================================
# TEST 3b: comment-5027591125 scenario A -- a detached session that was
# NEVER attached must show ZERO list-clients rows (no synthesized pts/0 ghost).
# ============================================================
Write-Host "`n[Test 3b] Detached session (never attached) shows no client rows" -ForegroundColor Yellow
$S = "iss434_neverattach"
Cleanup $S
& $PSMUX new-session -d -s $S; Start-Sleep -Seconds 3
$rows = @(& $PSMUX list-clients -t $S 2>&1 | Where-Object { $_ -match ': ' + [regex]::Escape($S) + ':' })
$att  = Attached $S
if ($rows.Count -eq 0 -and $att -eq "0") {
  Write-Pass "never-attached session: 0 client rows AND session_attached=0"
} else {
  Write-Fail "ghost row on never-attached session: rows=$($rows.Count) [$($rows -join '|')] attached=$att"
}
Cleanup $S

# ============================================================
# TEST 3c: comment-5027591125 scenario B -- after a clean in-pane
# detach-client, the row must disappear (registry is the source of truth).
# ============================================================
Write-Host "`n[Test 3c] Clean detach-client leaves no residual row" -ForegroundColor Yellow
$S = "iss434_cleandetach"
Cleanup $S
& $PSMUX new-session -d -s $S; Start-Sleep -Seconds 3
$p = Start-Process -FilePath $PSMUX -ArgumentList "attach-session","-t",$S -PassThru -WindowStyle Minimized
Start-Sleep -Seconds 4
$dRows = @(& $PSMUX list-clients -t $S 2>&1 | Where-Object { $_ -match ': ' + [regex]::Escape($S) + ':' })
if ((Attached $S) -eq "1" -and $dRows.Count -eq 1) { Write-Pass "attached: exactly 1 row, attached=1" }
else { Write-Fail "attach state wrong: rows=$($dRows.Count) attached=$(Attached $S)" }
& $PSMUX detach-client -t $S 2>&1 | Out-Null
Start-Sleep -Seconds 3
$aRows = @(& $PSMUX list-clients -t $S 2>&1 | Where-Object { $_ -match ': ' + [regex]::Escape($S) + ':' })
$aAtt  = Attached $S
$pDead = -not (Get-Process -Id $p.Id -EA SilentlyContinue)
if ($aRows.Count -eq 0 -and $aAtt -eq "0" -and $pDead) {
  Write-Pass "after clean detach: 0 rows, attached=0, attach process exited"
} else {
  Write-Fail "residual after detach: rows=$($aRows.Count) [$($aRows -join '|')] attached=$aAtt procDead=$pDead"
}
Stop-Process -Id $p.Id -Force -EA SilentlyContinue
Cleanup $S

# ============================================================
# TEST 4 (TUI visual verification via CLI): live window stays functional
# ============================================================
Write-Host "`n[Test 4] Win32 TUI visual verification (CLI-driven)" -ForegroundColor Yellow
$S = "iss434_tui"
Cleanup $S
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$S -PassThru
Start-Sleep -Seconds 4
& $PSMUX split-window -v -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$panes = (& $PSMUX display-message -t $S -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes" } else { Write-Fail "TUI: panes=$panes" }
$a = Attached $S
if ($a -eq "1") { Write-Pass "TUI: the visible window counts as 1 attached client" } else { Write-Fail "TUI: attached=$a" }
& $PSMUX kill-session -t $S 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Cleanup $S

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
