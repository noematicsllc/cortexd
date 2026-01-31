# Cortex Planning Document

## What is Cortex?

Cortex is a distributed storage daemon for local-first applications. It provides a mesh-networked Mnesia database accessible via Unix socket, TCP, or CLI.

**Not opinionated.** Cortex doesn't dictate schemas, workflows, or how you structure your data. It's infrastructure—a building block for whatever you want to build on top. Agent memory, session state, distributed cache, offline-first sync—your call.

**Why Mnesia?** Embedded (no external database), distributed (built-in replication), and battle-tested (Erlang/OTP). One binary, zero dependencies, mesh networking out of the box.

## Design Principles

1. **Infrastructure, not framework** - Generic storage primitives. No opinions on schema or usage.
2. **Zero external dependencies** - No Docker, no Postgres, no Redis. Just the binary.
3. **Local-first** - Data lives on your machine. You own it.
4. **Mesh-native** - Distributed by default. Nodes find and replicate to each other.
5. **Simple install** - Clone, build, install. Enable service. Done.

## Architecture

```
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│   Your App      │ │   CLI           │ │   Another App   │
└────────┬────────┘ └────────┬────────┘ └────────┬────────┘
         │                   │                   │
         └───────────────────┼───────────────────┘
                             │ Unix socket / TCP
                             ▼
┌─────────────────────────────────────────────────────────┐
│                        cortexd                           │
│                                                         │
│                          ▼                              │
│                 ┌─────────────────┐                     │
│                 │     Mnesia      │                     │
│                 │  (embedded db)  │                     │
│                 └─────────────────┘                     │
│                          │                              │
│         ┌────────────────┼────────────────┐             │
│         ▼                ▼                ▼             │
│  /var/lib/cortex/mnesia/                                │
└─────────────────────────────────────────────────────────┘
          │
          │ Erlang distribution
          ▼
┌─────────────────────┐
│  cortexd@remote     │  ← Mesh peer
└─────────────────────┘
```

## Technology Choices

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Language | Elixir | OTP supervision, distribution, Mnesia access |
| Database | Mnesia | Embedded, zero-config, distributed replication built-in |
| IPC | Unix socket + MessagePack | Fast local access, language-agnostic protocol |
| Remote | TCP + MessagePack | Same protocol for remote clients |
| Distribution | Erlang clustering | Native mesh networking, automatic failover |
| Packaging | Mix release | Self-contained binary, no runtime deps |

## Data Model

Phase 1 provides generic Mnesia table operations. Specific schemas (memories, projects, tasks) are defined when the data model layer is implemented.

### Generic Operations

| Operation | Description |
|-----------|-------------|
| `create_table` | Define a new table with attributes |
| `put` | Insert or update a record |
| `get` | Retrieve by key |
| `delete` | Remove a record |
| `match` | Query by pattern |
| `all` | List all records in table |

### Example: Agent Memory Schema

Someone building an agent memory system might create:
```
memories: id, content, category, priority, tags, project_id, expires_at
projects: id, git_remote, name
workspaces: id, path, project_id
```

But Cortex doesn't care—define whatever tables you need.

## RPC Interface

Communication via MessagePack-RPC over Unix socket (local) or TCP (remote).

### Core Methods

| Method | Params | Description |
|--------|--------|-------------|
| `ping` | - | Health check |
| `status` | - | Daemon status, cluster info |
| `create_table` | name, attributes, indexes? | Create a Mnesia table |
| `put` | table, record | Insert/update record |
| `get` | table, key | Get record by key |
| `delete` | table, key | Delete record |
| `match` | table, pattern | Query by match pattern |
| `all` | table | List all records |

### Mesh Methods

| Method | Params | Description |
|--------|--------|-------------|
| `cluster_status` | - | List connected peers |
| `cluster_connect` | node | Connect to peer |
| `cluster_disconnect` | node | Disconnect from peer |
| `query_mesh` | table, pattern | Query across all nodes |

## CLI Interface

```bash
cortex <command> [args]

# Status
cortex status                    # Daemon status, cluster info

# Mesh
cortex cluster                   # Show connected peers
cortex cluster connect <node>    # Connect to peer
cortex cluster disconnect <node> # Disconnect from peer

# Data (generic)
cortex tables                    # List tables
cortex create_table <name> <attrs> [--replicate local|mesh|peers:...] [--indexes ...]
cortex get <table> <key>         # Get record
cortex put <table> <json>        # Insert/update record
cortex delete <table> <key>      # Delete record
cortex query <table> <pattern>   # Query by pattern

# Access control
cortex acl grant <identity> <table> <perms>   # Grant read,write
cortex acl revoke <identity> <table> <perms>  # Revoke permissions
cortex acl list [identity]                    # List ACLs

# Remote auth (tokens)
cortex token create --name <name>   # Create bearer token
cortex token list                   # List tokens
cortex token revoke <name>          # Revoke token

# Certificates (mesh + remote clients)
cortex ca init                      # Initialize CA
cortex ca issue node                # Issue node cert for mesh
cortex ca issue client --name <n>   # Issue client cert
```

