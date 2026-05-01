$dumpPath = 'C:\Users\uniqu\AppData\Local\Temp\psmux_issue263_dump.json'
$json = Get-Content -Raw -Encoding UTF8 -Path $dumpPath
$obj = $json | ConvertFrom-Json

# Print top-level keys
Write-Host "Top-level keys:" -ForegroundColor Cyan
$obj.PSObject.Properties | ForEach-Object { Write-Host "  $($_.Name) (type: $($_.Value.GetType().Name))" }

# Recursively find any string property containing │
$BAR = [char]0x2502
$results = New-Object System.Collections.Generic.List[object]

function Walk {
    param($node, [string]$path = '')
    if ($null -eq $node) { return }
    if ($node -is [System.Array]) {
        for ($i = 0; $i -lt $node.Count; $i++) { Walk $node[$i] "$path[$i]" }
        return
    }
    if ($node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $node.PSObject.Properties) {
            $childPath = "$path.$($p.Name)"
            if ($p.Value -is [string] -and $p.Value.Contains($BAR)) {
                $results.Add(@{ Path=$childPath; Value=$p.Value }) | Out-Null
            }
            Walk $p.Value $childPath
        }
        return
    }
}

Walk $obj 'root'

Write-Host "`n=== Strings containing U+2502 ===" -ForegroundColor Cyan
foreach ($r in $results) {
    $valShown = $r.Value
    if ($valShown.Length -gt 200) { $valShown = $valShown.Substring(0, 200) + '...' }
    Write-Host "  $($r.Path):" -ForegroundColor Yellow
    Write-Host "    [$valShown]"
}

# Also locate cells/cells-array with their fg
# Common psmux dump shape has windows/panes -> screen -> rows -> cells with ch+fg+bg
function Walk-Cells {
    param($node, [string]$path = '')
    if ($null -eq $node) { return }
    if ($node -is [System.Array]) {
        for ($i = 0; $i -lt $node.Count; $i++) { Walk-Cells $node[$i] "$path[$i]" }
        return
    }
    if ($node -is [System.Management.Automation.PSCustomObject]) {
        # Heuristic: an object with a 'ch' or 'char' property + 'fg'
        $names = $node.PSObject.Properties.Name
        if (($names -contains 'ch' -or $names -contains 'char' -or $names -contains 'c') -and ($names -contains 'fg' -or $names -contains 'foreground')) {
            $ch = if ($names -contains 'ch') { $node.ch } elseif ($names -contains 'char') { $node.char } else { $node.c }
            if ($ch -and "$ch".Contains($BAR)) {
                Write-Host "`n>>> CELL containing U+2502 found at $path" -ForegroundColor Green
                $node | ConvertTo-Json -Compress | Write-Host
            }
        }
        foreach ($p in $node.PSObject.Properties) {
            Walk-Cells $p.Value "$path.$($p.Name)"
        }
    }
}

Write-Host "`n=== Cells containing U+2502 (with fg/bg) ===" -ForegroundColor Cyan
Walk-Cells $obj 'root'
