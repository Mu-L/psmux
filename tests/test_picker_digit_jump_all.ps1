# Picker digit-jump parity (extends issue #247 from session picker to every
# other picker): choose-tree, choose-buffer, customize-mode.
#
# Each picker now supports the same UX as the session picker:
#   • digit keys append to a per-picker num_buffer
#   • Enter consumes the buffer as a 1-based index and jumps to that row
#   • Backspace edits the buffer
#   • Esc closes and clears the buffer
#   • a leak-guard catch-all absorbs other Char keys
#   • every visible row is rendered with a right-aligned 1-based number
#   • a "go to N" indicator is rendered when the buffer is non-empty
#
# All picker state lives client-side in src/client.rs (the same place where
# session_num_buffer was added by PR #248), so just like
# test_issue247_session_picker_digit.ps1 we can't observe the overlay via
# capture-pane or dump-state. We follow the same proof strategy:
#   1. Source-code proof of the state, the input handlers, and the
#      renderer for every picker.
#   2. Functional verification that the data sources each picker reads
#      from work end-to-end (window list, buffer list, customize options
#      over TCP), so a digit-jump has real rows to jump to.

$ErrorActionPreference = "Continue"
$script:pass = 0
$script:fail = 0
$script:results = @()

function Write-Test($msg) { Write-Host "  TEST: $msg" -ForegroundColor Yellow }
function Write-Pass($msg) { Write-Host "  PASS: $msg" -ForegroundColor Green; $script:pass++ }
function Write-Fail($msg) { Write-Host "  FAIL: $msg" -ForegroundColor Red; $script:fail++ }
function Add-Result($name, $ok, $detail) {
    if ($ok) { Write-Pass "$name $detail" } else { Write-Fail "$name $detail" }
    $script:results += [PSCustomObject]@{ Test = $name; Pass = $ok; Detail = $detail }
}

# ── Binary resolution ────────────────────────────────────────────
$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -ErrorAction SilentlyContinue).Path
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -ErrorAction SilentlyContinue).Path }
if (-not $PSMUX) {
    $cmd = Get-Command psmux -ErrorAction SilentlyContinue
    if ($cmd) { $PSMUX = $cmd.Source }
}
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

Write-Host "`n=== Picker digit-jump parity (tree / buffer / customize) ===" -ForegroundColor Cyan
Write-Host "  Binary: $PSMUX"

# ════════════════════════════════════════════════════════════════════
#  PART 1: Source-code proof
# ════════════════════════════════════════════════════════════════════

$srcFile = Join-Path $PSScriptRoot "..\src\client.rs"
if (-not (Test-Path $srcFile)) {
    Write-Fail "Source file not found at $srcFile"
    exit 1
}
$src = Get-Content $srcFile -Raw

# ── State declarations ─────────────────────────────────────────
Write-Test "State: tree_num_buffer declared"
Add-Result "tree_num_buffer declared" `
    ($src -match 'let\s+mut\s+tree_num_buffer\s*=\s*String::new\(\)') ""

Write-Test "State: buffer_num_buffer declared"
Add-Result "buffer_num_buffer declared" `
    ($src -match 'let\s+mut\s+buffer_num_buffer\s*=\s*String::new\(\)') ""

Write-Test "State: customize_num_buffer declared"
Add-Result "customize_num_buffer declared" `
    ($src -match 'let\s+mut\s+customize_num_buffer\s*=\s*String::new\(\)') ""

# ── Picker open clears the buffer ──────────────────────────────
Write-Test "Open clears tree_num_buffer when picker opens"
Add-Result "tree picker open clears buffer" `
    ($src -match '(?s)do_choose_tree\s*\{[^}]*tree_num_buffer\.clear\(\)') ""

Write-Test "Open clears buffer_num_buffer when picker opens"
Add-Result "buffer picker open clears buffer (CLI path)" `
    ($src -match '(?s)do_choose_buffer\s*\{[^}]*buffer_num_buffer\.clear\(\)') ""

# ── Digit handlers ─────────────────────────────────────────────
Write-Test "Handler: digit keys push into tree_num_buffer"
Add-Result "tree digit arm pushes into buffer" `
    ($src -match '(?s)KeyCode::Char\(c\)\s+if\s+tree_chooser\s+&&\s+c\.is_ascii_digit\(\)\s*=>\s*\{[^}]*tree_num_buffer\.push\(c\)') ""

Write-Test "Handler: digit keys push into buffer_num_buffer"
Add-Result "buffer digit arm pushes into buffer" `
    ($src -match '(?s)KeyCode::Char\(c\)\s+if\s+buffer_chooser\s+&&\s+c\.is_ascii_digit\(\)\s*=>\s*\{[^}]*buffer_num_buffer\.push\(c\)') ""

Write-Test "Handler: digit keys push into customize_num_buffer"
Add-Result "customize digit arm pushes into buffer" `
    ($src -match '(?s)KeyCode::Char\(c\)\s+if\s+c\.is_ascii_digit\(\)\s*=>\s*\{[^}]*customize_num_buffer\.push\(c\)') ""

