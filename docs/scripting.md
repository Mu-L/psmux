# Scripting & Automation

psmux supports tmux-compatible commands for scripting and automation.

## Window & Pane Control

```powershell
# Create a new window
psmux new-window

# Split panes
psmux split-window -v          # Split vertically (top/bottom)
psmux split-window -h          # Split horizontally (side by side)

# Navigate panes
psmux select-pane -U           # Select pane above
psmux select-pane -D           # Select pane below
psmux select-pane -L           # Select pane to the left
psmux select-pane -R           # Select pane to the right

# Navigate windows
psmux select-window -t 1       # Select window by index (default base-index is 1)
psmux next-window              # Go to next window
psmux previous-window          # Go to previous window
psmux last-window              # Go to last active window

# Kill panes and windows
psmux kill-pane
psmux kill-window
psmux kill-session
```

## Sending Keys

```powershell
# Send text directly
psmux send-keys "ls -la" Enter

# Send keys literally (no parsing)
psmux send-keys -l "literal text"

# Paste mode (legacy compatibility)
psmux send-keys -p

# Repeat a key N times
psmux send-keys -N 5 Up

# Send copy mode command
psmux send-keys -X copy-mode-up

# Special keys supported:
# Enter, Tab, Escape, Space, Backspace
# Up, Down, Left, Right, Home, End
# PageUp, PageDown, Delete, Insert
# F1-F12, C-a through C-z (Ctrl+key)
```

## Pane Information

```powershell
# List all panes in current window
psmux list-panes

# List all windows
psmux list-windows

# Capture pane content
psmux capture-pane

# Display formatted message with variables
psmux display-message "#S:#I:#W"   # Session:Window Index:Window Name
```

## Paste Buffers

```powershell
# Set paste buffer content
psmux set-buffer "text to paste"

# Paste buffer to active pane
psmux paste-buffer

# List all buffers
psmux list-buffers

# Show buffer content
psmux show-buffer

# Delete buffer
psmux delete-buffer

# Interactive buffer chooser (enter=paste, d=delete, esc=close)
psmux choose-buffer

# Clear command prompt history
psmux clear-prompt-history
```

## Pane Layout

```powershell
# Resize panes
psmux resize-pane -U 5         # Resize up by 5
psmux resize-pane -D 5         # Resize down by 5
psmux resize-pane -L 10        # Resize left by 10
psmux resize-pane -R 10        # Resize right by 10

# Swap panes
psmux swap-pane -U             # Swap with pane above
psmux swap-pane -D             # Swap with pane below

# Rotate panes in window
psmux rotate-window

# Toggle pane zoom
psmux zoom-pane
```

## Pane Titles

```powershell
# Set a title on the active pane
psmux select-pane -T "my build pane"

# Set pane title on a specific pane
psmux select-pane -t %3 -T "logs"

# Set per-pane style (foreground/background color override)
psmux select-pane -P "bg=default,fg=blue"

# Display pane title using format variables
psmux display-message "#{pane_title}"
```

Enable `pane-border-format` and `pane-border-status` in your config to see titles on pane borders:

```tmux
set -g pane-border-status top
set -g pane-border-format " #{pane_index}: #{pane_title} "
```

## Popups

```powershell
# Open a popup running a command
psmux display-popup "Get-Process"

# Set width and height (absolute or percentage)
psmux display-popup -w 80% -h 50% "htop"

# Set the starting directory
psmux display-popup -d "C:\Projects" -w 100 -h 30

# Close popup on command exit (default behavior, -E inverts it)
psmux display-popup -E "git log --oneline -20"

# Keep popup open after command finishes
psmux display-popup -K "echo done"
```

## Menus

```powershell
# Display an interactive menu
# Format: display-menu [-x x] [-y y] [-T title] name key command ...
psmux display-menu -T "Actions" \
  "New Window" n "new-window" \
  "Split Horizontal" h "split-window -h" \
  "Split Vertical" v "split-window -v" \
  "Close Pane" x "kill-pane"

# Position the menu at specific coordinates
psmux display-menu -x 10 -y 5 -T "Quick" \
  "Zoom" z "resize-pane -Z" \
  "Rename" r "command-prompt -I '#W' 'rename-window %%'"
```

## Session Management

```powershell
# Check if session exists (exit code 0 = exists)
psmux has-session -t mysession

# Rename session
psmux rename-session newname

# Respawn pane (restart shell)
psmux respawn-pane
```

## Environment Variables

```powershell
# Set a global env var (inherited by all new panes)
psmux set-environment -g EDITOR vim

# Set a session-scoped env var
psmux set-environment MY_VAR value

# Unset a global env var
psmux set-environment -gu MY_VAR

# Show all environment variables
psmux show-environment
psmux show-environment -g
```

## Format Variables

The `display-message` command supports these variables:

| Variable | Description |
|----------|-------------|
| `#S` | Session name |
| `#I` | Window index |
| `#W` | Window name |
| `#P` | Pane ID |
| `#T` | Pane title |
| `#H` | Hostname |

## Advanced Commands

```powershell
# Discover supported commands
psmux list-commands

# Server/session management
psmux kill-server
psmux list-clients
psmux switch-client -t other-session

# Config at runtime
psmux source-file ~/.psmux.conf
psmux show-options
psmux set-option -g status-left "[#S]"

# Layout/history/stream control
psmux next-layout
psmux previous-layout
psmux clear-history
psmux pipe-pane -o "cat > pane.log"

# Hooks
psmux set-hook -g after-new-window "display-message created"
psmux set-hook -gu after-new-window     # Unset (remove) a hook
psmux show-hooks

# Run shell commands (always non-blocking)
psmux run-shell "echo hello"           # Async, output shown in status
psmux run-shell -b "long-running.ps1"  # Fire-and-forget (detached stdin)
```

## Target Syntax (`-t`)

psmux supports tmux-style targets:

```powershell
# window by index in session
psmux select-window -t work:2

# specific pane by index
psmux send-keys -t work:2.1 "echo hi" Enter

# pane by pane id
psmux send-keys -t %3 "pwd" Enter

# window by window id
psmux select-window -t @4
```

## Server Namespaces (`-L`)

Use `-L` to run multiple isolated psmux servers on the same machine:

```powershell
# Start a session in a named server namespace
psmux -L work new-session -s dev

# Attach to a session in that namespace
psmux -L work attach -t dev

# Each namespace gets its own server, sessions, and socket
psmux -L personal new-session -s play
```

## Key Binding Management

```powershell
# Bind a key in the default prefix table
psmux bind-key h split-window -h

# Unbind a single key
psmux unbind-key h

# Unbind ALL keys (reset to clean slate)
psmux unbind-key -a

# Unbind all keys in a specific key table only
psmux unbind-key -a -T copy-mode-vi
```
