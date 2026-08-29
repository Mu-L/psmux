# psmux Performance: How Fast Is tmux for Windows?

psmux is a native terminal multiplexer for Windows, and this page is its performance record: what a psmux command costs, how long a new pane takes to show a PowerShell prompt, what the server uses in memory per pane, and where the time actually goes. Every number below was measured on a real machine with the commands shown, so you can reproduce them on yours.

## Key facts

- **A psmux CLI command round trip is about 15 to 25 ms**, including starting the `psmux.exe` client process, reading the registry files, connecting over loopback TCP, and printing the reply.
- **`new-session -d` takes about 50 ms** when the warm pool has a standby server ready, about 215 ms when it has to cold start one.
- **A new window shows a pwsh prompt in about 100 ms** when the server's spare shell is ready, 400 to 550 ms when the shell has to boot from scratch. Bare `pwsh -NoProfile -c exit` takes about 210 ms on the same machine, so psmux is not the bottleneck; the shell is.
- **The server process needs about 30 MB working set (15 MB private) for a session with 11 windows and 16 panes.** Each pane adds three lightweight threads and its scrollback buffer. The shells themselves (about 90 MB per pwsh) dominate memory, exactly as they would outside psmux.
- **Output rendering is event driven.** The server pushes a frame within a few milliseconds of ConPTY output; the client never has to poll for it.
- **Release builds use `opt-level = 3`, full LTO, one codegen unit, and stripped symbols** (`[profile.release]` in `Cargo.toml`).

For how these numbers come about, read [How psmux Multiplexes Natively on Windows](architecture.md). For the warm pool, read [Warm Sessions](warm-sessions.md).

## Reference machine

All measurements on this page were taken on 2026-08-29 with psmux 3.3.8 (commit cbb9c10) installed from `cargo install --path .`:

- Windows 11, build 26200
- PowerShell 7.6.5 as the default shell
- AMD Ryzen AI MAX+ 395, 96 GB RAM
- Timed from a PowerShell script with `System.Diagnostics.Stopwatch` around each `& psmux ...` call, so every figure includes the client process start

Your numbers will differ. Shell startup in particular depends on your profile, PSReadLine, oh-my-posh, and antivirus scanning of `pwsh.exe`.

## How long does a psmux command take?

Ten runs each against a session with one window (`psmux new-session -d -s perf -x 200 -y 50`):

| Command | min | median | max |
|---------|----:|-------:|----:|
| `display-message -p '#{session_name}'` | 16 ms | 18 ms | 26 ms |
| `list-panes` | 15 ms | 18 ms | 23 ms |
| `send-keys 'echo hi' Enter` | 15 ms | 20 ms | 26 ms |
| `capture-pane -p` | 18 ms | 24 ms | 38 ms |
| `split-window -h` (command returns; shell keeps booting) | 25 ms | 36 ms | 70 ms |
| `new-window` (command returns; shell keeps booting) | 31 ms | 58 ms | 74 ms |
| `kill-session` (waits for the process tree to exit) | 250 ms | 255 ms | 283 ms |

What that means for scripts: a loop that sends 100 `send-keys` commands finishes in about two seconds, and most of that is Windows creating 100 `psmux.exe` client processes, not the server. Chain commands with `\;` or use [control mode](control-mode.md) to send many commands over one connection when that matters.

## How long until a new pane is usable?

The command returning is not the same as the prompt being visible. This measures `new-window` until `capture-pane` shows a `PS C:\...>` prompt, polling every 5 ms:

| Run | new-window to visible pwsh prompt |
|-----|----------------------------------:|
| 1 | 562 ms (spare shell not ready, cold pwsh start) |
| 2 | 106 ms (spare shell claimed) |
| 3 | 432 ms |
| 4 | 94 ms |
| 5 | 403 ms |

The two clusters are the warm pane pool at work. Every server keeps one spare shell booted; the first `new-window` or `split-window` after a pause gets it in about 100 ms, and a burst of creates falls back to cold shell starts of 400 to 550 ms while the pool refills. Baseline for comparison, on the same machine:

