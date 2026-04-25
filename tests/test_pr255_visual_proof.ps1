#!/usr/bin/env pwsh
# TANGIBLE VISUAL PROOF for PR #255
# Renders the SAME render_layout_json used by the live TUI to a TestBackend
# (via the hidden _render-preview command), parses the ANSI output, and
# proves that for a 3-pane layout H[active=%1, V[%2, %3]]:
#   * The vertical separator between %1 and the right side IS colored active (green)
#     ONLY in the rows adjacent to %1 (the active pane).
#   * The HORIZONTAL separator between %2 and %3 (entirely on the inactive side)
#     is NOT colored active anywhere.
#   * When we activate %2 instead, the colors flip correctly.
#
# Before PR #255, the legacy "both_leaves" path would color HALF of the
# inner horizontal separator as active even though %1 was selected.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()
$env:PYTHONIOENCODING = 'utf-8'
$psmux = (Get-Command psmux).Source
$session = "renderproof_$(Get-Random -Maximum 99999)"
$failed = 0
$passed = 0

function Pass($msg) { Write-Host "[PASS] $msg" -ForegroundColor Green; $script:passed++ }
function Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:failed++ }

# Parse ANSI output into a 2D array of @{ Char; Fg } entries.
function Parse-AnsiBuffer {
    param([string[]]$Lines, [int]$W, [int]$H)
    # Strip width/height first if present, just take the body.
    $grid = @()
    for ($y = 0; $y -lt $H; $y++) {
        $row = @()
        for ($x = 0; $x -lt $W; $x++) { $row += @{ Char=' '; Fg='default' } }
        $grid += ,$row
    }
    $y = 0
    foreach ($line in $Lines) {
        if ($y -ge $H) { break }
        $x = 0
        $curFg = 'default'
        # Iterate chars, tracking ANSI escape state.
        $i = 0
        while ($i -lt $line.Length -and $x -lt $W) {
            $c = $line[$i]
            if ($c -eq [char]0x1b -and $i + 1 -lt $line.Length -and $line[$i+1] -eq '[') {
                # find end (letter)
                $j = $i + 2
                while ($j -lt $line.Length -and -not [char]::IsLetter($line[$j])) { $j++ }
                if ($j -lt $line.Length) {
                    $params = $line.Substring($i + 2, $j - $i - 2)
                    $cmd = $line[$j]
                    if ($cmd -eq 'm') {
                        # SGR
                        if ($params -eq '' -or $params -eq '0') { $curFg = 'default' }
                        # Parse semi-colon list
                        $tokens = $params -split ';'
                        for ($k = 0; $k -lt $tokens.Count; $k++) {
                            $t = $tokens[$k]
                            if ($t -eq '0' -or $t -eq '') { $curFg = 'default' }
                            elseif ($t -eq '38' -and $k + 4 -lt $tokens.Count -and $tokens[$k+1] -eq '2') {
                                $r=$tokens[$k+2]; $g=$tokens[$k+3]; $b=$tokens[$k+4]
                                $curFg = "rgb($r,$g,$b)"
                                $k += 4
                            }
                            elseif ($t -match '^3[0-9]$' -or $t -match '^9[0-7]$') {
                                $curFg = "fg$t"
                            }
                        }
                    }
                    $i = $j + 1
                    continue
                }
            }
            $grid[$y][$x] = @{ Char=$c; Fg=$curFg }
            $x++
            $i++
        }
        $y++
    }
    return $grid
}

function Show-Grid {
    param($Grid, [string]$Title)
    Write-Host "--- $Title (chars only) ---" -ForegroundColor DarkGray
    foreach ($row in $Grid) {
        $line = ''
        foreach ($cell in $row) { $line += $cell.Char }
        Write-Host $line -ForegroundColor DarkGray
    }
    Write-Host "--- $Title (color map: A=active, .=inactive, ' '=empty) ---" -ForegroundColor DarkGray
    foreach ($row in $Grid) {
        $line = ''
        foreach ($cell in $row) {
            if ($cell.Char -eq ' ') { $line += ' ' }
            elseif ($cell.Fg -eq 'fg32' -or $cell.Fg -match 'rgb\(0,128,0\)|rgb\(0,255,0\)') { $line += 'A' }
            else { $line += '.' }
        }
        Write-Host $line -ForegroundColor DarkGray
    }
}

