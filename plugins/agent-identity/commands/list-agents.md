---
allowed-tools: Bash(getent passwd:*), Bash(cortex:*)
description: List all agent users and their world-readable Cortex tables
---

## Context

This command lists all `agent-*` users on the system and shows their world-readable Cortex tables.

Note: Private tables are not visible (by design - that's the privacy model).

## Your Task

1. List all users matching the agent-* pattern:
   ```bash
   getent passwd | grep '^agent-' | cut -d: -f1,3
   ```

2. Check for world-readable tables by querying cortex ACLs:
   ```bash
   cortex acl list --pretty
   ```
   Look for entries with `"identity": "*"` - these are world-readable.

3. Present a summary showing:
   - Agent username and UID
   - Their world-readable tables (tables where identity is "*")
   - Note that private tables exist but aren't shown

## Output Format

```
Agent Users:
  agent-cortexd-coder (uid: 987)
    Public tables:
      - 987:public_memories (read)
    (Private tables not shown)

  agent-cortexd-researcher (uid: 988)
    Public tables:
      - 988:public_findings (read)
      - 988:public_sources (read)
    (Private tables not shown)

  agent-helper (uid: 989)
    No public tables
    (Private tables not shown)
```

If no agent users exist, suggest:
```
No agent users found. Create one with the setup script:

  ./plugins/agent-identity/setup.sh

Or manually:
  sudo useradd -r -s /usr/sbin/nologin agent-<project>-<role>

See the plugin README for full setup instructions.
```
