# Warm Sessions

psmux uses a background **warm session** (`__warm__`) to make new session creation nearly instant. This page explains how it works and how to interact with it if needed.

## What is a Warm Session?

When you create a session, psmux pre-spawns a hidden standby server called `__warm__`. This server loads your config, initializes a shell, and waits. When you run `psmux new-session` next time, psmux **claims** this warm server (renames it to your requested session name) instead of cold-starting a new process. This skips the entire server startup + config load + shell spawn cycle.

**Result:** New session creation drops from ~400-1000ms (shell startup) to near-instant.

## Why You Don't See It

The `__warm__` session is an internal implementation detail. It is hidden from:

- `psmux ls` / `psmux list-sessions`
- `prefix + s` (choose-session)
- `prefix + w` (choose-tree)
- `prefix + (` / `)` (session navigation)
- The `last_session` tracking file

Users should never need to interact with it directly.

## When It's Not Spawned

The warm server is **not** created when:

- The current session has `destroy-unattached on`, and keeping a hidden warm server alive would break the expectation that sessions die when you detach
- The current session **is** the warm session (no recursive warm spawning)
- Warm panes are explicitly disabled (see below)

## Pool Depth (`warm-pool-size`)

Inside a running server the spare shells live in a small pool. How deep that
pool is decides whether a *run* of creations is fast or only the first one is.

A pool of depth one is enough for the first `new-window` and useless for the
second: claiming the only spare triggers a refill, and the refill is a shell
that started milliseconds ago, so the next creation waits out its entire
startup. Opening five windows in a row that way alternates fast, slow, fast,
slow. Depth is the cure, because the spare handed to creation N+1 has then had
the whole of creation N to finish booting.

```
# default: keep two spare shells ready
set -g warm-pool-size 2

# a machine with memory to spare and bursty window creation
set -g warm-pool-size 5

# no pool at all (same as set -g warm off)
set -g warm-pool-size 0
```

The value is clamped to 8. Each spare is a real shell process, so the cost is
linear: measured on Windows 11 with pwsh, one unit of depth costs one process
and about 94 MB of working set, and an idle server plus its spares burns under
0.1% of a 32 core machine. `PSMUX_WARM_POOL_SIZE` sets the boot time value for a
single run without touching the config.

Refills run on a background thread, so a burst of creations never waits on a
`CreateProcess` and the server loop is never stalled by one.

### A spare only counts once its shell has started

A spare becomes a pool member about 25 ms after it is asked for, which is just
the `CreateProcess` and the ConPTY allocation. Its pwsh needs roughly another
400 ms to put a prompt on the screen. Handing one out in between is
indistinguishable from a cold spawn: the window opens and then sits blank for
the rest of the shell's startup.

So the pool tracks readiness, inferred from the spare's own output: a spare
counts as started once it has written something and then stayed quiet for
250 ms. A claim prefers a started spare and takes the oldest one, since the
oldest is the furthest through its startup. When nothing has started yet the
claim still takes the oldest warming spare, because a shell part way through
booting beats a cold spawn that is not started at all.

A `default-shell` that never writes anything would otherwise never be handed
out, so a spare older than 1500 ms counts as started regardless.

### Bursts (surge)

Depth on its own cannot serve a *run* of creations. Ten windows opened back to
back arrive roughly every 20 ms, and no fixed depth survives that, because each
claim is replaced by one shell that needs 400 ms.

When a claim finds nothing started **and** another claim happened within the
last 1.5 s, the pool treats that as a run and temporarily grows to four times
`warm-pool-size`, capped at 8. Those spawns go out concurrently, so the run pays
one shell startup between all of them instead of one each. Measured over ten
back to back `new-window` calls, that is nine creations at 15 to 30 ms and one
at about 500 ms, against every second one costing 400 to 600 ms before.

One isolated slow creation does not surge: a cold `new-session` misses by
definition, since its only spare was born moments earlier, and surging there
fired eight shell spawns alongside the session's own starting shell and cost
about 100 ms of startup. The extra spares are released 5 s after the last miss,
so the idle footprint stays at `warm-pool-size`.

A `__warm__` standby is held at one spare and never surges: it creates no
windows of its own, and it may sit around for days.

### Tracing

To see what the pool is doing, set `PSMUX_WARM_TRACE=1` before starting the
server. Every claim, refill, landing and readiness flip is appended to
`%TEMP%\psmux_warm_trace.log` (override with `PSMUX_WARM_TRACE_FILE`) with a
millisecond timeline, including the age of the spare each claim received, which
is the number that explains a slow open.

