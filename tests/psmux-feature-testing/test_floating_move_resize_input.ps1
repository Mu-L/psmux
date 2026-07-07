# Feature: floating panes phases 3-4 - move / resize / input focus / kill.
#
# Drives a real psmux server and proves, via dump-state, that:
#  - new-pane -R moves the focused float right (x increases)
#  - resize-pane -R grows the focused float (w increases)
#  - send-keys typed into the focused float echoes into the float's content
#  - kill-pane closes the focused float
#
# Exit 0 = all pass.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S     = "flt_mri"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Stop-All {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 250
    Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
}
function DS { (& $PSMUX dump-state 2>&1) -join "" }

$failures = 0
function Check($label, $cond, $detail) {
    if ($cond) { Write-Host ("  PASS {0}: {1}" -f $label,$detail) -ForegroundColor Green }
    else       { Write-Host ("  FAIL {0}: {1}" -f $label,$detail) -ForegroundColor Red; $script:failures++ }
}
# Extract the first float's integer field value from state JSON.
function FloatField([string]$json, [string]$field) {
    $m = [regex]::Match($json, '"floats"\s*:\s*\[\s*\{[^}]*?"' + [regex]::Escape($field) + '"\s*:\s*(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value } else { return -1 }
}

Stop-All
& $PSMUX new-session -d -s $S -x 100 -y 30 2>&1 | Out-Null
Start-Sleep -Seconds 2

# Create a focused float at x=10.
& $PSMUX new-pane -x 10 -y 5 -w 30 -h 10 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
$x0 = FloatField (DS) "x"
Check "create" ($x0 -eq 10) "float created at x=$x0"

# Move right by 6 -> x should be 16.
& $PSMUX new-pane -R 6 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$x1 = FloatField (DS) "x"
Check "move-right" ($x1 -eq 16) "x moved $x0 -> $x1 (expected 16)"

# Move up by 3 -> y should be 2.
& $PSMUX new-pane -U 3 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$y1 = FloatField (DS) "y"
Check "move-up" ($y1 -eq 2) "y moved 5 -> $y1 (expected 2)"

# Resize: grow width by 8 -> w 30 -> 38.
& $PSMUX resize-pane -R 8 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
$w1 = FloatField (DS) "w"
Check "resize-grow" ($w1 -eq 38) "w grew 30 -> $w1 (expected 38)"

# Input: type into the focused float; its content should echo the text.
& $PSMUX send-keys -t $S "echo FLTECHO" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX send-keys -t $S Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 1200
$ds = DS
# The float's rows carry the echoed text (not the tiled pane).
$echoed = $ds -match 'FLTECHO'
Check "input-echo" $echoed "typed text appears in float content"

# Kill: close the focused float.
& $PSMUX kill-pane -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$after = DS
Check "kill" (-not ($after -match '"floats"\s*:\s*\[\s*\{')) "float removed by kill-pane"

Stop-All
Write-Host ""
if ($failures -eq 0) { Write-Host "FLOATING move/resize/input/kill PROVEN" -ForegroundColor Green; exit 0 }
else { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