# ── Enter parses buffer ────────────────────────────────────────
Write-Test "Enter parses tree_num_buffer as 1-based index"
Add-Result "tree Enter parses buffer" `
    ($src -match '(?s)KeyCode::Enter\s+if\s+tree_chooser.*?tree_num_buffer\.parse::<usize>\(\)') ""

Write-Test "Enter parses buffer_num_buffer as 1-based index"
Add-Result "buffer Enter parses buffer" `
    ($src -match '(?s)KeyCode::Enter\s+if\s+buffer_chooser.*?buffer_num_buffer\.parse::<usize>\(\)') ""

Write-Test "Enter parses customize_num_buffer as 1-based index"
Add-Result "customize Enter parses buffer" `
    ($src -match '(?s)customize_num_buffer\.parse::<usize>\(\)') ""

Write-Test "Customize Enter dispatches customize-navigate with computed delta"
Add-Result "customize Enter sends customize-navigate" `
    ($src -match '(?s)customize_num_buffer.*?format!\("customize-navigate \{\}\\n",\s*delta\)') ""

# ── Backspace ──────────────────────────────────────────────────
Write-Test "Backspace pops tree_num_buffer"
Add-Result "tree Backspace pops" `
    ($src -match 'KeyCode::Backspace\s+if\s+tree_chooser\s*=>\s*\{\s*tree_num_buffer\.pop\(\)') ""

Write-Test "Backspace pops buffer_num_buffer"
Add-Result "buffer Backspace pops" `
    ($src -match 'KeyCode::Backspace\s+if\s+buffer_chooser\s*=>\s*\{\s*buffer_num_buffer\.pop\(\)') ""

Write-Test "Backspace pops customize_num_buffer"
Add-Result "customize Backspace pops" `
    ($src -match 'KeyCode::Backspace\s*=>\s*\{\s*customize_num_buffer\.pop\(\)') ""

# ── Esc clears ─────────────────────────────────────────────────
Write-Test "Esc clears tree_num_buffer"
Add-Result "tree Esc clears buffer" `
    ($src -match '(?s)KeyCode::Esc\s+if\s+tree_chooser\s*=>\s*\{[^}]*tree_chooser\s*=\s*false;[^}]*tree_num_buffer\.clear\(\)') ""

Write-Test "Esc clears buffer_num_buffer"
Add-Result "buffer Esc clears buffer" `
    ($src -match '(?s)KeyCode::Esc\s*\|\s*KeyCode::Char\(.q.\)\s+if\s+buffer_chooser\s*=>\s*\{[^}]*buffer_chooser\s*=\s*false;[^}]*buffer_num_buffer\.clear\(\)') ""

Write-Test "Esc clears customize_num_buffer"
Add-Result "customize Esc clears buffer" `
    ($src -match '(?s)KeyCode::Esc\s*\|\s*KeyCode::Char\(.q.\)\s*=>\s*\{[^}]*customize_num_buffer\.clear\(\)') ""

# ── Leak guard catch-all ───────────────────────────────────────
Write-Test "Leak guard: catch-all absorbs Char keys while tree picker open"
Add-Result "tree leak-guard catch-all" `
    ($src -match 'KeyCode::Char\(_\)\s+if\s+tree_chooser\s*=>\s*\{\s*\}') ""

Write-Test "Leak guard: catch-all absorbs Char keys while buffer picker open"
Add-Result "buffer leak-guard catch-all" `
    ($src -match 'KeyCode::Char\(_\)\s+if\s+buffer_chooser\s*=>\s*\{\s*\}') ""

# ── Renderer: numbered prefix ──────────────────────────────────
Write-Test "Renderer: tree rows numbered with dynamic-width column"
Add-Result "tree row numbering uses dynamic width" `
    ($src -match '(?s)tree_chooser\s*\{.*?num_width\s*=\s*tree_entries\.len\(\)\.to_string\(\)\.len\(\)') ""

Write-Test "Renderer: buffer rows numbered with dynamic-width column"
Add-Result "buffer row numbering uses dynamic width" `
    ($src -match '(?s)buffer_chooser\s*\{.*?num_width\s*=\s*buffer_entries\.len\(\)\.to_string\(\)\.len\(\)') ""

Write-Test "Renderer: customize rows show 1-based jump position"
Add-Result "customize row numbering uses dynamic width" `
    ($src -match 'visible_pos\s*=\s*srv_customize_scroll\s*\+\s*row_idx\s*\+\s*1') ""

# ── Renderer: 'go to N' indicator ──────────────────────────────
Write-Test "Renderer: tree picker draws 'go to N' indicator"
Add-Result "tree 'go to N' indicator rendered" `
    ($src -match '(?s)if\s+!tree_num_buffer\.is_empty\(\).*?format!\("go to \{\}",\s*tree_num_buffer\)') ""

