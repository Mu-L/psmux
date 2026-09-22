# Issue #684: where a bracketed paste goes, and the two paste-buffer defects
# found alongside it.
#
# On Windows 10 19045 the inbox conhost (10.0.19041.1) silently removes
# ESC[200~ and ESC[201~ from a pane's ConPTY INPUT pipe and hands the child the
# payload alone.  The pipe write reports success, so psmux could not observe the
# loss and the "fall back when the brackets are stripped" strategy in
# input.rs was unreachable.  The same bytes delivered as KEY_EVENT records with
# WriteConsoleInputW arrive intact on that conhost, which is why psmux 0.4.9
# bracketed there and master did not.
#
# The fix decides the channel up front, from the host's build number and the
# pane child's console input mode, and PSMUX_PASTE_INJECT makes the decision
# testable on a host whose pipe works.  That is what this file does: it proves
# the injection route delivers the markers BYTE FOR BYTE the same as the pipe
# route on a modern build, so a 19045 user gets exactly what a 26200 user gets.
#
# Also covered, both reproduced before they were fixed:
#   * prefix + ] sent `paste-buffer` where tmux binds `paste-buffer -p`
#     (key-bindings.c:422), so that one keypress was unbracketed everywhere.
#   * the in server `paste-buffer` dispatch threw every flag away and pasted
#     the top buffer unbracketed, so a binding, a hook or a `:paste-buffer -p
#     -b name` at the command prompt ignored -p, -b, -d, -s and -t.
#
# The recorder is tests\paste_recorder.cs, compiled here, in two shapes:
#   vt       a byte stream reader (ENABLE_VIRTUAL_TERMINAL_INPUT), the node and
#            nvim case, the one the injection route is for.
#   records  an INPUT_RECORD reader, the crossterm / Helix case from issue #98,
#            which must NEVER be handed injected marker bytes because it would
#            show them as the literal characters [200~.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = "i684paste"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

$repoTests = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($v in 'PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX') {
    Remove-Item "env:$v" -EA SilentlyContinue
}

$savedDataDir = $env:PSMUX_DATA_DIR
$savedNoWarm  = $env:PSMUX_NO_WARM
$savedInject  = $env:PSMUX_PASTE_INJECT
$savedDebug   = $env:PSMUX_INPUT_DEBUG

$root = Join-Path $env:TEMP "psmux_i684_paste"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$env:PSMUX_NO_WARM = "1"
$env:PSMUX_INPUT_DEBUG = "1"

# --- compile the recorder ---------------------------------------------------
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe" }
$recorder = Join-Path $root "paste_recorder.exe"
& $csc /nologo /optimize /platform:x64 /out:$recorder (Join-Path $repoTests "paste_recorder.cs") 2>&1 | Out-Null
if (-not (Test-Path $recorder)) {
    Write-Host "FATAL: could not compile paste_recorder.cs" -ForegroundColor Red
    exit 1
}
$hostInjector = Join-Path $root "paste_host_injector.exe"
& $csc /nologo /optimize /platform:x64 /out:$hostInjector (Join-Path $repoTests "paste_host_injector.cs") 2>&1 | Out-Null

# --- payloads ---------------------------------------------------------------
# 10 lines of 47 characters with CRLF endings: 490 bytes, the reporter's file.
$stdLines = 0..9 | ForEach-Object { ("LINE{0}-ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789" -f $_).PadRight(47, '.') }
$stdText  = ($stdLines -join "`r`n") + "`r`n"
$stdFile  = Join-Path $root "payload_std.txt"
[IO.File]::WriteAllBytes($stdFile, [Text.Encoding]::ASCII.GetBytes($stdText))

# 100 lines of 99 characters: 10100 bytes, well past the 512 byte pipe chunk
# and the 2048 record injection chunk.
$bigText = ((1..100 | ForEach-Object { "X" * 99 }) -join "`r`n") + "`r`n"
$bigFile = Join-Path $root "payload_big.txt"
[IO.File]::WriteAllBytes($bigFile, [Text.Encoding]::ASCII.GetBytes($bigText))

# An ESC byte inside the payload, Latin 1, and CJK: the UTF-16 path in the
# KEY_EVENT records has to carry all of it.
$wideText = "ASCII-start" + [char]0x1b + "ESCBYTE-" + [char]0xe9 + [char]0xfc +
            "-CJK:" + [char]0x4f60 + [char]0x597d + [char]0x4e16 + [char]0x754c + "-end`r`n"
$wideFile = Join-Path $root "payload_wide.txt"
[IO.File]::WriteAllBytes($wideFile, [Text.Encoding]::UTF8.GetBytes($wideText))