| Command | min | median | max |
|---------|----:|-------:|----:|
| `pwsh -NoProfile -c exit` (no psmux involved) | 206 ms | 211 ms | 246 ms |

A cold pane costs the shell's own startup plus a couple of hundred milliseconds of PSReadLine and prompt rendering inside a fresh console. psmux's share of that is the ConPTY creation and the first frame, well under 50 ms.

## How long does session creation take?

| Scenario | min | median | max |
|----------|----:|-------:|----:|
| `new-session -d` with the warm pool enabled (default) | 45 ms | 50 ms | 51 ms |
| `new-session -d` with `PSMUX_NO_WARM=1` (cold server) | 203 ms | 216 ms | 243 ms |

The warm path is a rename of the standby `__warm__` server's registry files plus a claim message, which is why it is four times faster than spawning a server, binding the listener, loading the config, and booting the first shell. See [Warm Sessions](warm-sessions.md).

## What does the server use in memory?

After creating 11 windows and splitting the first window into 5 panes (16 panes in total, all pwsh):

| Process | Working set | Private bytes | Threads |
|---------|------------:|--------------:|--------:|
| `psmux.exe server -s perf` | 29.5 MB | 14.4 MB | 55 |
| each `pwsh.exe` pane (average) | about 94 MB | | |

Per pane the server adds three threads (ConPTY reader, VT parser, write queue) and the scrollback grid, which is `history-limit` rows times the pane width. With the default history the server's private memory grows by well under a megabyte per pane. The shells dominate: 16 panes of pwsh is about 1.5 GB of working set, the same as 16 Windows Terminal tabs. Use `cmd`, `nu`, or `pwsh -NoProfile` for panes that only need to run one command (see [Multi-Shell](multi-shell.md)).

## The extreme scale harness

`tests/test_extreme_perf.ps1` is the repository's stress benchmark. It creates 100 sequential windows, 50 windows in a burst, splits one window until psmux refuses, builds a 20 windows by 5 splits mixed session, and then measures command round trips and `dump-state` serialisation with 100 panes alive. It writes a JSON summary with these fields:

| Field | Meaning |
|-------|---------|
| `baseline_noprofile_ms`, `baseline_profile_ms` | Raw `pwsh` startup with and without the profile, no psmux involved |
| `cold_start_ms` | `new-session -d` on a cold server until its first prompt is visible |
| `seq_prompt_p50`, `seq_prompt_p90`, `seq_prompt_p99` | Prompt ready latency percentiles across 100 sequential `new-window` calls |
| `seq_cmd_avg` | Average `new-window` command return time in that run |
| `burst_total_ms` | Wall time to fire 50 `new-window` commands and see 50 prompts |
| `max_splits` | Splits accepted in one window before "pane too small" (depends on the terminal size you give the session) |
| `mixed_total_ms`, `mixed_mem_mb` | Wall time and server memory for the 100 pane mixed session |
| `rtt_avg_ms`, `rtt_p90_ms` | Command round trip with 100 panes alive |
| `dumpstate_avg_ms` | Server time to serialise a full frame with 100 panes alive |
| `throughput_wps` | `new-window` commands per second over 200 calls |
| `final_mem_mb`, `mem_after_kill_mb` | Server memory at the end and after `kill-session` |

Run it yourself after a release build (it looks for `target\release\psmux.exe`):

```powershell
cargo build --release
pwsh -NoProfile -File tests\test_extreme_perf.ps1
# smaller and faster:
pwsh -NoProfile -File tests\test_extreme_perf.ps1 -SequentialWindows 20 -BurstWindows 10 -SkipPromptCheck
```

A recorded run kept in the repository root (`test_extreme_perf_results.txt`, from an earlier build on a smaller terminal) shows `seq_prompt_p50` of 158 ms, `seq_prompt_p90` of 418 ms, `seq_prompt_p99` of 433 ms, `dumpstate_avg_ms` of 1 ms, and a server `final_mem_mb` of 73 MB with 100 panes alive. The p50 to p90 gap is the same warm versus cold shell split visible in the table above.

