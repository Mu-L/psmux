# Preview-stuck investigation: reproduce conditions where the preview
# pane in session/tree pickers stops updating when navigating with arrow keys.
#
# Strategy: create multiple sessions with distinct content, open pickers via
# WriteConsoleInput keystroke injection, navigate with arrows, then analyze
# the preview_debug.log to see whether the preview target changes.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$debugLog = "$psmuxDir\preview_debug.log"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    @("prev_alpha","prev_beta","prev_gamma","prev_delta","prev_epsilon","prev_main") | ForEach-Object {
        & $PSMUX kill-session -t $_ 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 1000
    @("prev_alpha","prev_beta","prev_gamma","prev_delta","prev_epsilon","prev_main") | ForEach-Object {
        Remove-Item "$psmuxDir\$_.*" -Force -EA SilentlyContinue
    }
}

# Compile the injector
$injectorExe = "$env:TEMP\psmux_injector.exe"
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (Test-Path "$PSScriptRoot\injector.cs") {
    & $csc /nologo /optimize /out:$injectorExe tests\injector.cs 2>&1 | Out-Null
    if (-not (Test-Path $injectorExe)) {
        Write-Host "FATAL: injector compilation failed" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "FATAL: tests\injector.cs not found" -ForegroundColor Red
    exit 1
}

Write-Host "`n=== Preview Stuck Investigation ===" -ForegroundColor Cyan

# === SETUP: Create 5 sessions with very distinct content ===
Cleanup
Write-Host "`n[Setup] Creating 5 sessions with distinct content..." -ForegroundColor Yellow

$sessions = @("prev_alpha","prev_beta","prev_gamma","prev_delta","prev_epsilon")
foreach ($s in $sessions) {
    & $PSMUX new-session -d -s $s 2>&1 | Out-Null
    Start-Sleep -Seconds 2
}

# Put distinct content in each session
& $PSMUX send-keys -t prev_alpha "echo '=== ALPHA ALPHA ALPHA ==='" Enter 2>&1 | Out-Null
& $PSMUX send-keys -t prev_beta "echo '=== BETA BETA BETA ==='" Enter 2>&1 | Out-Null
& $PSMUX send-keys -t prev_gamma "echo '=== GAMMA GAMMA GAMMA ==='" Enter 2>&1 | Out-Null
& $PSMUX send-keys -t prev_delta "echo '=== DELTA DELTA DELTA ==='" Enter 2>&1 | Out-Null
& $PSMUX send-keys -t prev_epsilon "echo '=== EPSILON EPSILON EPSILON ==='" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2

# Verify all sessions exist
$allExist = $true
foreach ($s in $sessions) {
    & $PSMUX has-session -t $s 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Session $s not created"
        $allExist = $false
    }
}
if ($allExist) { Write-Pass "All 5 sessions created" }

# === SCENARIO 1: Session chooser (Ctrl+B s) with preview + arrow navigation ===
Write-Host "`n[Scenario 1] Session chooser: open, toggle preview, navigate down 4 times" -ForegroundColor Yellow

# Launch an attached session for TUI interaction
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","prev_main" -PassThru
Start-Sleep -Seconds 4

# Clear old debug log
Remove-Item $debugLog -Force -EA SilentlyContinue

# Open session chooser: prefix(Ctrl+B) + s
& $injectorExe $proc.Id "^b{SLEEP:400}s"
Start-Sleep -Seconds 2

# Toggle preview on: p
& $injectorExe $proc.Id "p"
Start-Sleep -Seconds 2

# Capture log state after opening + preview toggle
$logAfterOpen = if (Test-Path $debugLog) { Get-Content $debugLog -Raw } else { "" }
$openLines = ($logAfterOpen -split "`n" | Where-Object { $_ -match "session_chooser:" }).Count
Write-Host "    Preview renders after open+toggle: $openLines" -ForegroundColor DarkGray

# Navigate DOWN 4 times, with pauses between for the log to accumulate
for ($i = 1; $i -le 4; $i++) {
    & $injectorExe $proc.Id "{DOWN}"
    Start-Sleep -Seconds 2
}