## Disabling Warm Sessions

If you prefer every session, window, and pane to start with a completely fresh shell invocation (no pre-spawned state), you can disable warm entirely.

### Via config file

Add this to your `.psmux.conf`, `.tmux.conf`, or `~/.config/psmux/psmux.conf`:

```
set -g warm off
```

### Via environment variable

```powershell
$env:PSMUX_NO_WARM = "1"
```

When warm is disabled:
- No `__warm__` background server is spawned
- No warm panes are pre-spawned inside sessions
- Every `new-session`, `new-window`, and `split-window` cold-starts a fresh shell
- Startup latency increases slightly (shell profile load is not parallelized)

You can re-enable warm at runtime with `set -g warm on`.

## What a Claim Carries Over

A warm server and a warm pane are spawned ahead of time, so they know nothing about the client
that later claims them. psmux carries the parts that matter across the claim:

- **Start directory.** `new-session -c`, `new-window -c` and `split-window -c` cannot set the
  working directory of a shell that is already running, so psmux types a `cd` line into the warm
  shell and clears the screen. The line uses the syntax of the shell in the pane, chosen from the
  effective `default-shell`: PowerShell, cmd.exe and the POSIX shells each get their own form.
  Before [#600](https://github.com/psmux/psmux/issues/600) every Windows pane got the PowerShell
  form, which Git Bash and cmd.exe rejected. See
  [multi-shell.md](multi-shell.md#start-directories-and-warm-panes) for the exact lines.
- **Process priority.** The claiming client's `PSMUX_PRIORITY` (or its config file `priority`
  line) is applied to the claimed server, so `show-options -g priority` and the real scheduling
  class agree whether the session was cold started or claimed
  ([#608](https://github.com/psmux/psmux/issues/608)). See
  [configuration.md](configuration.md#process-priority).
- **Config.** The claimed server reloads your config file on the claim, so a `set -g` line you
  added since the standby was spawned is honoured.
- **Environment.** The claimed server adopts the claiming client's environment, which is what a
  cold started server inherits anyway, so `run-shell` children, hooks, plugin scripts and every
  pane spawned afterwards see the environment of the shell you ran psmux in. Before
  [#659](https://github.com/psmux/psmux/issues/659) a standby kept the environment of whatever
  spawned it for life, and a standby born without the psmux directory on `PATH` (a shell that
  predates the install, psmux reached through WSL interop) made every plugin fail with "the term
  'psmux' is not recognized". Two variables stay the server's own: `PSMUX_TARGET_SESSION`, which
  is its identity, and `PSMUX_DATA_DIR`, which names the directory its registry files already
  live in.

What does not carry over: `-e VAR=value` on `new-session`, `new-window` or `split-window` cannot
reach a shell that already has its environment, so a spawn with `-e` skips the warm pool and starts
cold. For the same reason the standby's first shell, the one you land in, keeps the environment it
was born with: a running process's environment block cannot be edited from outside. Its `PATH` is
read from the registry when the shell is spawned rather than inherited, so installed tools stay
resolvable there; a variable you exported in your own shell reaches the panes you open next, not
that first one. tmux behaves the same way, for the same reason.

## One Warm Server per Registry

The warm server belongs to the registry that spawned it. Each `-L <name>` namespace keeps its own
(`<name>____warm__`), and each `PSMUX_DATA_DIR` keeps its own as well: the single server guard that
stops two servers from publishing the same session name is keyed by the resolved data root, so two
registries can each hold a `__warm__` without refusing one another
([#599](https://github.com/psmux/psmux/issues/599)).

## Accessing the Warm Session (Advanced)

If you need to inspect or manage the warm session directly (debugging, development):

```powershell
# Check if a warm session is running
Test-Path "$HOME\.psmux\__warm__.port"

# List all sessions including warm (raw port files)
Get-ChildItem "$HOME\.psmux\*.port" | Select-Object Name

# Send a command to the warm server
psmux -t __warm__ list-windows

# Kill just the warm session
psmux -t __warm__ kill-session

# With -L namespace: warm session is stored as "<namespace>____warm__"
Test-Path "$HOME\.psmux\myns____warm__.port"
```

## File Layout

| File | Purpose |
|------|---------|
| `~\.psmux\__warm__.port` | TCP port of the warm server |
| `~\.psmux\__warm__.key` | Auth key for the warm server |
| `~\.psmux\<ns>____warm__.port` | Warm server under `-L <ns>` namespace |
