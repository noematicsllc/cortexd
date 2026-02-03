# Claude Code Hooks for Cortex Integration

These hooks automatically integrate cortex with Claude Code sessions, providing persistent memory across sessions without requiring the agent to be cortex-aware.

## What the Hooks Do

| Hook | Trigger | Action |
|------|---------|--------|
| `session-start.sh` | Session startup/resume/clear | Injects `status-current` into context |
| `prompt-context.sh` | Every user prompt | Retrieves relevant decisions/corrections/patterns, captures new ones |
| `response-consolidate.sh` | After each response | Extracts learnings/outcomes from the conversation |
| `session-end.sh` | Session end | Writes handoff note for next session |

## Installation

### 1. Copy hooks to global config

```bash
mkdir -p ~/.claude/hooks
cp *.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh
```

### 2. Add hooks to settings.json

Add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/session-start.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/prompt-context.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/response-consolidate.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/session-end.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

### 3. Optional: Add global CLAUDE.md

Copy `CLAUDE.md.example` to `~/.claude/CLAUDE.md` for agent instructions on manual cortex usage.

## How It Works

### Project Detection

Hooks derive the project name from the git repository:
```bash
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" || basename "$PWD")
```

This becomes the cortex table name. A project named `myapp` uses table `myapp`.

### Recursion Prevention

Helper agents spawned by hooks set environment variables to prevent infinite loops:
- `CORTEX_HELPER_AGENT=1` - For capture/consolidation agents
- `CORTEX_CLEANUP_AGENT=1` - For session-end agents

### Background Agents

The capture, consolidation, and session-end agents run in the background using `nohup` and `disown`. They don't block the main conversation.

### Lock Files

`response-consolidate.sh` uses a lock file (`/tmp/cortex-consolidate.lock`) to prevent pile-up during rapid exchanges. Stale locks (>2 minutes) are automatically removed.

## Logs

Hook activity is logged to:
- `/tmp/cortex-prompt-context.log` - Prompt hook
- `/tmp/cortex-consolidate.log` - Consolidation hook
- `/tmp/cortex-session-end.log` - Session end hook

## Dependencies

- `cortex` CLI in PATH
- `jq` for JSON parsing
- `git` for project detection
- `claude` CLI for spawning helper agents

## Customization

### Capture Patterns

Edit `prompt-context.sh` line ~30 to change which user messages trigger capture:
```bash
capture_patterns='actually|no,|not quite|the real issue|...'
```

### What Gets Stored

Edit the agent prompts in each hook to change what knowledge gets extracted and stored.
