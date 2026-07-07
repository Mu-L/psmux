# Issue #443: capture-pane -p drops cells skipped by cursor-forward (CUF, ESC[nC),
# collapsing words. Root cause: a never-written grid cell reports empty contents(),
# so the capture serializer emitted nothing for it instead of a space. Fixed in
# src/copy_mode.rs (push_capture_cell) for the -p, range, and -e (styled) paths.
#
# The payload is emitted from a script file (tests/payload_issue443_cuf.ps1) rather
# than through send-keys, because send-keys collapses interior whitespace in its
# argument and would confound the capture assertions.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux).Source
$S = "test_issue443"
$payload = Join-Path $PSScriptRoot "payload_issue443_cuf.ps1"

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $S -x 80 -y 24
Start-Sleep -Seconds 3
& $PSMUX send-keys -t $S 'clear' Enter
Start-Sleep -Seconds 1
& $PSMUX send-keys -t $S "chcp 65001 > `$null; [Console]::OutputEncoding=[Text.Encoding]::UTF8; powershell -NoProfile -ExecutionPolicy Bypass -File `"$payload`"" Enter
Start-Sleep -Seconds 3

$pass = 0; $fail = 0
function Check($name,$got,$want){
  if ($got -ceq $want) { Write-Host ("[PASS] {0}" -f $name) -ForegroundColor Green; $script:pass++ }
  else { Write-Host ("[FAIL] {0}: got=[{1}] want=[{2}]" -f $name, ($got -replace ' ','.'), ($want -replace ' ','.')) -ForegroundColor Red; $script:fail++ }
}

# Plain -p
$cap = & $PSMUX capture-pane -t $S -p
$g=@{}; $cap | ForEach-Object { if($_ -match "^SPCA"){$g.SPC=$_}elseif($_ -match "^CUFA"){$g.CUF=$_}elseif($_ -match "^CHAA"){$g.CHA=$_}elseif($_ -match "^WIDE:"){$g.WIDE=$_} }
Write-Host "--- capture-pane -p ---"
Check "CUF gaps (4 spaces each)" $g.CUF "CUFA    CUFB    CUFC    CUFD"
Check "CHA gaps (5 then 6 spaces)" $g.CHA "CHAA     CHAB      CHAC"
Check "literal spaces intact" $g.SPC "SPCA    SPCB    SPCC"

# Wide/CJK regression guard (issue #441): the two CJK glyphs must sit adjacent
# with NO phantom space between or around them. Assert via space-free structure
# rather than a literal CJK string, since the outer console may not encode CJK
# (it would ?-substitute the expected literal and give a false failure).
$wideNoSpace = ($g.WIDE -notmatch ' ') -and ($g.WIDE.StartsWith("WIDE:")) -and ($g.WIDE.EndsWith(":END"))
if ($wideNoSpace) { Write-Host "[PASS] wide/CJK no phantom spaces (#441 guard)" -ForegroundColor Green; $pass++ }
else { Write-Host ("[FAIL] wide/CJK: got=[{0}]" -f ($g.WIDE -replace ' ','.')) -ForegroundColor Red; $fail++ }

# Styled -e : strip SGR, verify structural spacing on the CUF line is preserved too
$cape = & $PSMUX capture-pane -t $S -p -e
$cufe = ($cape | Where-Object { $_ -match "CUFA" }) -replace "$([char]27)\[[0-9;]*m",""
Write-Host "--- capture-pane -e (SGR-stripped) ---"
Check "CUF gaps preserved in -e" $cufe "CUFA    CUFB    CUFC    CUFD"

Write-Host "`nRESULT: PASS=$pass FAIL=$fail"
& $PSMUX kill-session -t $S 2>&1 | Out-Null
exit $fail
