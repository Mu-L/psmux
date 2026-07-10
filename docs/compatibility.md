# tmux Compatibility

psmux is the most tmux-compatible terminal multiplexer on Windows.

## Overview

| Feature | Support |
|---------|---------|
| Commands | **83** tmux commands implemented |
| Format variables | **140+** variables with full modifier support |
| Config file | Reads `~/.tmux.conf` directly |
| Key bindings | `bind-key`/`unbind-key` with key tables, case-sensitive |
| Hooks | 15+ event hooks (`after-new-window`, etc.) with `set-hook`/`show-hooks` |
| Status bar | Full format engine with conditionals, loops, and multi-line support |
| Themes | 14 style options, 24-bit color, text attributes |
| Layouts | 5 layouts (even-h, even-v, main-h, main-v, tiled) |
| Copy mode | 53 vim keybindings, search, registers, rectangle select |
| Targets | `session:window.pane`, `session:window_name`, `%id`, `@id` syntax |
| `if-shell` / `run-shell` | ✅ Conditional config logic |
| Paste buffers | ✅ Full buffer management |
| Control mode | ✅ `-C` / `-CC` programmatic protocol |
| Popups and menus | ✅ `display-popup`, `display-menu` |
| Interactive choosers | ✅ `choose-tree`, `choose-buffer`, `choose-client` |
| Server namespaces | ✅ `-L` for isolated instances |
| Command chaining | ✅ Sequential `;` operator |
| Nesting prevention | ✅ Blocks psmux inside psmux |
| Session environment | ✅ `set-environment` / `show-environment` |

**Your existing `.tmux.conf` works.** psmux reads it automatically. Just install and go.

## Comparison

| | psmux | Windows Terminal tabs | WSL + tmux |
|---|:---:|:---:|:---:|
| Session persist (detach/reattach) | ✅ | ❌ | ⚠️ WSL only |
| Synchronized panes | ✅ | ❌ | ✅ |
| tmux keybindings | ✅ | ❌ | ✅ |
| Reads `.tmux.conf` | ✅ | ❌ | ✅ |
| tmux theme support | ✅ | ❌ | ✅ |
| Native Windows shells | ✅ | ✅ | ❌ |
| Full mouse support | ✅ | ✅ | ⚠️ Partial |
| Zero dependencies | ✅ | ✅ | ❌ (needs WSL) |
| Scriptable (83 commands) | ✅ | ❌ | ✅ |
| Claude Code agent teams | ✅ | ❌ | ✅ |
| CJK/IME text input | ✅ | ✅ | ✅ |
| Warm session pre-spawn | ✅ | N/A | ❌ |

## Supported Commands

For the full list of supported tmux commands and arguments, see [tmux_args_reference.md](tmux_args_reference.md).

## Recent Parity Improvements

This section covers tmux features that were recently brought to full parity.

### Case-sensitive Key Bindings

Key bindings now distinguish between lowercase and uppercase letters exactly like tmux. `bind-key T` binds to `Shift+T`, while `bind-key t` binds to lowercase `t`. This is critical for plugins like PPM (`Prefix+I` to install) and psmux-sensible (`Prefix+R` to reload).

### Ctrl+Space as Prefix

`set -g prefix C-Space` now works correctly. Previously, multi-character key names like `Space` were parsed as single character fallbacks.

### Wrapped Directional Pane Navigation

Directional pane navigation (`select-pane -U/-D/-L/-R`) now wraps at layout edges, matching tmux behavior. Navigating past the rightmost pane wraps to the leftmost, and so on. Wrap is also correctly suppressed while zoomed.

### Prefix Repeat Chaining

After pressing the prefix key, successive keypresses within the `repeat-time` window (default 500ms) each trigger the bound action without needing to re-enter the prefix. This matches tmux's repeat behavior for pane navigation and resize bindings.

### Switch Client

`switch-client` is fully functional with all standard flags (`-t`, `-n`, `-p`, `-l`). Use it to programmatically switch between sessions.

### Window Name Resolution in Targets

Target syntax now resolves window names, not just indices. `send-keys -t mysession:mywindow` correctly finds the window named "mywindow" in session "mysession".

### Manual Rename Flag

`new-window -n NAME` now sets the `manual_rename` flag, preventing `automatic-rename` from overwriting the explicitly specified window name with the foreground process name.

### List Commands from Within Session

Commands like `list-panes`, `list-windows`, `list-clients`, `list-commands`, and `show-hooks` now work when run from within a psmux session (via `Prefix + :`). Output is displayed in a temporary overlay.

### Source File from Within Session

`source-file` works from within a live session via `Prefix + :`. Previously, config changes only took effect after detaching and reattaching or killing the server.

### Display Panes Overlay