# Read the log
$logAfterNav = if (Test-Path $debugLog) { Get-Content $debugLog -Raw } else { "" }
$navLines = $logAfterNav -split "`n" | Where-Object { $_ -match "session_chooser:" }
Write-Host "    Total preview renders: $($navLines.Count)" -ForegroundColor DarkGray

# Extract session_selected values to see if they changed
$selectedValues = @()
foreach ($line in $navLines) {
    if ($line -match 'session_selected=(\d+)') {
        $selectedValues += [int]$Matches[1]
    }
}

$uniqueSelected = $selectedValues | Sort-Object -Unique
Write-Host "    Unique session_selected values seen: $($uniqueSelected -join ', ')" -ForegroundColor DarkGray

if ($uniqueSelected.Count -ge 3) {
    Write-Pass "Preview updated for multiple selections (saw $($uniqueSelected.Count) distinct values)"
} else {
    Write-Fail "Preview may be STUCK: only saw $($uniqueSelected.Count) distinct session_selected values: $($uniqueSelected -join ', ')"
}

# Check dump targets
$dumpTargets = $logAfterNav -split "`n" | Where-Object { $_ -match "rendering dump for sess=" }
$dumpSessions = @()
foreach ($line in $dumpTargets) {
    if ($line -match 'sess=(\S+)') {
        $dumpSessions += $Matches[1]
    }
}
$uniqueDumps = $dumpSessions | Sort-Object -Unique
Write-Host "    Unique sessions rendered in preview: $($uniqueDumps -join ', ')" -ForegroundColor DarkGray

if ($uniqueDumps.Count -ge 2) {
    Write-Pass "Preview rendered different sessions: $($uniqueDumps -join ', ')"
} else {
    Write-Fail "Preview STUCK on one session: $($uniqueDumps -join ', ')"
}

# Check for fetch failures
$failures = $logAfterNav -split "`n" | Where-Object { $_ -match "DUMP FETCH FAILED|NO win_id|FALLBACK" }
if ($failures.Count -gt 0) {
    Write-Host "    Preview failures detected:" -ForegroundColor Yellow
    $failures | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
}

# Close the picker
& $injectorExe $proc.Id "{ESC}"
Start-Sleep -Seconds 1

# === SCENARIO 2: Rapid arrow key navigation (potential race condition) ===
Write-Host "`n[Scenario 2] Session chooser: rapid arrow navigation (no pause between keys)" -ForegroundColor Yellow

# Clear log
Remove-Item $debugLog -Force -EA SilentlyContinue

# Open session chooser + preview
& $injectorExe $proc.Id "^b{SLEEP:400}s"
Start-Sleep -Seconds 2
& $injectorExe $proc.Id "p"
Start-Sleep -Seconds 1

# Rapid: 4 DOWN keys with only 100ms sleep between (via SLEEP in injector)
& $injectorExe $proc.Id "{DOWN}{SLEEP:100}{DOWN}{SLEEP:100}{DOWN}{SLEEP:100}{DOWN}"
Start-Sleep -Seconds 3

$logRapid = if (Test-Path $debugLog) { Get-Content $debugLog -Raw } else { "" }
$rapidSelected = @()
foreach ($line in ($logRapid -split "`n" | Where-Object { $_ -match "session_chooser:" })) {
    if ($line -match 'session_selected=(\d+)') {
        $rapidSelected += [int]$Matches[1]
    }
}
$rapidUnique = $rapidSelected | Sort-Object -Unique
Write-Host "    Unique session_selected in rapid mode: $($rapidUnique -join ', ')" -ForegroundColor DarkGray

$rapidDumps = @()
foreach ($line in ($logRapid -split "`n" | Where-Object { $_ -match "rendering dump for sess=" })) {
    if ($line -match 'sess=(\S+)') {
        $rapidDumps += $Matches[1]
    }
}
$rapidDumpUnique = $rapidDumps | Sort-Object -Unique
Write-Host "    Unique sessions rendered (rapid): $($rapidDumpUnique -join ', ')" -ForegroundColor DarkGray

if ($rapidDumpUnique.Count -ge 2) {
    Write-Pass "Rapid navigation: preview rendered different sessions"
} else {
    Write-Fail "Rapid navigation: preview STUCK on one session: $($rapidDumpUnique -join ', ')"
}

& $injectorExe $proc.Id "{ESC}"
Start-Sleep -Seconds 1

