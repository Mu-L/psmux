# Feature: floating panes (tmux new-pane) - creation E2E.
#
# Drives a real psmux server: `new-pane` with an explicit position/size/border
# creates a floating pane over the active window. We assert the float appears
# in the live state JSON (dump-state) at the requested geometry. The actual
# glyph rendering is proven deterministically by tests-rs/test_floating_render.rs.
#
# Exit 0 = new-pane creates a float with the requested geometry.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S     = "flt_new_pane"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Stop-All {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    Start-Sleep -Milliseconds 250
    Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue
}

$failures = 0
function Check($label, $cond, $detail) {
    if ($cond) { Write-Host ("  PASS {0}: {1}" -f $label,$detail) -ForegroundColor Green }
    else       { Write-Host ("  FAIL {0}: {1}" -f $label,$detail) -ForegroundColor Red; $script:failures++ }
}

Stop-All
& $PSMUX new-session -d -s $S -x 100 -y 30 2>&1 | Out-Null
Start-Sleep -Seconds 2

# No float yet.
$before = (& $PSMUX dump-state 2>&1) -join ""
Check "baseline" (-not ($before -match '"floats"\s*:\s*\[\s*\{')) "no float before new-pane"

# Create a floating pane at an explicit position/size with a double border.
& $PSMUX new-pane -x 8 -y 4 -w 30 -h 10 -B double -T FLTTITLE 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$after = (& $PSMUX dump-state 2>&1) -join ""
Check "float-present" ($after -match '"floats"\s*:\s*\[\s*\{') "floats array present in state"
Check "float-x" ($after -match '"x"\s*:\s*8') "float x=8 in state"
Check "float-y" ($after -match '"y"\s*:\s*4') "float y=4 in state"
Check "float-w" ($after -match '"w"\s*:\s*30') "float w=30 in state"
Check "float-border" ($after -match '"border"\s*:\s*"double"') "border=double in state"
Check "float-title" ($after -match 'FLTTITLE') "title shipped in state"

# Position keyword form also creates a float.
& $PSMUX new-pane -P top-right -w 20 -h 6 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$after2 = (& $PSMUX dump-state 2>&1) -join ""
# top-right of a 100-wide window with a 20-wide float => x = 80.
Check "position-keyword" ($after2 -match '"x"\s*:\s*80') "top-right float anchored to x=80"

Stop-All

Write-Host ""
if ($failures -eq 0) { Write-Host "FLOATING new-pane CREATION PROVEN (geometry + border + title + -P)" -ForegroundColor Green; exit 0 }
else { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