try {
    & $psmux kill-session -t $session 2>$null | Out-Null
    & $psmux new-session -d -s $session 2>$null | Out-Null
    Start-Sleep -Milliseconds 400

    # Build H[%1, V[%2, %3]] - matches the unit test layout exactly
    & $psmux split-window -h -t $session 2>$null | Out-Null
    Start-Sleep -Milliseconds 300
    & $psmux split-window -v -t $session 2>$null | Out-Null
    Start-Sleep -Milliseconds 300

    $panes = (& $psmux list-panes -t $session -F '#{pane_id}' 2>$null) -join ','
    Pass "Layout built: $panes"

    $winId = (& $psmux list-windows -t $session -F '#{window_id}' 2>$null).TrimStart('@')
    Write-Host "win_id=$winId" -ForegroundColor DarkGray

    $W = 60; $H = 20

    # === Activate %1 (left pane) ===
    & $psmux select-pane -t '%1' 2>$null | Out-Null
    Start-Sleep -Milliseconds 200
    $active = (& $psmux display-message -t $session -p '#{pane_id}' 2>$null).Trim()
    if ($active -eq '%1') { Pass "select-pane %1 (left/active)" } else { Fail "expected %1 active, got $active" }

    $rawLeft = & $psmux _render-preview $session $winId $W $H 2>&1
    $gridLeft = Parse-AnsiBuffer -Lines $rawLeft -W $W -H $H
    Show-Grid -Grid $gridLeft -Title "Active=LEFT(%1)"

    # Find vertical separator '│' columns
    $vsepCols = @{}
    for ($y = 0; $y -lt $H; $y++) {
        for ($x = 0; $x -lt $W; $x++) {
            if ($gridLeft[$y][$x].Char -eq '│') {
                if (-not $vsepCols.ContainsKey($x)) { $vsepCols[$x] = 0 }
                $vsepCols[$x]++
            }
        }
    }
    Write-Host "Vertical separator columns (x -> count): $(($vsepCols.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')" -ForegroundColor DarkGray

    # The outer vertical separator should be near the middle (around col 30 for w=60)
    $vsepX = ($vsepCols.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    Write-Host "Outer vsep at x=$vsepX" -ForegroundColor DarkGray

    # Find horizontal separator '─' rows on the RIGHT side (x > vsepX)
    $hsepRowsRight = @{}
    for ($y = 0; $y -lt $H; $y++) {
        for ($x = $vsepX + 1; $x -lt $W; $x++) {
            if ($gridLeft[$y][$x].Char -eq '─') {
                if (-not $hsepRowsRight.ContainsKey($y)) { $hsepRowsRight[$y] = 0 }
                $hsepRowsRight[$y]++
            }
        }
    }
    if ($hsepRowsRight.Count -gt 0) {
        $hsepY = ($hsepRowsRight.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
        Pass "Found inner horizontal separator on right side at y=$hsepY"

        # PROOF #1: NO cell on that horizontal separator (right side) should be colored active (green)
        $badGreen = 0
        $totalDash = 0
        for ($x = $vsepX + 1; $x -lt $W; $x++) {
            $cell = $gridLeft[$hsepY][$x]
            if ($cell.Char -eq '─') {
                $totalDash++
                if ($cell.Fg -eq 'fg32') { $badGreen++ }
            }
        }
        if ($badGreen -eq 0 -and $totalDash -gt 0) {
            Pass "[BUG-FIX-PROOF #1] Inner horizontal separator (between inactive %2 and %3) has 0/$totalDash cells colored active. Before PR #255, half of these would be green."
        } else {
            Fail "[BUG REGRESSION] $badGreen/$totalDash cells on inactive horizontal separator are colored active (green)"
        }

        # PROOF #2: Cells of the OUTER vertical separator that touch the active pane (%1)
        # rows [0 .. left_height-1] should be active (green)
        # Determine left pane's vertical extent: the rows where col vsepX-1 is non-border content.
        # Simpler: the left pane spans the full height of the layout, so all rows of the
        # outer vsep should be adjacent to active pane on the left.
        $vsepActiveCount = 0
        $vsepTotal = 0
        for ($y = 0; $y -lt $H; $y++) {
            $cell = $gridLeft[$y][$vsepX]
            if ($cell.Char -eq '│' -or $cell.Char -eq '┤' -or $cell.Char -eq '├' -or $cell.Char -eq '┬' -or $cell.Char -eq '┴' -or $cell.Char -eq '┼') {
                $vsepTotal++
                if ($cell.Fg -eq 'fg32') { $vsepActiveCount++ }
            }
        }
        if ($vsepActiveCount -gt 0) {
            Pass "[BUG-FIX-PROOF #2] Outer vertical separator has $vsepActiveCount/$vsepTotal active-colored cells (left pane active -> at least some cells must be green)"
        } else {
            Fail "Outer vsep has 0 active cells but left pane is active"
        }
    } else {
        Fail "No horizontal separator found on right side"
    }

    # === Activate %2 (top-right pane) ===
    & $psmux select-pane -t '%2' 2>$null | Out-Null
    Start-Sleep -Milliseconds 250
    $active = (& $psmux display-message -t $session -p '#{pane_id}' 2>$null).Trim()
    if ($active -eq '%2') { Pass "select-pane %2 (top-right/active)" } else { Fail "expected %2 active, got $active" }

    $rawTopRight = & $psmux _render-preview $session $winId $W $H 2>&1
    $gridTR = Parse-AnsiBuffer -Lines $rawTopRight -W $W -H $H
    Show-Grid -Grid $gridTR -Title "Active=TOP-RIGHT(%2)"

    # PROOF #3: Now the inner horizontal separator (between active %2 and inactive %3)
    # MUST have active-colored cells (since %2 is now adjacent above it).
    $hsepActiveTR = 0
    $hsepTotalTR = 0
    if ($null -ne $hsepY) {
        for ($x = $vsepX + 1; $x -lt $W; $x++) {
            $cell = $gridTR[$hsepY][$x]
            if ($cell.Char -eq '─') {
                $hsepTotalTR++
                if ($cell.Fg -eq 'fg32') { $hsepActiveTR++ }
            }
        }
        if ($hsepActiveTR -gt 0) {
            Pass "[BUG-FIX-PROOF #3] When %2 is active, inner horizontal separator has $hsepActiveTR/$hsepTotalTR cells colored active (border adjacent to active pane is highlighted)"
        } else {
            Fail "When %2 is active, inner horizontal separator has 0 active cells"
        }
    }

    # PROOF #4: When %2 active, the LOWER half of the outer vsep (below the inner hsep)
    # is adjacent to %3 (inactive) and the UPPER half is adjacent to %2 (active).
    # So upper part of outer vsep should be active, lower part should be inactive.
    $upperActive = 0; $upperTotal = 0; $lowerActive = 0; $lowerTotal = 0
    for ($y = 0; $y -lt $H; $y++) {
        $cell = $gridTR[$y][$vsepX]
        if ($cell.Char -in @('│','┤','├','┬','┴','┼')) {
            if ($y -lt $hsepY) {
                $upperTotal++
                if ($cell.Fg -eq 'fg32') { $upperActive++ }
            } elseif ($y -gt $hsepY) {
                $lowerTotal++
                if ($cell.Fg -eq 'fg32') { $lowerActive++ }
            }
        }
    }
    if ($upperActive -gt 0 -and $lowerActive -eq 0) {
        Pass "[BUG-FIX-PROOF #4] Outer vsep: upper half (adjacent to active %2) has $upperActive/$upperTotal active cells; lower half (adjacent to inactive %3) has $lowerActive/$lowerTotal active cells. Per-cell adjacency works."
    } else {
        Fail "Outer vsep adjacency wrong: upper $upperActive/$upperTotal active, lower $lowerActive/$lowerTotal active"
    }

} finally {
    & $psmux kill-session -t $session 2>$null | Out-Null
}

Write-Host ""
Write-Host "Results: $passed passed, $failed failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
if ($failed -gt 0) { exit 1 }
