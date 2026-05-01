$dumpPath = 'C:\Users\uniqu\AppData\Local\Temp\psmux_issue263_dump.json'
$json = Get-Content -Raw -Encoding UTF8 -Path $dumpPath
$obj = $json | ConvertFrom-Json

# Print all rows_v2 lines with their runs
$rowsV2 = $obj.layout.rows_v2
Write-Host "Total rows_v2 lines: $($rowsV2.Count)" -ForegroundColor Cyan

for ($i = 0; $i -lt $rowsV2.Count; $i++) {
    $row = $rowsV2[$i]
    $runs = $row.runs
    if (-not $runs -or $runs.Count -eq 0) { continue }
    # Skip empty rows
    $rowText = ($runs | ForEach-Object { $_.text }) -join ''
    if ([string]::IsNullOrWhiteSpace($rowText)) { continue }

    Write-Host "`n--- rows_v2[$i] (text length=$($rowText.Length)) ---" -ForegroundColor Yellow
    Write-Host "  Joined text: [$rowText]"

    for ($j = 0; $j -lt $runs.Count; $j++) {
        $run = $runs[$j]
        if ([string]::IsNullOrWhiteSpace($run.text)) { continue }
        $runJson = $run | ConvertTo-Json -Depth 5 -Compress
        Write-Host "    run[$j]: $runJson"
    }
}