`display-panes` (and `Prefix + q`) now shows pane numbers briefly and auto-dismisses after `display-panes-time` (default 1s). Type a number during the overlay to switch to that pane.

### Hook Deduplication

`set-hook -g` now replaces existing hooks on reload instead of stacking duplicates. `set-hook -gu` correctly removes hooks.

### Command Chaining with Semicolons

Multiple commands can be chained with `;` on a single line, matching tmux behavior:

```tmux
bind-key M-s split-window -h \; select-pane -L
```

### Run Shell Output

`run-shell` now displays output in the status bar, matching tmux behavior. Background mode with `-b` runs fire and forget.

### Session Server Persistence

The psmux session server now survives SSH disconnects. On reconnect, sessions are intact and `psmux attach` reattaches normally.

### Bell and Alert Support

BEL characters (`\x07`) from programs are forwarded to your host terminal for audible beep. The `bell-action` option controls when bells are forwarded and when the status bar tab gets a bell flag.

### Pane Border Labels with Truncation

`pane-border-format` labels that exceed the pane width are now truncated with ellipsis instead of overflowing or clipping mid-character.

### Pane Title Management

`select-pane -T ""` correctly clears a pane title. The default pane title is the hostname, matching tmux convention. Programs can update the pane title via OSC 0/2 escape sequences (controlled by the `allow-set-title` option). See [pane-titles.md](pane-titles.md) for details on how this interacts with PowerShell and other shells.

### Multi-line Status Bar

`set -g status 2` enables a multi-line status bar with `status-format[0]` and `status-format[1]` fully rendering style directives like `#[fg=red]`, `#[align=left]`, and `#[fill=blue]`.

### Status Bar Style Directives

The following inline style directives are now rendered correctly in status-format lines:

- `#[list]` for the window list region
- `#[fill=colour]` for background fill
- `#[align=left|centre|right]` for text alignment
- `#[range=...]` for click regions

### Format Variable Expansion in Bindings

The `-F` flag on `bind-key` now properly expands format variables, enabling plugins like smart-splits.nvim to query pane dimensions.

### Set Environment

`set-environment` and `show-environment` are fully functional. Environment variables set with `set-environment -g` are inherited by all new panes at the process level (no shell commands echoed). The `new-session -e VAR=val` flag also sets session environment correctly.

### Unbind All Keys

`unbind-key -a` correctly removes all key bindings across all key tables. You can also target specific tables: `unbind-key -a -T prefix`, `unbind-key -a -T root`, `unbind-key -a -T copy-mode`.

### Client Prefix Format Variable

The `#{client_prefix}` format variable is correctly set when the prefix key is pressed. This enables status bar indicators like:

```tmux
set -g status-right "#{?client_prefix,#[bg=red] PREFIX ,}"
```

### Window Zoomed Flag

The `#{window_zoomed_flag}` format variable is correctly maintained during zoom/unzoom operations.

### Capture Pane

`capture-pane -p` correctly outputs pane content to stdout, enabling scripts and integrations (including Claude Code agent team coordination) to read pane state.

### Split Window Percentage

`split-window -p <percent>` correctly creates splits at the specified percentage instead of defaulting to 50/50.

### Split Window Working Directory

`split-window -c "#{pane_current_path}"` correctly resolves the format variable and opens the new pane in the current pane's working directory.

### UTF-8 and CJK Support

Multi-byte UTF-8 characters (box-drawing, emoji, CJK text) render correctly in panes. Pasting CJK text no longer crashes the session. Japanese and Korean IME input is handled with minimal latency (the paste-detection heuristic was tuned to avoid misidentifying rapid IME bursts).

## Behavioral Differences from tmux

A few commands intentionally behave differently from upstream tmux. These are deliberate choices, not bugs.

### `kill-server` with Multiple Sockets

In upstream tmux, each `-L <name>` socket is a fully separate server, and `kill-server` only ever affects the socket it was invoked on. Bare `tmux kill-server` kills the default socket and leaves any `-L` servers running.

psmux differs: **bare `psmux kill-server` tears down every socket and every session at once**, the default namespace plus all `-L` namespaces. It is a single "stop everything" switch. This is convenient on Windows, where leftover background servers are easy to lose track of.

The namespaced form stays scoped, exactly like tmux:

```text
psmux kill-server            # kills ALL sockets and ALL sessions (default + every -L namespace)
psmux -L work kill-server    # kills ONLY the "work" socket; other sockets keep running
```

So if you rely on isolated `-L` instances, always pass `-L <name>` to `kill-server` to limit the blast radius. Reach for bare `kill-server` only when you genuinely want a clean slate.

### Background Processes When a Pane Exits

