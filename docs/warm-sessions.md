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

What does not carry over: `-e VAR=value` on `new-session`, `new-window` or `split-window` cannot
reach a shell that already has its environment, so a spawn with `-e` skips the warm pool and starts
cold.

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