Write-Test "Renderer: buffer picker draws 'go to N' indicator"
Add-Result "buffer 'go to N' indicator rendered" `
    ($src -match '(?s)if\s+!buffer_num_buffer\.is_empty\(\).*?format!\("go to \{\}",\s*buffer_num_buffer\)') ""

Write-Test "Renderer: customize picker draws 'go to N' indicator"
Add-Result "customize 'go to N' indicator rendered" `
    ($src -match '(?s)if\s+!customize_num_buffer\.is_empty\(\).*?format!\(" go to \{\} ",\s*customize_num_buffer\)') ""

# ── Renderer: title hints advertise the workflow ───────────────
Write-Test "Renderer: tree picker title advertises digits+enter"
Add-Result "tree title hint" `
    ($src -match 'choose-tree\s*\(digits\+enter=jump') ""

Write-Test "Renderer: buffer picker title advertises digits+enter"
Add-Result "buffer title hint" `
    ($src -match 'choose-buffer\s*\(digits\+enter=jump') ""

Write-Test "Renderer: customize header advertises digits+Enter"
Add-Result "customize header hint" `
    ($src -match 'Customize Mode.*?digits\+Enter:jump') ""

# ════════════════════════════════════════════════════════════════════
#  PART 2: Functional verification of picker data sources
# ════════════════════════════════════════════════════════════════════
#
# Prove that each picker actually has multiple rows to jump to. If the
# data source is broken there's nothing for "type 3 + Enter" to land on.

$psmuxDir = "$env:USERPROFILE\.psmux"
$S = "picker_digit_jump_e2e"

function Kill-Session($name) { & $PSMUX kill-session -t $name 2>$null | Out-Null }
function Wait-Session($name, [int]$timeoutSec = 10) {
    for ($i = 0; $i -lt ($timeoutSec * 2); $i++) {
        & $PSMUX has-session -t $name 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Kill-Session $S
Start-Sleep -Milliseconds 500

# new-session -d refuses to nest if PSMUX_SESSION is set.
$env:PSMUX_SESSION = ""

& $PSMUX new-session -d -s $S 2>&1 | Out-Null
$alive = Wait-Session $S
Add-Result "test session started" $alive ""

if (-not $alive) {
    Write-Host "`n  Cannot continue without a live session." -ForegroundColor Red
    exit 1
}

# Build several windows so the choose-tree picker has rows to jump to.
& $PSMUX new-window -t $S -n win_a 2>&1 | Out-Null
& $PSMUX new-window -t $S -n win_b 2>&1 | Out-Null
& $PSMUX new-window -t $S -n win_c 2>&1 | Out-Null
& $PSMUX new-window -t $S -n win_d 2>&1 | Out-Null
Start-Sleep -Milliseconds 400

Write-Test "choose-tree data source: list-windows returns multiple windows"
$winList = & $PSMUX list-windows -t $S 2>&1 | Out-String
$winCount = ([regex]::Matches($winList, "(?m)^\s*\d+:")).Count
Add-Result "choose-tree has multiple rows" ($winCount -ge 4) "windows=$winCount"

# Populate several paste buffers so the choose-buffer picker has rows.
& $PSMUX set-buffer -b alpha   "buffer-alpha-payload"   2>&1 | Out-Null
& $PSMUX set-buffer -b bravo   "buffer-bravo-payload"   2>&1 | Out-Null
& $PSMUX set-buffer -b charlie "buffer-charlie-payload" 2>&1 | Out-Null

Write-Test "choose-buffer data source: list-buffers returns multiple buffers"
$bufList = & $PSMUX list-buffers 2>&1 | Out-String
$bufCount = ([regex]::Matches($bufList, "(?m)^[A-Za-z0-9_-]+:\s*\d+\s+bytes")).Count
if ($bufCount -lt 3) {
    # Some builds prefix with "buffer" + index — count those too.
    $bufCount = ([regex]::Matches($bufList, "(?m)^buffer\d+:")).Count
}
Add-Result "choose-buffer has multiple rows" ($bufCount -ge 3) "buffers=$bufCount"

