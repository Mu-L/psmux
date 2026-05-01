# Issue #266 — automatic-rename overrides explicit -n NAME
#
# Bug claim (3.3.4):
#   `psmux new-session -d -s X -n my_explicit_name`
#   then list-windows shows "my_explicit_name" replaced by active process name
#   (e.g. "python" or "pwsh"). automatic-rename is ON when it should be OFF
#   for windows born with an explicit -n.
#
# tmux behavior (the spec): when -n is supplied, that window's
# automatic-rename is implicitly disabled and the explicit name persists
# regardless of which process is active in the pane.
#
# Test plan:
#   1. CASE A: new-session -d -s S -n explicit_alpha
#      - Read window_name immediately + after 5s (let any rename loop fire)
#      - Read window-option automatic-rename for that window
#      - Send a long-running process (Start-Sleep) so active cmd is distinct
#      - Read window_name again — must still equal explicit_alpha
#
#   2. CASE B: new-window -t S -n explicit_beta
#      - Same checks
#
#   3. CASE C (control): new-window -t S (NO -n)
#      - automatic-rename should be ON; window_name should reflect active cmd
#      - Confirms the rename mechanism IS working — not just inactive globally
#
# Verification methods:
#   - display-message -p '#{window_name}' over time
#   - show-options -w automatic-rename per target window
#   - dump-state JSON: look for "manual_rename" cell in window struct
#
# Verdict matrix:
#   - Explicit-name windows keep their name AND have automatic-rename off
#     (or manual_rename=true) -> bug NOT present
#   - Explicit-name windows lose their name OR have automatic-rename on
#     -> bug REPRODUCES exactly as reported

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$VERSION = (& $PSMUX -V).Trim()
$SESSION = "issue266"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0; $script:Fail = 0

function Write-Pass($m) { Write-Host "  [PASS] $m" -F Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -F Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -F DarkCyan }

# Cleanup
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host "`n=== Issue #266 EXPLICIT-NAME OVERRIDE PROOF ===" -F Cyan
Write-Host "  Build under test: $VERSION"
Write-Host "  Issue reports:    psmux 3.3.4"
Write-Host "  Spec: -n NAME must persist; automatic-rename should be OFF for that window"
Write-Host ""

# === CASE A: new-session -n explicit_alpha ===
Write-Host "[CASE A] new-session -d -s $SESSION -n explicit_alpha" -F Yellow
& $PSMUX new-session -d -s $SESSION -n explicit_alpha 2>&1 | Out-Null
Start-Sleep -Seconds 3

# T+0
$nameT0 = (& $PSMUX display-message -t "${SESSION}:0" -p '#{window_name}' 2>&1).Trim()
$autoT0 = (& $PSMUX show-options -w -v automatic-rename -t "${SESSION}:0" 2>&1 | Out-String).Trim()
Write-Info "T+0: window_name='$nameT0'  automatic-rename='$autoT0'"

# Run a long-lived process to make sure active cmd is something specific
& $PSMUX send-keys -t "${SESSION}:0" 'Start-Sleep -Seconds 30' Enter
Start-Sleep -Seconds 3

# T+3 (post-process-launch)
$nameT3 = (& $PSMUX display-message -t "${SESSION}:0" -p '#{window_name}' 2>&1).Trim()
$paneCmdT3 = (& $PSMUX display-message -t "${SESSION}:0" -p '#{pane_current_command}' 2>&1).Trim()
Write-Info "T+3: window_name='$nameT3'  pane_current_command='$paneCmdT3'"

Start-Sleep -Seconds 5
$nameT8 = (& $PSMUX display-message -t "${SESSION}:0" -p '#{window_name}' 2>&1).Trim()
$paneCmdT8 = (& $PSMUX display-message -t "${SESSION}:0" -p '#{pane_current_command}' 2>&1).Trim()
Write-Info "T+8: window_name='$nameT8'  pane_current_command='$paneCmdT8'"

if ($nameT0 -eq "explicit_alpha") { Write-Pass "A.1 initial name preserved at T+0" }
else { Write-Fail "A.1 initial name expected 'explicit_alpha', got '$nameT0'" }

if ($nameT3 -eq "explicit_alpha") { Write-Pass "A.2 name preserved after process spawn (T+3)" }
else { Write-Fail "A.2 name expected 'explicit_alpha', got '$nameT3' -- BUG: explicit -n was overwritten" }

if ($nameT8 -eq "explicit_alpha") { Write-Pass "A.3 name preserved after wait (T+8)" }
else { Write-Fail "A.3 name expected 'explicit_alpha', got '$nameT8' -- BUG: explicit -n was overwritten" }

if ($autoT0 -eq "off") { Write-Pass "A.4 automatic-rename is 'off' for window with explicit -n" }
else { Write-Fail "A.4 automatic-rename expected 'off', got '$autoT0' -- BUG: should be off for explicit-name windows" }

# === CASE B: new-window -t S -n explicit_beta ===
Write-Host "`n[CASE B] new-window -t $SESSION -n explicit_beta" -F Yellow
& $PSMUX new-window -t $SESSION -n explicit_beta 2>&1 | Out-Null
Start-Sleep -Seconds 3