## Installation

### Standard install (system service)

```bash
git clone https://github.com/noematicsllc/cortex.git
cd cortex
sudo ./install.sh
```

### install.sh does:

1. Check prerequisites (Elixir for building)
2. Build release: `MIX_ENV=prod mix release`
3. Create `cortex` group
4. Copy release to `/var/lib/cortex/`
5. Install binary to `/usr/local/bin/cortex`
6. Create config directory `/etc/cortex/`
7. Install systemd service: `/etc/systemd/system/cortexd.service`
8. Print next steps

### After install:

```bash
sudo systemctl enable --now cortexd
cortex status

# Add yourself to cortex group (log out/in to take effect)
sudo usermod -aG cortex $USER
```

### Creating agent users:

```bash
sudo useradd -r -s /usr/sbin/nologin -G cortex agent-planner
sudo useradd -r -s /usr/sbin/nologin -G cortex agent-coder
# etc.
```

### Alternative: User service (single-user, no sudo)

For personal machines or when root access isn't available:

```bash
./install.sh --user
```

This installs to `~/.local/` with a user systemd service. UID-based agent isolation is not available in this mode—all access runs as your user.

### File locations

**System service** (default):
| Path | Contents |
|------|----------|
| `/usr/local/bin/cortex` | CLI binary |
| `/var/lib/cortex/` | Release + Mnesia data |
| `/run/cortex/cortex.sock` | Unix socket (mode 0660, group cortex) |
| `/etc/cortex/` | Certs, config, ACLs |
| `/etc/systemd/system/cortexd.service` | Systemd unit |

**User service** (`--user`):
| Path | Contents |
|------|----------|
| `~/.local/bin/cortex` | CLI binary (symlink) |
| `~/.local/share/cortex/` | Release + Mnesia data |
| `~/.local/run/cortex.sock` | Unix socket (mode 0600) |
| `~/.config/cortex/` | Certs, config |
| `~/.config/systemd/user/cortexd.service` | Systemd unit |

## Client Integration

Cortex is a distributed store accessible via CLI or socket.

### CLI

```bash
# Create a table
cortex create_table users id,name,email --indexes name

# Store data
cortex put users '{"id": "u1", "name": "alice", "email": "alice@example.com"}'

# Retrieve data
cortex get users u1

# Query
cortex query users '{"name": "alice"}'
```

### RPC Protocol

MessagePack-RPC over Unix socket (local) or TCP (remote).

Request format: `[type, msgid, method, params]`
- `type`: 0 for request
- `msgid`: integer, echoed in response
- `method`: string, the RPC method name
- `params`: map of parameters

Response format: `[type, msgid, error, result]`
- `type`: 1 for response
- `msgid`: matches request
- `error`: null on success, error info on failure
- `result`: method return value

### RPC Example (Python)

```python
import socket
import msgpack

# Connect to system socket
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("/run/cortex/cortex.sock")

# Put a record: [type=0, msgid=1, method, params]
request = msgpack.packb([0, 1, "put", {"table": "users", "record": {"id": "u1", "name": "alice"}}])
sock.send(request)
response = msgpack.unpackb(sock.recv(4096))
# response: [1, 1, null, {"ok": true}]

# Query across mesh
request = msgpack.packb([0, 2, "query_mesh", {"table": "users", "pattern": {"name": "alice"}}])
sock.send(request)
response = msgpack.unpackb(sock.recv(4096))
# response: [1, 2, null, {"records": [...], "nodes": ["node1", "node2"]}]
```

Higher-level APIs (like `store_memory`, `recall`) would be built in application code on top of these primitives.

## Implementation Phases

### Phase 1: Infrastructure
- [ ] Project skeleton with Mix release config
- [ ] Mnesia store module (init, generic table ops)
- [ ] Unix socket server (MessagePack-RPC)
- [ ] UID-based identity via SO_PEERCRED
- [ ] TCP server with TLS
- [ ] Token auth for remote clients
- [ ] Per-table ACLs
- [ ] Erlang clustering (mesh networking)
- [ ] mTLS for mesh peers
- [ ] CLI (status, cluster, acl, token)
- [ ] Systemd service templates (user + system)
- [ ] install.sh script

### Example applications (separate projects)

Things you could build on Cortex:
- Agent memory system (memories, recall, context assembly)
- Task/project planning (tasks, dependencies, milestones)
- Session state sync (offline-first, multi-device)
- Distributed cache (mesh-replicated key-value)
- Config management (versioned, replicated settings)

## Security Model

### Design Philosophy

Tokens and keys are only as secure as the boundary around them. If an agent runs as your user, it can read your tokens—there's no real isolation.

