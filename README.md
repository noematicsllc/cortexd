# Cortex

A local storage daemon providing an embedded Mnesia database accessible via Unix socket. UID-based authentication with per-table access control.

## Features

- **Zero dependencies** - No Docker, no Postgres, no Redis. Just the binary.
- **Embedded storage** - Mnesia database with transactions and pattern matching
- **UID-based auth** - Kernel-enforced identity via SO_PEERCRED (no tokens to steal)
- **Per-table ACLs** - Read, write, admin permissions with world-readable option
- **Cross-platform** - Linux and macOS support

## Installation

```bash
# Build
mix deps.get
mix compile
MIX_ENV=prod mix release

# Install (Linux)
sudo ./install.sh
sudo systemctl enable --now cortexd
```

## Usage

```bash
# Health check
cortex ping
cortex status

# Tables
cortex tables
cortex create_table users id,name,email
cortex drop_table users

# Records
cortex put users '{"id":"u1","name":"alice","email":"alice@example.com"}'
cortex get users u1
cortex delete users u1
cortex query users '{"name":"alice"}'
cortex all users

# Access control
cortex acl grant uid:2001 users read,write
cortex acl grant '*' public_data read    # World-readable
cortex acl revoke uid:2001 users write
cortex acl list
```

## Architecture

```
App / CLI --> Unix socket --> cortexd --> Mnesia
                  |
           SO_PEERCRED (kernel reports UID)
```

Tables are namespaced by creator UID (`1000:users`). Users access their own tables without prefix; cross-user access requires the full identifier and appropriate ACL permissions.

## Security Model

- **Identity**: UID extracted via SO_PEERCRED/getpeereid (kernel-enforced)
- **Namespacing**: Tables prefixed with creator UID internally
- **Permissions**: Per-table ACLs (read, write, admin)
- **World access**: Special `*` identity for public tables
- **Socket**: Mode 0660, accessible via setgid CLI

## Agent Deployment

Each AI agent runs as a dedicated system user in the `cortex` group:

```bash
sudo useradd -r -s /usr/sbin/nologin -G cortex agent-coder
sudo -u agent-coder claude -p "do agent stuff"
```

The agent's UID becomes its Cortex identity automatically. No tokens or API keys needed.

**Note:** Users must be in the `cortex` group to access the daemon. The install script adds the installing user automatically. For additional users: `sudo usermod -a -G cortex USERNAME` (log out/in to take effect).

## Usage Patterns

### Agent Memory (Public + Private)

A common pattern for AI agents: maintain both shared knowledge and private state.

```bash
# Agent creates its memory tables
cortex create_table private id,type,content,ts
cortex create_table public id,type,content,ts

# Make public memory world-readable
cortex acl grant '*' public read
```

**Private memory** - internal state, scratchpad, credentials:

```bash
cortex put private '{"id":"task-ctx-1","type":"context","content":"Working on auth bug","ts":1706745600}'
```

**Public memory** - shared facts, discoveries, learned patterns:

```bash
cortex put public '{"id":"fact-1","type":"fact","content":"Rust async functions return impl Future","ts":1706745600}'
```

**Cross-agent sharing** - other agents can read public memories:

```bash
# Agent 2002 reads Agent 2001's public memories
cortex query 2001:public '{"type":"fact"}'
```

### State Machine + Commands

Define workflows and discoverable command templates using Cortex primitives.

```bash
# Create schema tables
cortex create_table sm_definitions id,states,transitions,initial
cortex create_table sm_instances id,machine,state,data,updated
cortex create_table commands id,scope,description,usage,example

# Make commands discoverable
cortex acl grant '*' commands read
cortex acl grant '*' sm_definitions read
```

**Define a workflow:**

```bash
cortex put sm_definitions '{
  "id": "order",
  "states": ["pending", "paid", "shipped", "delivered", "cancelled"],
  "transitions": {"pending":["paid","cancelled"],"paid":["shipped","cancelled"],"shipped":["delivered"]},
  "initial": "pending"
}'
```

**Create and advance instances:**

```bash
# Create instance
cortex put sm_instances '{"id":"order-123","machine":"order","state":"pending","data":{},"updated":1706745600}'

# Advance state
cortex put sm_instances '{"id":"order-123","state":"paid","updated":1706746000}'

# Query by state
cortex query sm_instances '{"machine":"order","state":"pending"}'
```

**Document commands:**

```bash
cortex put commands '{
  "id": "sm:new",
  "scope": "sm",
  "description": "Create a new state machine instance",
  "usage": "sm:new <machine> <instance_id>",
  "example": "cortex put sm_instances {\"id\":\"order-123\",\"machine\":\"order\",\"state\":\"pending\",...}"
}'

# Discover available commands
cortex query commands '{"scope":"sm"}'
```

### Namespace Convention

| Pattern | Example | Access |
|---------|---------|--------|
| `{agent}_private` | `coder_private` | Owner only |
| `{agent}_public` | `coder_public` | Owner writes, world reads |
| `shared_{topic}` | `shared_codebase` | Designated writers, world reads |

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| Linux | Supported | Uses SO_PEERCRED |
| macOS/BSD | Supported | Uses getpeereid() (PID unavailable) |
| Windows | Not supported | No Unix socket credentials |

## Development

```bash
mix deps.get
mix compile
mix test
```

## File Locations

| Path | Purpose |
|------|---------|
| `/usr/local/bin/cortex` | CLI binary (setgid cortex) |
| `/var/lib/cortex/bin/` | Daemon release |
| `/var/lib/cortex/mnesia/` | Data directory |
| `/run/cortex/cortex.sock` | Unix socket |

## Claude Code Integration

Add this to your project's `CLAUDE.md` to enable Cortex usage:

~~~markdown
## Cortex (Local Storage)

Cortex is a local storage daemon accessible via the `cortex` CLI. Data persists across sessions.

### Basic Operations

```bash
# Tables
cortex tables                              # List your tables
cortex create_table NAME key,field1,field2 # First field is primary key
cortex drop_table NAME

# Records
cortex put TABLE '{"key":"k1","field1":"value"}'
cortex get TABLE k1
cortex delete TABLE k1
cortex query TABLE '{"field1":"value"}'    # Pattern match (scans table)
cortex all TABLE

# Access control
cortex acl grant uid:NUMBER TABLE read,write
cortex acl grant '*' TABLE read            # World-readable
cortex acl list
```

### Agent Memory Pattern

Use private tables for internal state and public tables for shared knowledge:

```bash
# Setup (once)
cortex create_table private id,type,content,ts
cortex create_table public id,type,content,ts
cortex acl grant '*' public read

# Store private context
cortex put private '{"id":"ctx-1","type":"context","content":"Working on...","ts":1234567890}'

# Share discoveries
cortex put public '{"id":"fact-1","type":"fact","content":"Learned that...","ts":1234567890}'

# Query by type
cortex query private '{"type":"context"}'
cortex query public '{"type":"fact"}'
```

Tables are namespaced by UID automatically. Your identity comes from the Unix user running the command.
~~~

## Future Work

- TCP/remote access
- Mesh networking / clustering
- Certificates / mTLS
- Token authentication
- Backup/export commands

## License

MIT