# Find which window index it landed on (likely :1)
$winListB = & $PSMUX list-windows -t $SESSION -F '#{window_index}|#{window_name}' 2>&1 | Out-String
Write-Info "list-windows after new-window:`n$winListB"

$nameBT0 = (& $PSMUX display-message -t "${SESSION}:1" -p '#{window_name}' 2>&1).Trim()
$autoBT0 = (& $PSMUX show-options -w -v automatic-rename -t "${SESSION}:1" 2>&1 | Out-String).Trim()
Write-Info "T+0: window_name='$nameBT0'  automatic-rename='$autoBT0'"

& $PSMUX send-keys -t "${SESSION}:1" 'Start-Sleep -Seconds 30' Enter
Start-Sleep -Seconds 3
$nameBT3 = (& $PSMUX display-message -t "${SESSION}:1" -p '#{window_name}' 2>&1).Trim()
Write-Info "T+3: window_name='$nameBT3'"

Start-Sleep -Seconds 5
$nameBT8 = (& $PSMUX display-message -t "${SESSION}:1" -p '#{window_name}' 2>&1).Trim()
Write-Info "T+8: window_name='$nameBT8'"

if ($nameBT0 -eq "explicit_beta") { Write-Pass "B.1 initial name preserved at T+0" }
else { Write-Fail "B.1 initial name expected 'explicit_beta', got '$nameBT0'" }

if ($nameBT3 -eq "explicit_beta") { Write-Pass "B.2 name preserved after process spawn (T+3)" }
else { Write-Fail "B.2 name expected 'explicit_beta', got '$nameBT3' -- BUG" }

if ($nameBT8 -eq "explicit_beta") { Write-Pass "B.3 name preserved after wait (T+8)" }
else { Write-Fail "B.3 name expected 'explicit_beta', got '$nameBT8' -- BUG" }

if ($autoBT0 -eq "off") { Write-Pass "B.4 automatic-rename is 'off' for window with explicit -n" }
else { Write-Fail "B.4 automatic-rename expected 'off', got '$autoBT0' -- BUG" }

# === CASE C (CONTROL): new-window WITHOUT -n ===
Write-Host "`n[CASE C — CONTROL] new-window -t $SESSION  (no -n flag)" -F Yellow
& $PSMUX new-window -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 3

$autoCT0 = (& $PSMUX show-options -w -v automatic-rename -t "${SESSION}:2" 2>&1 | Out-String).Trim()
$nameCT0 = (& $PSMUX display-message -t "${SESSION}:2" -p '#{window_name}' 2>&1).Trim()
Write-Info "T+0: window_name='$nameCT0'  automatic-rename='$autoCT0'"

if ($autoCT0 -ne "off") { Write-Pass "C.1 automatic-rename ON for window without -n (control: rename mechanism is active)" }
else { Write-Fail "C.1 automatic-rename should be ON for windows born without -n; got '$autoCT0'" }

# === DUMP STATE: look for manual_rename flag ===
Write-Host "`n[DUMP-STATE] inspecting windows.manual_rename flags" -F Yellow
$port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
$key = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
$tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
$tcp.NoDelay = $true; $tcp.ReceiveTimeout = 10000
$st = $tcp.GetStream()
$wr = [System.IO.StreamWriter]::new($st); $wr.AutoFlush = $true
$rd = [System.IO.StreamReader]::new($st)
$wr.Write("AUTH $key`n")
$null = $rd.ReadLine()
$wr.Write("PERSISTENT`n")
$wr.Write("dump-state`n")
$tcp.ReceiveTimeout = 3000
$dump = $null
for ($i = 0; $i -lt 50; $i++) {
    try { $line = $rd.ReadLine() } catch { break }
    if ($null -eq $line) { break }
    if ($line.Length -gt 100 -and $line.StartsWith("{")) { $dump = $line; break }
}
$tcp.Close()

if ($dump) {
    $obj = $dump | ConvertFrom-Json
    $wins = $obj.windows
    if ($wins) {
        for ($i = 0; $i -lt $wins.Count; $i++) {
            $w = $wins[$i]
            $manRen = if ($w.PSObject.Properties.Name -contains 'manual_rename') { $w.manual_rename } else { '<missing>' }
            $name = $w.name
            Write-Info "  window[$i]: name='$name'  manual_rename=$manRen"
        }
    } else {
        Write-Info "  no windows array in dump"
    }
} else {
    Write-Info "  dump-state failed; skipping"
}

# === Cleanup ===
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null

Write-Host "`n============================================" -F Cyan
Write-Host "VERDICT" -F Cyan
Write-Host "============================================" -F Cyan
Write-Host "  Pass: $($script:Pass)"
Write-Host "  Fail: $($script:Fail)"
Write-Host ""

if ($script:Fail -eq 0) {
    Write-Host "  >>> BUG IS NOT PRESENT in $VERSION" -F Green
    Write-Host "      -n NAME persists across pane process changes."
    Write-Host "      automatic-rename is OFF for explicit-name windows,"
    Write-Host "      ON for control window (rename mechanism works correctly)."
    exit 0
} else {
    Write-Host "  >>> BUG REPRODUCES in $VERSION" -F Red
    Write-Host "      Explicit -n names were overwritten by automatic rename."
    Write-Host "      This matches issue #266 exactly."
    exit 1
}
