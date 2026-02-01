# Agent Identity Plugin

Spawn Claude Code agents as Unix users with isolated Cortex storage.

## Overview

Each agent runs as a separate Unix user, giving it:
- **Kernel-enforced identity** via UID
- **Isolated private storage** in Cortex (namespaced by UID)
- **Optional public storage** via world-readable ACLs

## Commands

| Command | Description |
|---------|-------------|
| `/spawn-agent <user> "<task>"` | Run a task as an agent |
| `/list-agents` | List agents and their public tables |

## Setup

### One-Time Setup

Make Claude credentials and binary accessible to agents in your group:

```bash
# Credentials
chmod g+x ~/.claude
chmod g+r ~/.claude/.credentials.json

# Binary path (adjust if claude is installed elsewhere)
chmod g+x ~ ~/.local ~/.local/bin ~/.local/share ~/.local/share/claude ~/.local/share/claude/versions
```

### Sudoers Setup

```bash
sudo visudo -f /etc/sudoers.d/claude-agents
```

Use a `Runas_Alias` to group agents:

```sudoers
Runas_Alias AGENTS = agent-cortexd-tester, agent-cortexd-coder
YOUR_USERNAME ALL=(AGENTS) NOPASSWD: ALL
```

**Note**: Wildcards like `(agent-*)` don't work - use an alias instead.

### Adding an Agent

```bash
# 1. Create user with your group
sudo useradd -r -s /usr/sbin/nologin -G YOUR_USERNAME agent-NAME

# 2. Add to the AGENTS alias in sudoers
sudo visudo -f /etc/sudoers.d/claude-agents
```

### Naming Convention

Use `agent-<project>-<role>` to scope memories per project:
- `agent-cortexd-coder` - cortexd project work
- `agent-myapp-researcher` - myapp project research

Generic names like `agent-coder` accumulate memories across all projects.

## Usage

```
> /spawn-agent agent-cortexd-tester "Create memory tables and store some test data"

> /list-agents
```

## How It Works

1. **Identity**: Agent's UID is extracted via `SO_PEERCRED` (kernel-enforced)
2. **Isolation**: Tables are namespaced by UID (e.g., `949:my_table`)
3. **Sharing**: Agents grant access with `cortex acl_grant my_table '*' read`
4. **Discovery**: Access shared tables by qualified name: `cortex all 949:my_table`

## Troubleshooting

**"sudo: a password is required"**
- Ensure agent is in the `AGENTS` alias in sudoers
- Wildcards like `(agent-*)` don't work - use an alias
- Verify syntax: `sudo visudo -c`

**"Permission denied" or "Invalid API key"**
- Check agent is in your group: `id agent-name`
- Check credentials: `ls -la ~/.claude/.credentials.json` (should be group-readable)
- Check binary path is traversable

## Limitations

- Each agent must be added to sudoers explicitly
- Agents share your Claude authentication/billing
- No automatic cleanup of unused agent users