## Where the time goes

- **Shell startup dominates.** pwsh takes 200 to 1000 ms to a prompt depending on the profile; psmux spends tens of milliseconds per pane. The warm pool exists to overlap the two.
- **Client process start is most of a CLI round trip.** The server answers a query in about a millisecond; the other 15 ms is Windows creating `psmux.exe`, loading it, and reading three small files. This is why control mode and `\;` chains are faster for automation.
- **Frame serialisation is about 1 ms.** `dump_layout_json_fast` (`src/layout.rs`) snapshots each pane's cells under its parser mutex for about a millisecond and serialises outside the lock, so rendering never blocks a pane's reader thread.
- **`kill-session` is slow on purpose.** It walks the process tree of every pane, verifies each pid's creation time so a recycled pid is never killed, and waits for the exits, which is where the 250 ms goes.

## How psmux keeps latency low

All of these are in the source today; the file is named so you can check.

| Technique | Effect | Where |
|-----------|--------|-------|
| Server push rendering | A dirty state pushes a frame to attached clients within a few milliseconds instead of waiting for the next client poll | `src/server/mod.rs` |
| Adaptive client polling | 10 ms while typing, 16 ms idle with pushed frames, 1 ms while assembling a paste | `src/client.rs` |
| Reader and parser split | A 64 KB reader thread never takes the parser lock, and the parser coalesces bursts in 1 ms ticks | `src/pane.rs` |
| Per pane write queue | Keystrokes are queued and written by a dedicated thread, so a wedged child cannot stall the server loop | `src/pane.rs` (PR #543) |
| Lazy pane resize | Only the active window's panes are resized; background windows resize when shown, avoiding O(n) `ResizePseudoConsole` calls | `src/tree.rs` |
| Cached shell resolution | The default shell's path is resolved once per server in an `OnceLock` | `src/pane.rs` |
| Early port file write | The server binds its listener and writes `.port` before loading config or spawning shells, so an attaching client connects immediately | `src/server/mod.rs` |
| 10 ms attach polling | The client watches for the `.port` beacon in 10 ms ticks | `src/main.rs` |
| Warm servers and warm panes | Pre booted standby server and spare shell per server | [Warm Sessions](warm-sessions.md) |
| ConPTY passthrough | On Windows 11 22H2+ conhost forwards VT output as written instead of re rendering it | `crates/portable-pty-psmux` |
| Above normal priority | psmux's own server and client processes get `ABOVE_NORMAL_PRIORITY_CLASS` so a compile on every core cannot starve keystrokes (issue #608) | `src/platform.rs` |
| Release profile | `opt-level = 3`, `lto = true`, `codegen-units = 1`, `strip = "symbols"` | `Cargo.toml` |

## Why native multiplexing suits scripted TUIs and terminal agents

Running a dozen terminal agents, a build watcher, a log tail, and a couple of editors from one script is the workload psmux is tuned for:

- **Dozens of panes are cheap on the psmux side.** The server cost is a few threads and a screen buffer per pane; the harness routinely runs 100 panes in one server. What you pay for is the programs in the panes, which you would pay for anyway.
- **Commands are local and cheap.** `send-keys`, `capture-pane`, `wait-for`, and `pipe-pane` are 15 to 25 ms loopback calls. There is no WSL boundary and no shell wrapper between your script and the pane.
- **Detached servers keep running.** A supervisor script can create sessions at boot, hand agents their panes, and attach from any terminal later. See [Windows Use Cases](use-cases.md).
- **Output arrives as it happens.** Push rendering means an attached client sees an agent's output within milliseconds, and `capture-pane` reads the same screen the parser holds.
- **The interactive path is protected.** Above normal priority for psmux's own processes keeps the client responsive while agents saturate the CPU.

The step by step guide is [Running Terminal Agents and TUIs in psmux](tutorials/terminal-agents-and-tuis.md), and the command reference is [Scripting and Automation](scripting.md).

## Measure it yourself

Command round trip and session creation, in PowerShell 7:

```powershell
function Time-Psmux([string[]]$cmd, [int]$n = 10) {
    $t = 1..$n | ForEach-Object {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $null = & psmux @cmd
        $sw.Stop(); $sw.ElapsedMilliseconds
    }
    $s = $t | Sort-Object
    "{0,-40} min={1} med={2} max={3}" -f ($cmd -join ' '), $s[0], $s[[int]($s.Count / 2)], $s[-1]
}

psmux new-session -d -s perf -x 200 -y 50
Time-Psmux @('display-message', '-p', '-t', 'perf', '#{session_name}')
Time-Psmux @('send-keys', '-t', 'perf', 'echo hi', 'Enter')
Time-Psmux @('capture-pane', '-p', '-t', 'perf')
Time-Psmux @('new-window', '-t', 'perf') 5
psmux kill-session -t perf

# Session creation, warm versus cold
Time-Psmux @('new-session', '-d', '-s', 'perf2') 1; psmux kill-session -t perf2
$env:PSMUX_NO_WARM = '1'
Time-Psmux @('new-session', '-d', '-s', 'perf3') 1; psmux kill-session -t perf3
Remove-Item Env:PSMUX_NO_WARM
```

Prompt ready latency for a new window:

```powershell
$sw = [Diagnostics.Stopwatch]::StartNew()
psmux new-window -t perf -n probe
while ($sw.ElapsedMilliseconds -lt 20000) {
    $screen = (psmux capture-pane -p -t perf:probe) -join "`n"
    if ($screen -match 'PS [A-Z]:') { break }
    Start-Sleep -Milliseconds 5
}
"new-window to prompt: $($sw.ElapsedMilliseconds) ms"
```

Server memory:

```powershell
Get-CimInstance Win32_Process -Filter "Name='psmux.exe'" |
    Where-Object CommandLine -match 'server -s perf' |
    ForEach-Object { Get-Process -Id $_.ProcessId } |
    Select-Object Id, @{n='WS_MB';e={[math]::Round($_.WorkingSet64/1MB,1)}},
                      @{n='Private_MB';e={[math]::Round($_.PrivateMemorySize64/1MB,1)}}, Threads