# === SCENARIO 3: Tree chooser (Ctrl+B w) ===
Write-Host "`n[Scenario 3] Tree chooser (Ctrl+B w): preview + navigation" -ForegroundColor Yellow

Remove-Item $debugLog -Force -EA SilentlyContinue

& $injectorExe $proc.Id "^b{SLEEP:400}w"
Start-Sleep -Seconds 2
& $injectorExe $proc.Id "p"
Start-Sleep -Seconds 1

# Navigate down through tree entries
for ($i = 1; $i -le 6; $i++) {
    & $injectorExe $proc.Id "{DOWN}"
    Start-Sleep -Seconds 1
}

$logTree = if (Test-Path $debugLog) { Get-Content $debugLog -Raw } else { "" }
$treeSelected = @()
foreach ($line in ($logTree -split "`n" | Where-Object { $_ -match "tree_chooser:" })) {
    if ($line -match 'tree_selected=(\d+)') {
        $treeSelected += [int]$Matches[1]
    }
}
$treeUnique = $treeSelected | Sort-Object -Unique
Write-Host "    Unique tree_selected values: $($treeUnique -join ', ')" -ForegroundColor DarkGray

# Check which sessions were rendered
$treeDumps = @()
foreach ($line in ($logTree -split "`n" | Where-Object { $_ -match "rendering dump for sess=|tree_chooser:.*sess=" })) {
    if ($line -match 'sess=(\S+)') {
        $treeDumps += $Matches[1]
    }
}
$treeDumpUnique = $treeDumps | Sort-Object -Unique
Write-Host "    Unique sessions rendered in tree: $($treeDumpUnique -join ', ')" -ForegroundColor DarkGray

if ($treeUnique.Count -ge 4) {
    Write-Pass "Tree chooser: selection moved through $($treeUnique.Count) entries"
} else {
    Write-Fail "Tree chooser: selection only moved through $($treeUnique.Count) entries"
}

& $injectorExe $proc.Id "{ESC}"
Start-Sleep -Seconds 1

# === SCENARIO 4: Toggle preview off/on while navigating ===
Write-Host "`n[Scenario 4] Session chooser: navigate, toggle preview off/on, check update" -ForegroundColor Yellow

Remove-Item $debugLog -Force -EA SilentlyContinue

# Open session chooser
& $injectorExe $proc.Id "^b{SLEEP:400}s"
Start-Sleep -Seconds 2

# Enable preview
& $injectorExe $proc.Id "p"
Start-Sleep -Seconds 1

# Navigate down 2
& $injectorExe $proc.Id "{DOWN}{SLEEP:500}{DOWN}"
Start-Sleep -Seconds 1

# Toggle preview OFF then ON
& $injectorExe $proc.Id "p"
Start-Sleep -Milliseconds 500
& $injectorExe $proc.Id "p"
Start-Sleep -Seconds 2

# Navigate down 2 more
& $injectorExe $proc.Id "{DOWN}{SLEEP:500}{DOWN}"
Start-Sleep -Seconds 2

$logToggle = if (Test-Path $debugLog) { Get-Content $debugLog -Raw } else { "" }
$toggleSelected = @()
foreach ($line in ($logToggle -split "`n" | Where-Object { $_ -match "session_chooser:" })) {
    if ($line -match 'session_selected=(\d+)') {
        $toggleSelected += [int]$Matches[1]
    }
}
$toggleUnique = $toggleSelected | Sort-Object -Unique
Write-Host "    Unique session_selected after toggle: $($toggleUnique -join ', ')" -ForegroundColor DarkGray

# Check if the last renders are for a different session than the first
$toggleDumps = @()
foreach ($line in ($logToggle -split "`n" | Where-Object { $_ -match "rendering dump for sess=" })) {
    if ($line -match 'sess=(\S+)') {
        $toggleDumps += $Matches[1]
    }
}
$toggleDumpUnique = $toggleDumps | Sort-Object -Unique
Write-Host "    Sessions rendered after toggle: $($toggleDumpUnique -join ', ')" -ForegroundColor DarkGray

if ($toggleDumpUnique.Count -ge 2) {
    Write-Pass "Preview updated correctly after toggle cycle"
} else {
    Write-Fail "Preview stuck after toggle: only rendered $($toggleDumpUnique -join ', ')"
}