# What the pane child must receive: every line break collapsed to a single CR,
# which is what BOTH channels do (write_paste_chunked normalises CRLF to CR and
# send_vt_response does the same on its way into UTF-16).
function Expected([string]$text, [bool]$bracket) {
    $body = $text -replace "`r`n", "`r"
    if ($bracket) { "`e[200~" + $body + "`e[201~" } else { $body }
}
function HexOf([string]$s) {
    ([Text.Encoding]::UTF8.GetBytes($s) | ForEach-Object { $_.ToString("x2") }) -join ""
}

# --- one measurement --------------------------------------------------------
# Runs the recorder as a pane child, loads a buffer, pastes into it, and returns
# the recorder's parsed block plus the route psmux chose.
function Invoke-Paste {
    param(
        [string]$Tag,
        [string]$PayloadFile,
        [string]$Flags = "-p",
        [string]$RecorderMode = "vt",
        [string]$Inject = "",
        [int]$Seconds = 12
    )
    if ($Inject -ne "") { $env:PSMUX_PASTE_INJECT = $Inject }
    else { Remove-Item env:PSMUX_PASTE_INJECT -EA SilentlyContinue }
    # The route is read by the SERVER, so each arm needs its own cold server.
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $dbg = Join-Path $env:PSMUX_DATA_DIR "input_debug.log"
    Remove-Item $dbg -EA SilentlyContinue

    $log = Join-Path $root "rec_$Tag.log"
    Remove-Item $log -EA SilentlyContinue
    $sess = "i684_$Tag"
    & $PSMUX -L $NS new -d -s $sess -x 100 -y 30 -- $recorder $log $Seconds $RecorderMode 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    & $PSMUX -L $NS load-buffer $PayloadFile 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    $argv = @("-L", $NS, "paste-buffer") + ($Flags -split ' ' | Where-Object { $_ -ne "" }) + @("-t", $sess)
    & $PSMUX @argv 2>&1 | Out-Null
    Start-Sleep -Seconds ($Seconds - 1)

    $res = [ordered]@{ Total = -1; Hex = ""; Has200 = "?"; Has201 = "?"; Text = ""; Route = "none" }
    if (Test-Path $log) {
        foreach ($line in Get-Content $log) {
            if ($line -match '^TOTAL (\d+)$')  { $res.Total  = [int]$Matches[1] }
            elseif ($line -match '^HEX (.*)$') { $res.Hex    = $Matches[1] }
            elseif ($line -match '^HAS200 (\w+)$') { $res.Has200 = $Matches[1] }
            elseif ($line -match '^HAS201 (\w+)$') { $res.Has201 = $Matches[1] }
            elseif ($line -match '^TEXT (.*)$') { $res.Text   = $Matches[1] }
        }
    }
    if (Test-Path $dbg) {
        $r = Get-Content $dbg | Select-String -Pattern 'route=(inject|pipe)' | Select-Object -Last 1
        if ($r) { $res.Route = ([regex]'route=(inject|pipe)').Match($r.Line).Groups[1].Value }
    }
    & $PSMUX -L $NS kill-session -t $sess 2>&1 | Out-Null
    [pscustomobject]$res
}

Write-Host "`n=== Issue #684: paste route ===" -ForegroundColor Yellow

# 1. The pipe route, which is what this host does on its own.
$pipe = Invoke-Paste -Tag "pipe" -PayloadFile $stdFile -Inject "0"
$want = HexOf (Expected $stdText $true)
if ($pipe.Route -eq "pipe") { Write-Pass "PSMUX_PASTE_INJECT=0 pins the pipe route" }
else { Write-Fail "PSMUX_PASTE_INJECT=0 chose '$($pipe.Route)'" }
if ($pipe.Hex -eq $want) { Write-Pass "pipe route delivers the 490 byte payload byte exact with both markers ($($pipe.Total) bytes)" }
else { Write-Fail "pipe route bytes differ`n    want $want`n    got  $($pipe.Hex)" }