On Unix, tmux leans on the kernel: closing a pane's terminal sends SIGHUP to its foreground process group, and anything deliberately detached (`nohup`, daemons, most GUI apps) survives. Windows has no SIGHUP and no pty process groups, so psmux walks the pane's process tree instead. By default, when a pane's shell exits on its own, psmux terminates the background children that shell left behind; without the sweep they leak invisibly along with a `conhost.exe` each, which in bulk can exhaust the desktop heap.

To get tmux-style survival for intentionally backgrounded processes, opt out with the `@kill-descendants` user option:

```tmux
set -g @kill-descendants off
```

Explicit `kill-pane`, `kill-window`, and `kill-session` always terminate the pane's full process tree regardless of this option. See the Dead Panes section in [configuration.md](configuration.md) for details.

## Format Variables

psmux supports 140+ format variables with full modifier support, including:

- Session/window/pane variables (`#S`, `#W`, `#P`, `#{pane_current_path}`, etc.)
- Style and color modifiers
- Conditional expressions (`#{?condition,true,false}`)
- Comparison operators (`#{==:a,b}`, `#{!=:a,b}`, `#{<:a,b}`)
- Logical operators (`#{||:a,b}`, `#{&&:a,b}`)
- Regex substitution (`#{s/pat/rep/:var}`)
- String operations: basename (`#{b:}`), dirname (`#{d:}`), lowercase (`#{l:}`), shell quote (`#{q:}`)
- Truncation and padding (`#{=N:var}`, `#{pN:var}`)
- Loop iteration over windows (`#{W:fmt}`), panes (`#{P:fmt}`), and sessions (`#{S:fmt}`)

## Named Paste Buffers

psmux supports named paste buffers, matching tmux behavior:

```powershell
# Set a named buffer
psmux set-buffer -b mybuf "hello world"

# Show a named buffer
psmux show-buffer -b mybuf

# Delete a named buffer
psmux delete-buffer -b mybuf

# Paste from a named buffer
psmux paste-buffer -b mybuf
```

Named buffers are separate from the default (anonymous) buffer stack. They persist for the lifetime of the session and can be used for inter-pane data exchange in scripts and automation workflows.

## Developer Integration: Using psmux as a tmux Drop-in on Windows

psmux implements the same CLI protocol as tmux. Any tool, library, or script that drives tmux via subprocess commands will work on psmux with minimal or zero changes. This section covers what developers need to know when integrating.

### Same Protocol, Same Commands

psmux accepts the same command syntax as tmux:

```python
# This code works identically with both tmux (Linux/macOS) and psmux (Windows)
import subprocess

def run_mux(cmd):
    binary = "tmux"  # psmux installs a tmux.exe alias
    result = subprocess.run([binary] + cmd, capture_output=True, text=True)
    return result.stdout.strip()

# All of these work on both platforms
run_mux(["new-session", "-d", "-s", "work"])
run_mux(["list-sessions"])
run_mux(["send-keys", "-t", "work", "echo hello", "Enter"])
run_mux(["capture-pane", "-t", "work", "-p"])
run_mux(["list-windows", "-F", "#{window_id}:#{window_name}"])
run_mux(["kill-session", "-t", "work"])
```

Because psmux installs a `tmux.exe` alias, existing scripts that call `tmux` by name will find psmux on the PATH without any binary name changes.

### Stable IDs: `$N`, `@N`, `%N`

psmux uses the same stable ID scheme as tmux:

| Prefix | Entity | Example |
|--------|--------|---------|
| `$` | Session | `$0`, `$1` |
| `@` | Window | `@0`, `@1`, `@2` |
| `%` | Pane | `%0`, `%1`, `%2` |

These IDs are monotonically increasing and never reused during a server's lifetime. Use them for reliable targeting:

```powershell
# Target by session ID
psmux has-session -t "$0"

# Target by window ID
psmux select-window -t @2

# Target by pane ID
psmux send-keys -t %3 "echo hello" Enter

# Compound targets work too
psmux send-keys -t "$0:@2.%3" "echo hello" Enter
```

### Format Separator Encoding (Windows UTF-8)

Libraries that parse format output from `list-sessions -F`, `list-windows -F`, or `list-panes -F` should be aware of encoding on Windows.

psmux outputs UTF-8 encoded text. On Linux, tmux also outputs UTF-8, and most tools decode correctly because the system locale is UTF-8. On Windows, the default console code page is often cp1252 or cp437, not UTF-8.

If your library uses `subprocess.Popen(text=True)` in Python without specifying an encoding, Python will use the system default encoding (cp1252 on most Windows systems). This will garble any non-ASCII bytes in the output, including Unicode separator characters like U+241E that some libraries use internally.

**Fix**: Always specify `encoding="utf-8"` when reading psmux output:

```python
import subprocess

proc = subprocess.Popen(
    ["psmux", "list-sessions", "-F", "#{session_name}"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    encoding="utf-8",       # Required on Windows
    errors="backslashreplace"
)
stdout, stderr = proc.communicate()
```