& $injectorExe $proc.Id "{ESC}"
Start-Sleep -Seconds 1

# === SCENARIO 5: choose-tree-preview option ON by default ===
Write-Host "`n[Scenario 5] Session chooser with choose-tree-preview ON (no manual p press)" -ForegroundColor Yellow

Remove-Item $debugLog -Force -EA SilentlyContinue

# Set the option
& $PSMUX set-option -g choose-tree-preview on -t prev_main 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Open session chooser (preview should be ON automatically)
& $injectorExe $proc.Id "^b{SLEEP:400}s"
Start-Sleep -Seconds 2

# Navigate down through sessions
for ($i = 1; $i -le 4; $i++) {
    & $injectorExe $proc.Id "{DOWN}"
    Start-Sleep -Seconds 1
}

$logDefault = if (Test-Path $debugLog) { Get-Content $debugLog -Raw } else { "" }
$defaultDumps = @()
foreach ($line in ($logDefault -split "`n" | Where-Object { $_ -match "rendering dump for sess=" })) {
    if ($line -match 'sess=(\S+)') {
        $defaultDumps += $Matches[1]
    }
}
$defaultDumpUnique = $defaultDumps | Sort-Object -Unique
Write-Host "    Sessions rendered (auto-preview): $($defaultDumpUnique -join ', ')" -ForegroundColor DarkGray

if ($defaultDumpUnique.Count -ge 2) {
    Write-Pass "Auto-preview rendered different sessions"
} else {
    Write-Fail "Auto-preview stuck: $($defaultDumpUnique -join ', ')"
}

& $injectorExe $proc.Id "{ESC}"
Start-Sleep -Seconds 1

# === SCENARIO 6: hjkl navigation (the recent change) ===
Write-Host "`n[Scenario 6] Session chooser: hjkl navigation with preview" -ForegroundColor Yellow

Remove-Item $debugLog -Force -EA SilentlyContinue

& $injectorExe $proc.Id "^b{SLEEP:400}s"
Start-Sleep -Seconds 2

# Navigate with j (down) 4 times
for ($i = 1; $i -le 4; $i++) {
    & $injectorExe $proc.Id "j"
    Start-Sleep -Seconds 1
}

$logHjkl = if (Test-Path $debugLog) { Get-Content $debugLog -Raw } else { "" }
$hjklSelected = @()
foreach ($line in ($logHjkl -split "`n" | Where-Object { $_ -match "session_chooser:" })) {
    if ($line -match 'session_selected=(\d+)') {
        $hjklSelected += [int]$Matches[1]
    }
}
$hjklUnique = $hjklSelected | Sort-Object -Unique
Write-Host "    Unique session_selected via j key: $($hjklUnique -join ', ')" -ForegroundColor DarkGray

$hjklDumps = @()
foreach ($line in ($logHjkl -split "`n" | Where-Object { $_ -match "rendering dump for sess=" })) {
    if ($line -match 'sess=(\S+)') {
        $hjklDumps += $Matches[1]
    }
}
$hjklDumpUnique = $hjklDumps | Sort-Object -Unique
Write-Host "    Sessions rendered via j navigation: $($hjklDumpUnique -join ', ')" -ForegroundColor DarkGray

if ($hjklDumpUnique.Count -ge 2) {
    Write-Pass "hjkl navigation: preview rendered different sessions"
} else {
    Write-Fail "hjkl navigation: preview stuck: $($hjklDumpUnique -join ', ')"
}

& $injectorExe $proc.Id "{ESC}"
Start-Sleep -Seconds 1

# === CLEANUP ===
& $PSMUX kill-session -t prev_main 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })

# Dump the full debug log for analysis
Write-Host "`n=== Full Preview Debug Log ===" -ForegroundColor Magenta
if (Test-Path $debugLog) {
    $fullLog = Get-Content $debugLog -Raw
    Write-Host $fullLog
    Write-Host "`nLog size: $((Get-Item $debugLog).Length) bytes" -ForegroundColor DarkGray
} else {
    Write-Host "(no log file found - preview was never rendered?)" -ForegroundColor Red
}

exit $script:TestsFailed