# 2. The injection route, the one a 19045 pane needs, forced on here.
$inj = Invoke-Paste -Tag "inject" -PayloadFile $stdFile -Inject "1"
if ($inj.Route -eq "inject") { Write-Pass "PSMUX_PASTE_INJECT=1 takes the WriteConsoleInputW route" }
else { Write-Fail "PSMUX_PASTE_INJECT=1 chose '$($inj.Route)'" }
if ($inj.Has200 -eq "YES" -and $inj.Has201 -eq "YES") { Write-Pass "the injected paste carries ESC[200~ and ESC[201~" }
else { Write-Fail "the injected paste lost a marker (200=$($inj.Has200) 201=$($inj.Has201))" }
if ($inj.Hex -eq $want) { Write-Pass "injection route delivers the same 490 byte payload byte exact ($($inj.Total) bytes)" }
else { Write-Fail "injection route bytes differ`n    want $want`n    got  $($inj.Hex)" }
if ($inj.Hex -eq $pipe.Hex) { Write-Pass "both routes hand the child IDENTICAL bytes" }
else { Write-Fail "the two routes disagree, so a 19045 user would not get what a 26200 user gets" }

# 3. Chunking: 10100 bytes crosses both the 512 byte pipe chunk and the 2048
#    record injection chunk.
$bigWant = HexOf (Expected $bigText $true)
$bigInj  = Invoke-Paste -Tag "biginj" -PayloadFile $bigFile -Inject "1" -Seconds 16
if ($bigInj.Hex -eq $bigWant) { Write-Pass "a 10100 byte paste survives injection chunking ($($bigInj.Total) bytes)" }
else { Write-Fail "the chunked injection lost bytes: want $($bigWant.Length/2), got $($bigInj.Total)" }

# 4. An ESC byte and non ASCII through the UTF-16 record encoding.
$wideWant = HexOf (Expected $wideText $true)
$wideInj  = Invoke-Paste -Tag "wideinj" -PayloadFile $wideFile -Inject "1"
$widePipe = Invoke-Paste -Tag "widepipe" -PayloadFile $wideFile -Inject "0"
if ($wideInj.Hex -eq $wideWant) { Write-Pass "an ESC byte, Latin 1 and CJK survive the KEY_EVENT records" }
else { Write-Fail "the wide payload was mangled by injection`n    want $wideWant`n    got  $($wideInj.Hex)" }
if ($wideInj.Hex -eq $widePipe.Hex) { Write-Pass "the wide payload is identical on both routes" }
else { Write-Fail "the wide payload differs between the routes" }

# 5. Issue #98: a record reader keeps the pipe even with the override on, and
#    never sees the markers as literal characters.
$rec = Invoke-Paste -Tag "records" -PayloadFile $stdFile -Inject "1" -RecorderMode "records"
if ($rec.Route -eq "pipe") { Write-Pass "a record reader keeps the pipe even with PSMUX_PASTE_INJECT=1 (issue #98)" }
else { Write-Fail "a record reader was sent down the '$($rec.Route)' route" }
if ($rec.Has200 -eq "NO" -and $rec.Has201 -eq "NO" -and $rec.Text -notmatch '\[20[01]~') {
    Write-Pass "the record reader sees no literal [200~ characters"
} else {
    Write-Fail "the record reader saw bracket characters: $($rec.Text)"
}
$recWant = HexOf (Expected $stdText $false)
if ($rec.Hex -eq $recWant) { Write-Pass "the record reader still receives the whole payload ($($rec.Total) bytes)" }
else { Write-Fail "the record reader lost payload bytes ($($rec.Total))" }

# 6. tmux parity: no -p means no markers, whatever the pane asked for
#    (cmd-paste-buffer.c:97 brackets only when -p AND MODE_BRACKETPASTE).
$plain = Invoke-Paste -Tag "noflag" -PayloadFile $stdFile -Flags ""
if ($plain.Has200 -eq "NO" -and $plain.Has201 -eq "NO") { Write-Pass "paste-buffer without -p is unbracketed, as tmux documents" }
else { Write-Fail "paste-buffer without -p emitted markers" }

Write-Host "`n=== Issue #684: the default ] binding ===" -ForegroundColor Yellow

& $PSMUX -L $NS kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
& $PSMUX -L $NS new -d -s i684_keys -x 80 -y 24 2>&1 | Out-Null
Start-Sleep -Seconds 2
$keys = (& $PSMUX -L $NS list-keys) -join "`n"
# tmux key-bindings.c:422: bind -N 'Paste the most recent paste buffer' ] { paste-buffer -p }
if ($keys -match 'bind-key -T prefix \] paste-buffer -p') {
    Write-Pass "list-keys shows ] bound to paste-buffer -p (tmux key-bindings.c:422)"
} else {
    Write-Fail "] is not bound to paste-buffer -p"
}

Write-Host "`n=== Issue #684: paste-buffer flags in the in server dispatch ===" -ForegroundColor Yellow