Alternatively, set the `PYTHONUTF8=1` environment variable to make Python use UTF-8 everywhere:

```powershell
$env:PYTHONUTF8 = "1"
python your_script.py
```

### libtmux Compatibility

[libtmux](https://github.com/tmux-python/libtmux) is the most popular Python library for programmatically controlling tmux. psmux is compatible with libtmux's API because it implements the same CLI commands and output formats.

#### Setup

```powershell
pip install libtmux
```

#### Usage

```python
import libtmux

# Connect to the running psmux server
server = libtmux.Server(socket_name="default")

# List sessions
for session in server.sessions:
    print(f"Session: {session.name} (ID: {session.id})")

# Get windows and panes
session = server.sessions[0]
for window in session.windows:
    print(f"  Window: {window.name} (ID: {window.id})")
    for pane in window.panes:
        print(f"    Pane: {pane.id}")

# Create a new window
new_win = session.new_window(window_name="build")

# Send keys to a pane
pane = new_win.panes[0]
pane.send_keys("echo hello from libtmux")

# Capture pane content
output = pane.capture_pane()
print(output)

# Kill the window
new_win.kill()
```

#### Windows Encoding Note for libtmux

libtmux internally uses a Unicode separator character (U+241E, `SYMBOL FOR RECORD SEPARATOR`) to split format query results. On Linux, this works transparently because tmux outputs UTF-8 and Python decodes with UTF-8.

On Windows, libtmux's `tmux_cmd` class uses `subprocess.Popen(text=True)` which defaults to cp1252 encoding. The 3-byte UTF-8 sequence for U+241E (0xE2 0x90 0x9E) gets decoded as three separate cp1252 characters, breaking the field parser.

**Workaround**: Patch libtmux's `common.py` to add `encoding="utf-8"` to the Popen call:

```python
# In libtmux/common.py, tmux_cmd.__init__
# Change:
#   subprocess.Popen(cmd, stdout=PIPE, stderr=PIPE, text=True)
# To:
subprocess.Popen(cmd, stdout=PIPE, stderr=PIPE, text=True, encoding="utf-8", errors="backslashreplace")
```

Or set `PYTHONUTF8=1` globally before importing libtmux. This is an upstream libtmux issue (it should specify encoding explicitly for cross-platform support) and not specific to psmux.

### Cross-Platform Project Pattern

For projects that need terminal multiplexing on both Linux/macOS (tmux) and Windows (psmux):

```python
import platform
import subprocess

def get_mux_binary():
    """Get the terminal multiplexer binary for the current platform."""
    # psmux installs a tmux.exe alias, so "tmux" works everywhere
    return "tmux"

def mux_run(args, **kwargs):
    """Run a tmux/psmux command portably."""
    binary = get_mux_binary()
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    if platform.system() == "Windows":
        kwargs.setdefault("encoding", "utf-8")
    return subprocess.run([binary] + args, **kwargs)

def create_session(name, width=120, height=30):
    """Create a detached session."""
    return mux_run(["new-session", "-d", "-s", name, "-x", str(width), "-y", str(height)])

def send_keys(target, keys):
    """Send keys to a target pane."""
    return mux_run(["send-keys", "-t", target] + keys)

def capture_pane(target):
    """Capture pane content."""
    result = mux_run(["capture-pane", "-t", target, "-p"])
    return result.stdout

def list_sessions():
    """List all sessions."""
    result = mux_run(["list-sessions", "-F", "#{session_name}"])
    return result.stdout.strip().split("\n") if result.stdout.strip() else []

def kill_session(name):
    """Kill a session."""
    return mux_run(["kill-session", "-t", name])
```

This pattern works identically on Linux (with tmux) and Windows (with psmux) because:

1. psmux installs a `tmux.exe` alias, so the binary name is the same
2. The CLI protocol (commands, flags, format strings) is identical
3. Stable IDs (`$N`, `@N`, `%N`) follow the same scheme
4. Control mode (`-C`/`-CC`) uses the same wire protocol

### What About GUI/IDE Integrations?

If you are building an IDE plugin, VS Code extension, or GUI application that manages terminal sessions:

1. **Use control mode** (`psmux -CC`) for persistent, event-driven integration. See [control-mode.md](control-mode.md).
2. **Use `dump-state`** (psmux extension) to get the full session state as JSON, including screen content.
3. **Query format variables** with `display-message -p "#{var}"` for lightweight state reads.
4. **Set environment variables** with `set-environment -g KEY val` to pass configuration to child processes.
5. **Use hooks** (`set-hook -g after-new-window ...`) to react to session events.
6. **Use `wait-for`** for cross-pane synchronization in multi-step automation.

For a complete developer integration guide with examples in Python, PowerShell, Node.js, and more, see [integration.md](integration.md).
