# Cortex

A local storage daemon providing an embedded Mnesia database accessible via Unix socket. UID-based authentication with per-table access control.

**Current version: 0.1.0-beta**

## Features

- **Zero dependencies** - Pre-built binaries, no runtime requirements
- **Embedded storage** - Mnesia database with transactions and pattern matching
- **UID-based auth** - Kernel-enforced identity via SO_PEERCRED (no tokens to steal)
- **Per-table ACLs** - Read, write, admin permissions with world-readable option
- **Cross-platform** - Linux (x86_64, ARM64) and macOS (Intel, Apple Silicon)

## Installation

### Option 1: Pre-built Binaries (Recommended)

One-line install (Linux/macOS):

```bash
curl -fsSL https://raw.githubusercontent.com/noematicsllc/cortexd/main/install-binary.sh | sudo bash
```

This auto-detects your platform and installs both the daemon and CLI.

To install a specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/noematicsllc/cortexd/main/install-binary.sh | sudo CORTEX_VERSION=0.1.0-beta bash
```

Or download manually from [GitHub Releases](https://github.com/noematicsllc/cortexd/releases).

### Option 2: Build from Source

Requires Elixir 1.17+ and Rust (for CLI):

```bash
git clone https://github.com/rynmrtn/cortexd.git
cd cortexd
sudo ./install.sh
sudo systemctl enable --now cortexd
```

## Uninstall

```bash
sudo ./uninstall.sh
```

You'll be prompted whether to keep or delete your data.

## Usage

```bash
# Version and help
cortex --version
cortex --help
cortex help memories    # Usage patterns documentation

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

- **Identity**: UID extracted via SO_PEERCRED/getpeereid (kernel-enforced, cannot be spoofed)
- **Namespacing**: Tables prefixed with creator UID internally
- **Permissions**: Per-table ACLs (read, write, admin)
- **World access**: Special `*` identity for public tables
- **Root access**: UID 0 bypasses all ACL checks (for admin backup/recovery and agent auditing)
- **Socket**: Mode 0666 (any local user can connect; security enforced by ACLs)

## Agent Deployment

AI agents get isolated storage by running as separate Unix users. Each user's UID becomes their Cortex identity (kernel-enforced, cannot be spoofed).

### With Claude Code Plugin (Recommended)

Install the agent-identity plugin for easy agent management:

```bash
# Copy plugin to your project
cp -r /path/to/cortexd/plugins/agent-identity .claude/plugins/

# Run setup (creates sudoers config, shows next steps)
.claude/plugins/agent-identity/setup.sh
```

Then use the slash commands:

```
/spawn-agent agent-myproject-coder "Implement the new feature"
/list-agents
```

See `plugins/agent-identity/README.md` for full setup instructions.

### Manual Setup

```bash
# Create agent user
sudo useradd -r -s /usr/sbin/nologin -G $(whoami) agent-coder

# Run claude as agent (requires sudoers setup)
sudo -u agent-coder claude -p "do agent stuff"
```

The agent's UID becomes its Cortex identity automatically.

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

## What Gets Installed

| Path | What it is |
|------|------------|
| `/usr/local/bin/cortex` | CLI tool (standalone Rust binary, ~800KB, no dependencies) |
| `/var/lib/cortex/bin/` | The daemon (Elixir release with bundled Erlang runtime) |
| `/var/lib/cortex/mnesia/` | Database storage - all your tables and data |
| `/run/cortex/cortex.sock` | Unix socket - how the CLI talks to the daemon |
| `/etc/systemd/system/cortexd.service` | systemd service file |

**Users/Groups created:**
- `cortex` system user and group - the daemon runs as this user for security isolation

**What is Mnesia?**

Mnesia is Erlang's built-in database. It's embedded (no separate server), supports transactions, and can persist to disk. Your data is stored in `/var/lib/cortex/mnesia/`.

**What is an Elixir release?**

A release bundles the Erlang runtime with the application. The daemon runs without needing Elixir installed - everything is in `/var/lib/cortex/bin/`.

## Claude Code Integration

### Plugin Installation

Copy the agent-identity plugin to your project:

```bash
mkdir -p .claude/plugins
cp -r /path/to/cortexd/plugins/agent-identity .claude/plugins/
```

This provides:
- `/spawn-agent <user> "task"` - Run a task as an isolated agent
- `/list-agents` - List agents and their public tables

### CLAUDE.md Template

Add this to your project's `CLAUDE.md`:

~~~markdown
## Cortex (Local Storage)

Cortex provides persistent local storage via the `cortex` CLI.

### Quick Reference

```bash
cortex tables                              # List your tables
cortex create_table NAME key,field1,field2 # Create table (first field = primary key)
cortex put TABLE '{"key":"k1",...}'        # Insert/update record
cortex get TABLE k1                        # Get by key
cortex query TABLE '{"field":"value"}'     # Pattern match
cortex all TABLE                           # List all records
cortex acl grant '*' TABLE read            # Make world-readable
```

### Memory Pattern

```bash
# Setup (once per agent)
cortex create_table memories id,type,content,ts
cortex create_table public id,type,content,ts
cortex acl grant '*' public read

# Store memories
cortex put memories '{"id":"m1","type":"context","content":"...","ts":1234567890}'
cortex put public '{"id":"p1","type":"fact","content":"...","ts":1234567890}'
```

Identity is automatic (Unix UID). Tables are namespaced per user.
~~~

## Future Work

- TCP/remote access
- Mesh networking / clustering
- Certificates / mTLS
- Token authentication
- Backup/export commands

## License

MIT