# A hook runs through commands.rs execute_command_string, the same route a key
# binding and the command prompt take.  Before the fix this pasted buffer 0
# unbracketed whatever the flags said.
function Invoke-HookPaste([string]$Tag, [string]$Command, [string]$Inject = "0") {
    if ($Inject -ne "") { $env:PSMUX_PASTE_INJECT = $Inject }
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $log = Join-Path $root "rec_$Tag.log"
    Remove-Item $log -EA SilentlyContinue
    $sess = "i684_$Tag"
    # The recorder lives in window 1 of a session whose window 0 is a plain
    # shell, so the session survives the recorder's exit.  Without that, the
    # session closes with the recorder and a later list-buffers answers
    # "no server running", which would satisfy a "the buffer is gone"
    # assertion for the wrong reason.
    & $PSMUX -L $NS new -d -s $sess -x 100 -y 30 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    & $PSMUX -L $NS new-window -t $sess -- $recorder $log 12 vt 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    & $PSMUX -L $NS set-buffer -b named684 "NAMEDBUF684" 2>&1 | Out-Null
    & $PSMUX -L $NS set-buffer "DEFAULTBUF684" 2>&1 | Out-Null
    $res = [ordered]@{ Text = ""; Total = -1; Buffers = ""; BuffersBefore = "" }
    $res.BuffersBefore = ((& $PSMUX -L $NS list-buffers) -join "`n")
    & $PSMUX -L $NS set-hook -g before-select-window $Command 2>&1 | Out-Null
    & $PSMUX -L $NS select-window -t "${sess}:1" 2>&1 | Out-Null
    Start-Sleep -Seconds 13
    if (Test-Path $log) {
        foreach ($line in Get-Content $log) {
            if ($line -match '^TEXT (.*)$')  { $res.Text  = $Matches[1] }
            elseif ($line -match '^TOTAL (\d+)$') { $res.Total = [int]$Matches[1] }
        }
    }
    $res.Buffers = ((& $PSMUX -L $NS list-buffers) -join "`n")
    & $PSMUX -L $NS set-hook -gu before-select-window 2>&1 | Out-Null
    & $PSMUX -L $NS kill-session -t $sess 2>&1 | Out-Null
    [pscustomobject]$res
}

$flagged = Invoke-HookPaste -Tag "flags" -Command "paste-buffer -p -b named684"
if ($flagged.Text -eq "<ESC>[200~NAMEDBUF684<ESC>[201~") {
    Write-Pass "a bound `paste-buffer -p -b named684` pastes the NAMED buffer, bracketed"
} else {
    Write-Fail "the flags were ignored, the pane received: '$($flagged.Text)'"
}

$deleted = Invoke-HookPaste -Tag "delete" -Command "paste-buffer -d -b named684"
if ($deleted.Text -eq "NAMEDBUF684") { Write-Pass "-d pastes the named buffer without brackets" }
else { Write-Fail "-d pasted '$($deleted.Text)'" }
if ($deleted.BuffersBefore -match 'named684' -and $deleted.Buffers -notmatch 'named684') {
    Write-Pass "-d deletes the buffer afterwards (cmd-paste-buffer.c:128)"
} elseif ($deleted.BuffersBefore -notmatch 'named684') {
    Write-Fail "the named buffer was never there to delete: $($deleted.BuffersBefore)"
} else {
    Write-Fail "-d left the buffer in place: $($deleted.Buffers)"
}

$sep = Invoke-HookPaste -Tag "sep" -Command "paste-buffer -s @@ -b named684"
if ($sep.Text -eq "NAMEDBUF684") { Write-Pass "-s is accepted (the named buffer has no newline to replace)" }
else { Write-Fail "-s changed a newline free buffer: '$($sep.Text)'" }

$missing = Invoke-HookPaste -Tag "missing" -Command "paste-buffer -p -b nosuchbuffer684"
if ($missing.Total -le 0) { Write-Pass "a missing named buffer pastes nothing (tmux: no buffer <name>)" }
else { Write-Fail "a missing buffer still pasted $($missing.Total) bytes: '$($missing.Text)'" }

# ---------------------------------------------------------------------------
& $PSMUX -L $NS kill-server 2>&1 | Out-Null
$env:PSMUX_DATA_DIR = $savedDataDir
$env:PSMUX_NO_WARM = $savedNoWarm
$env:PSMUX_INPUT_DEBUG = $savedDebug
if ($null -eq $savedInject) { Remove-Item env:PSMUX_PASTE_INJECT -EA SilentlyContinue }
else { $env:PSMUX_PASTE_INJECT = $savedInject }

Write-Host "`n================ SUMMARY ================" -ForegroundColor Yellow
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
