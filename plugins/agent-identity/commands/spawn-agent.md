---
allowed-tools: Bash(sudo -u *:*), Bash(id:*), Bash(mkdir:*), Bash(ln:*), Bash(export:*)
description: Spawn a Claude Code agent as a Unix user with isolated Cortex storage
---

## Context

This command spawns a Claude Code agent running as a different Unix user. The agent will have:
- Its own Cortex identity (based on UID)
- Isolated private storage
- Ability to share via public tables with world-readable ACLs

## Arguments

The user should provide:
1. **agent-user**: The Unix username to run as (e.g., `agent-cortexd-coder`)
2. **task**: The task for the agent to perform (in quotes)

## Your Task

Parse the user's input to extract the agent-user and task, then:

1. First, verify the user exists:
   ```bash
   id <agent-user>
   ```

2. **If the user does NOT exist**, tell the user they need to create it first:
   ```
   Agent user '<agent-user>' doesn't exist. Create it with:

     sudo useradd -r -s /usr/sbin/nologin -G YOUR_GROUP <agent-user>
     sudo visudo -f /etc/sudoers.d/claude-agents
     # Add <agent-user> to the AGENTS alias

   See the plugin README for full setup instructions.
   ```
   Then stop - do not proceed.

3. **If the user exists**, spawn Claude as that user with proper HOME setup:
   ```bash
   sudo -u <agent-user> sh -c 'export HOME=/tmp/<agent-user>; mkdir -p $HOME/.claude; ln -sf /home/YOUR_USER/.claude/.credentials.json $HOME/.claude/.credentials.json 2>/dev/null; /home/YOUR_USER/.local/bin/claude --dangerously-skip-permissions -p "<task>"'
   ```

   Replace:
   - `YOUR_USER` with the calling user's username (use `$USER` or `whoami`)
   - `<agent-user>` with the agent username
   - `<task>` with the user's task

4. **If sudo fails with "password required"**, tell the user:
   ```
   Sudo permission not configured. Run:

     sudo visudo -f /etc/sudoers.d/claude-agents

   Add or update the AGENTS alias:

     Runas_Alias AGENTS = agent-cortexd-tester, <agent-user>
     YOUR_USERNAME ALL=(AGENTS) NOPASSWD: ALL

   Note: Wildcards like (agent-*) don't work - use an alias instead.
   ```
   Then stop - do not proceed.

5. **If "Permission denied" on claude binary**, tell the user:
   ```
   Agent can't access Claude binary. Make path traversable:

     chmod g+x ~ ~/.local ~/.local/bin ~/.local/share ~/.local/share/claude ~/.local/share/claude/versions
   ```
   Then stop - do not proceed.

6. **If "Invalid API key"**, tell the user:
   ```
   Agent can't read Claude credentials. Fix with:

     sudo usermod -aG YOUR_GROUP <agent-user>
     chmod g+x ~/.claude
     chmod g+r ~/.claude/.credentials.json
   ```
   Then stop - do not proceed.

7. Report the agent's output back to the user.

## Spawn Command Template

Here's the full command to spawn an agent (fill in the values):

```bash
sudo -u AGENT_USER sh -c 'export HOME=/tmp/AGENT_USER; mkdir -p $HOME/.claude; ln -sf /home/CALLING_USER/.claude/.credentials.json $HOME/.claude/.credentials.json 2>/dev/null; /home/CALLING_USER/.local/bin/claude --dangerously-skip-permissions -p "TASK"'
```

## Agent Naming Guidance

When suggesting agent names to users, recommend project-scoped names:
- `agent-cortexd-coder` (not `agent-coder`) for project-specific work
- `agent-cortexd-researcher` for project-specific research
- General agents like `agent-coder` accumulate memories across all projects

## Important Notes

- The calling user must have sudo permission configured (see plugin README)
- The agent's Cortex tables are namespaced by their UID automatically
- Agents can share data via `cortex acl_grant my_table '*' read`
- Agents run with `--dangerously-skip-permissions` to avoid interactive prompts
- Agent HOME is set to `/tmp/<agent-user>` with symlinked credentials

## Example Usage

```
/spawn-agent agent-cortexd-tester "Create private and public memory tables, store some test data, and verify you can access Cortex"
```