```

If a number looks wrong, the debug and crash logs described in [Diagnostics](diagnostics.md) show where the time went.

## FAQ

### Is psmux faster than tmux inside WSL?

For Windows shells, yes by construction: a pwsh pane in psmux is a direct ConPTY child, while reaching pwsh from tmux in WSL means `wsl.exe` to `pwsh.exe` interop on every pane and every script call. For Linux shells inside WSL the two are comparable; psmux runs `wsl.exe` in a pane and the Linux side is unchanged.

### Why does the first split after a pause feel instant and a burst of splits does not?

The spare shell. Each server keeps one shell booted for the next `split-window` or `new-window`; a burst uses it up and the rest cold start while the pool refills. Windows created in a loop still return in about 50 ms each; only the prompt takes longer to appear.

### Does psmux add input latency?

A keystroke goes client to server over loopback (sub millisecond), into the pane's write queue, into ConPTY, and the echo comes back through the reader, parser, and a pushed frame. End to end this is a few milliseconds, below the 16 ms frame time of the terminal you are typing into.

### How many panes can one server hold?

The harness runs 100 panes in one session as a routine test. The practical limit is memory for the shells and your patience with `list-panes`, not psmux.

### What should I change to make it faster?

1. Trim your PowerShell profile or use `pwsh -NoProfile` for utility panes; the shell is the slow part.
2. Leave the warm pool on (default).
3. Prefer `\;` chains or control mode over hundreds of separate `psmux` invocations in tight loops.
4. Keep `history-limit` reasonable if you run hundreds of panes; scrollback is the only per pane memory psmux itself allocates.