**Solution:** Use OS user accounts for agent identity. The kernel enforces UID, and UIDs can't be forged. Cortexd derives identity from the connecting process's UID via `SO_PEERCRED`.

### Layers

| Layer | Threat | Mitigation |
|-------|--------|------------|
| Transport | Eavesdropping, MITM | TLS for TCP (mesh + remote clients) |
| Peer auth | Rogue node joins mesh | Mutual TLS (mTLS) with CA |
| Local identity | Agent impersonation | UID-based identity (kernel-enforced) |
| Remote identity | Unauthorized remote access | Tokens or client certificates |
| Data access | Unauthorized read/write | Per-table ACLs |

### Local Identity: UID-Based

For local and group sockets, identity is derived from the connecting process's UID:

```
agent-coder (UID 2001) connects
    → kernel reports UID via SO_PEERCRED
    → identity is "user:2001" or "agent-coder" (mapped)
    → ACLs checked for that identity
    → can't impersonate agent-planner (would need UID 2002)
```

No tokens to steal. No credentials to leak. The kernel enforces who you are.

### Multi-User Agent Setup

Create dedicated users for each agent role:

```bash
# Create agent users (no login shell, no home needed)
sudo useradd -r -s /usr/sbin/nologin -G cortex agent-planner
sudo useradd -r -s /usr/sbin/nologin -G cortex agent-architect
sudo useradd -r -s /usr/sbin/nologin -G cortex agent-coder
sudo useradd -r -s /usr/sbin/nologin -G cortex agent-reviewer

# Run agents as their role users
sudo -u agent-planner claude-code /path/to/project
sudo -u agent-coder aider /path/to/project
```

Each agent:
- Has a unique UID tied to its role
- Can connect to cortexd (member of `cortex` group)
- Gets its own identity and ACLs
- Cannot access other agents' data without explicit grants

### Socket Modes

**System service** (default):
```
/run/cortex/cortex.sock (mode 0660, group cortex)
    → any user in cortex group can connect
    → identity = connecting process's UID
    → ACLs separate users
```

**User service** (`--user`):
```
~/.local/run/cortex.sock (mode 0600)
    → only owner can connect
    → identity = owner's UID
    → no multi-agent isolation
```

### Remote Identity: Tokens or Certificates

UID doesn't travel over the network. For TCP connections (remote clients, mesh peers), explicit authentication is required.

**Mesh peers:** Mutual TLS (mTLS)
```bash
# Generate CA (once, share across trusted nodes)
cortex ca init

# Generate node cert (on each node)
cortex ca issue node

# Nodes verify each other's certs on connect
```

**Remote clients:** Bearer tokens or client certs
```bash
# Create a token for remote access
cortex token create --name remote-app

# Or issue a client certificate
cortex ca issue client --name remote-app
```

### Transport: TLS for TCP

All TCP connections use TLS:
- Mesh node ↔ node: mTLS (mutual verification)
- Remote client → daemon: TLS + token or client cert

```
/etc/cortex/
├── ca.crt           # CA cert (shared across trusted mesh)
├── node.crt         # This node's cert (signed by CA)
└── node.key         # This node's private key
```

Unix sockets don't need TLS—they're local and the kernel handles access control.

### Data Access Control (ACLs)

Per-table permissions, attached to identity (UID, token name, or cert CN).

```bash
# Grant access
cortex acl grant agent-coder source-files read,write
cortex acl grant agent-reviewer source-files read
cortex acl grant agent-planner tasks read,write
cortex acl grant agent-architect decisions read,write

# Revoke
cortex acl revoke agent-reviewer source-files read

# List
cortex acl list agent-coder
```

Default: table creator has full access. No implicit access for others.

### Replication Policies

When creating a table, specify where data can live:

```bash
# Local only (secrets, credentials)
cortex create_table secrets --replicate local

# Full mesh (shared state)
cortex create_table shared-state --replicate mesh

# Specific peers only
cortex create_table team-data --replicate peers:node1,node2
```

Data only replicates to nodes/identities that have access.

## Open Questions

1. **UID mapping**: How to map UIDs to friendly names?
   - Read from `/etc/passwd` (system users)
   - Cortex config file mapping UID → name
   - Just use numeric UIDs

2. **CA distribution**: How to bootstrap mesh trust?
   - Manual: copy ca.crt to each node
   - TOFU (trust on first use)
   - QR code / out-of-band exchange

3. **ACL storage**: Where do ACLs live?
   - Mnesia table (local only—each node controls its own access)
   - Config file
   - Both (config as source of truth, cached in Mnesia)

4. **Backup/export**: How to back up data?
   - File copy when daemon stopped
   - `cortex export` / `cortex import` commands
   - Both

5. **Node discovery**: How do mesh peers find each other?
   - Manual (`cortex cluster connect`)
   - mDNS/DNS-SD for LAN auto-discovery
   - Config file with known peers

## Non-Goals (for now)

- Web UI
- Cloud hosting
- Windows support