# choose-buffer is a client-side overlay; verify the server-side
# `choose-buffer` TCP handler returns the parseable list the client
# parses into buffer_entries (one row per "bufferN: M bytes: \"...\"").
Write-Test "choose-buffer TCP handler returns parseable list"
function Query-Server($name, $cmd) {
    $pf = "$psmuxDir\$name.port"
    $kf = "$psmuxDir\$name.key"
    if (-not (Test-Path $pf)) { return $null }
    try {
        $port = [int]((Get-Content $pf -Raw).Trim())
        $key  = if (Test-Path $kf) { (Get-Content $kf -Raw).Trim() } else { "" }
        $tcp  = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
        $st   = $tcp.GetStream()
        $st.ReadTimeout = 2000
        $w    = [System.IO.StreamWriter]::new($st); $w.AutoFlush = $true
        $r    = [System.IO.StreamReader]::new($st)
        $w.WriteLine("AUTH $key")
        $null = $r.ReadLine()
        $w.WriteLine($cmd)
        $sb = [System.Text.StringBuilder]::new()
        $deadline = [DateTime]::Now.AddSeconds(2)
        while ([DateTime]::Now -lt $deadline) {
            try {
                $line = $r.ReadLine()
                if ($null -eq $line) { break }
                [void]$sb.AppendLine($line)
                if ($line -eq "OK" -or $line.StartsWith("ERR")) { break }
            } catch { break }
        }
        $tcp.Close()
        return $sb.ToString()
    } catch { return $null }
}

$bufResp = Query-Server $S "choose-buffer"
$bufRows = if ($bufResp) {
    ([regex]::Matches($bufResp, "buffer\d+:\s*\d+\s+bytes")).Count
} else { 0 }
Add-Result "choose-buffer TCP handler returns rows" ($bufRows -ge 3) "rows=$bufRows"

# customize-mode lives server-side; the client mirror just shows
# srv_customize_options. Verify the data source (server show-options
# enumeration that backs the overlay) lists many options.
Write-Test "customize-mode data source: show-options enumerates many options"
$opts = & $PSMUX show-options -g 2>&1 | Out-String
$optCount = ([regex]::Matches($opts, "(?m)^\S")).Count
Add-Result "customize-mode has many rows" ($optCount -ge 10) "options=$optCount"

# ── Layer 2: visible-window CLI verification ─────────────────────
# Open a real visible psmux client, then drive state via CLI.
# We can't see the picker overlay from the outside, but we can prove
# the windows pile up so the choose-tree picker has rows to jump to,
# and that the binary does not crash in a real graphical attach.
Write-Test "Layer 2: visible psmux client survives multi-window setup"
$visibleSession = "picker_digit_jump_visible"
Kill-Session $visibleSession
Start-Sleep -Milliseconds 300
& $PSMUX new-session -d -s $visibleSession 2>&1 | Out-Null
$null = Wait-Session $visibleSession 5
$attachProc = $null
try {
    $attachProc = Start-Process -FilePath $PSMUX -ArgumentList @("attach","-t",$visibleSession) `
        -WindowStyle Normal -PassThru
    Start-Sleep -Milliseconds 1500
    & $PSMUX new-window -t $visibleSession -n vis_a 2>&1 | Out-Null
    & $PSMUX new-window -t $visibleSession -n vis_b 2>&1 | Out-Null
    & $PSMUX new-window -t $visibleSession -n vis_c 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $vlist = & $PSMUX list-windows -t $visibleSession 2>&1 | Out-String
    $vcount = ([regex]::Matches($vlist, "(?m)^\s*\d+:")).Count
    $stillAlive = -not $attachProc.HasExited
    Add-Result "visible client alive after CLI-driven window growth" `
        ($stillAlive -and $vcount -ge 3) "alive=$stillAlive windows=$vcount"
} finally {
    if ($attachProc -and -not $attachProc.HasExited) {
        try { $attachProc.Kill() } catch {}
    }
    Kill-Session $visibleSession
}

# ── Cleanup ──
Kill-Session $S

# ════════════════════════════════════════════════════════════════════
#  Summary
# ════════════════════════════════════════════════════════════════════

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $pass / $($pass + $fail)" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
foreach ($r in $results) {
    $color  = if ($r.Pass) { 'Green' } else { 'Red' }
    $status = if ($r.Pass) { 'PASS' } else { 'FAIL' }
    Write-Host "  [$status] $($r.Test)" -ForegroundColor $color
}

if ($fail -gt 0) {
    Write-Host "`n  Some tests failed." -ForegroundColor Red
    Write-Host "  To verify the UX manually:" -ForegroundColor Yellow
    Write-Host "    1. psmux new-session -d -s a; new-window x N times" -ForegroundColor Yellow
    Write-Host "    2. psmux attach -t a" -ForegroundColor Yellow
    Write-Host "    3. C-b w     -> choose-tree, type 3 + Enter -> jumps to 3rd row" -ForegroundColor Yellow
    Write-Host "    4. C-b =     -> choose-buffer, type 2 + Enter -> pastes 2nd buffer" -ForegroundColor Yellow
    Write-Host "    5. customize-mode  -> type 5 + Enter -> jumps to 5th option" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n  All tests passed. Picker digit-jump parity verified." -ForegroundColor Green
exit 0
