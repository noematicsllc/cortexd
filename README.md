# Cortex

> **Status: Experimental** — Cortex is under active development and not ready for production use. APIs, protocols, and data formats may change without notice. Use at your own risk.

A local storage daemon providing an embedded Mnesia database accessible via Unix socket or mesh network. UID-based authentication for local connections, mTLS for remote nodes, with per-table access control.

**Current version: 0.2.5**

## Features

- **Zero dependencies** - Pre-built binaries, no runtime requirements
- **Embedded storage** - Mnesia database with transactions and pattern matching
- **UID-based auth** - Kernel-enforced identity via SO_PEERCRED (no tokens to steal)
- **Per-table ACLs** - Read, write, admin permissions with world-readable option
- **Mesh networking** - mTLS-secured node-to-node communication with certificate management
- **Federated identity** - Cross-node identity registration and token-based claiming
- **Cross-platform** - Linux (x86_64, ARM64) and macOS (Intel, Apple Silicon)

## Installation

### Pre-built Binaries (Recommended)

```bash
sudo ./install.sh
```

This downloads pre-built binaries from GitHub releases for your architecture.

### Build from Source

Requires Elixir 1.17+ and Rust (for CLI):

```bash
git clone https://github.com/noematicsllc/cortexd.git
cd cortexd
sudo ./install.sh --from-source
sudo systemctl enable --now cortexd
```

## Quick Start

```bash
# Start the daemon
sudo systemctl enable --now cortexd

# Health check
cortex ping
cortex status

# Create a table and store data
cortex create-table users id,name,email
cortex put users '{"id":"u1","name":"alice","email":"alice@example.com"}'
cortex get users u1
```

## Uninstall

```bash
sudo ./uninstall.sh
```

You'll be prompted whether to keep or delete your data.

## Command Reference

### Core Commands

```bash
cortex ping                              # Health check
cortex status                            # Daemon status
cortex tables                            # List your tables
```

### Table Operations

```bash
cortex create-table NAME key,field1,field2  # Create table (first field = primary key)
cortex drop-table NAME                      # Drop a table
cortex info NAME                            # Show table metadata
cortex scope NAME                           # Get table's node scope
cortex scope NAME all                       # Set node scope (local, all, or node list)
```

### Record Operations

```bash
cortex put TABLE '{"key":"val",...}'      # Insert/update record
cortex get TABLE key                      # Get by key
cortex delete TABLE key                   # Delete record
cortex query TABLE '{"field":"value"}'    # Pattern match
cortex all TABLE                          # List all records
cortex keys TABLE                         # List all keys
```

### Access Control

```bash
cortex acl grant uid:2001 TABLE read,write  # Grant permissions
cortex acl grant '*' TABLE read             # World-readable
cortex acl revoke uid:2001 TABLE write      # Revoke permissions
cortex acl list                             # List all ACLs
```

### Mesh Networking

```bash
cortex mesh init                          # Initialize mesh and print join token
cortex mesh join TOKEN                    # Join an existing mesh
cortex mesh invite                        # Generate join token for new nodes
cortex mesh init-ca                       # Initialize CA (manual workflow)
cortex mesh add-node NAME HOST            # Generate node cert (manual workflow)
cortex mesh list-nodes                    # List configured mesh nodes
cortex mesh status                        # Show mesh connectivity
```

### Federated Identity

```bash
cortex identity register NAME             # Register identity on this node
cortex identity claim TOKEN               # Claim identity using a token
cortex identity list                      # List all identities
cortex identity revoke NAME               # Revoke identity on this node
cortex identity revoke NAME NODE          # Revoke identity on specific node
```

### Sync & Replication

```bash
cortex sync status                        # Replication status overview
cortex sync status TABLE                  # Table-specific sync status
cortex sync repair TABLE                  # Repair table replication
```

### Help

```bash
cortex help                               # General help
cortex help mesh                          # Mesh networking guide
cortex help identity                      # Federated identity guide
cortex help memories                      # Memory pattern guide
```

## Architecture

### Single Node

```
App / CLI --> Unix socket --> cortexd --> Mnesia
                  |
           SO_PEERCRED (kernel reports UID)
```

### Mesh Network

```
                      mTLS (port 5528)
  cortexd (node-a) <==================> cortexd (node-b)
       |                                     |
   Unix socket                           Unix socket
       |                                     |
   CLI / Apps                            CLI / Apps
```

Tables are namespaced by creator UID (`1000:users`). Local users access their own tables without prefix; cross-user and remote access requires the full identifier (`1000:users`) and appropriate ACL permissions.

## Mesh Networking

### Overview

Cortex nodes form a mesh network using mutual TLS (mTLS). Each node has a certificate signed by a shared CA. Nodes communicate over TCP with MessagePack-RPC, authenticated by their certificates.

Remote connections identify as **nodes**, not users. A TLS connection from `node-b` has `uid=nil` and `requesting_node="node-b"`. Table access for remote nodes requires world-readable ACLs (`*`) and fully-qualified table names.

### Quick Start (Token-Based)

Two commands to form a mesh — handles CA creation, certificates, configuration, and daemon restart automatically:

```
# On the first node:
$ sudo cortex mesh init
Initializing mesh...
  Node name: node1
  Host: 158.69.220.39
  TLS port: 5528
  Cert dir: /etc/cortex/mesh
  Mesh config: /etc/cortex/mesh.env
Restarting cortexd...

Mesh initialized on 158.69.220.39:5528
Join token: cxm_MTU4LjY5LjIyMC4zOTo1NTI4Omth...
Share this token with other nodes to join the mesh.
```

```
# On each additional node (copy-paste the token via any channel):
$ sudo cortex mesh join cxm_MTU4LjY5LjIyMC4zOTo1NTI4Omth...
Joining mesh...
  Seed: 158.69.220.39:5528
  Node name: node2
  Connecting to 158.69.220.39:5529...
  CA fingerprint verified.
  Certificate signed by mesh CA.
Restarting cortexd...
  Mesh configured. Node name: node2
Joined mesh. Connected peers: node1:158.69.220.39:5528
```

To add more nodes later, generate a new join token from any existing mesh node:

```bash
cortex mesh invite
# → cxm_...
```

Both `mesh init` and `mesh join` write certificates to `/etc/cortex/mesh/` and generate `/etc/cortex/mesh.env` with the required environment variables. The daemon is restarted automatically.

### Manual Workflow

For advanced use cases (custom PKI, air-gapped environments, or when nodes can't reach each other during setup):

```bash
# 1. Initialize the CA (once, on any machine)
cortex mesh init-ca

# 2. Generate node certificates
cortex mesh add-node node-a 192.168.1.10
cortex mesh add-node node-b 192.168.1.20

# 3. Distribute certs to each node:
#    ca.crt, {node}.key, {node}.crt → /etc/cortex/mesh/

# 4. Configure each node via environment variables or config
#    (see Environment Variables section below)

# 5. Restart cortexd on each node
```

### Node Configuration

`mesh init` and `mesh join` handle configuration automatically — they write `/etc/cortex/mesh.env` and restart the daemon. Manual configuration is only needed for the manual workflow.

For release-mode deployment, set environment variables (see [Environment Variables](#environment-variables)). For development, use `config/config.exs`:

```elixir
config :cortex, :mesh,
  node_name: "node-a",
  tls_port: 5528,
  ca_cert: "/etc/cortex/mesh/ca.crt",
  node_cert: "/etc/cortex/mesh/nodes/node-a.crt",
  node_key: "/etc/cortex/mesh/nodes/node-a.key",
  nodes: [
    {"node-b", "192.168.1.20", 5528}
  ]
```

## Federated Identity

Federated identity links a local UID on one node to a name that other nodes can reference. This enables cross-node table access without exposing raw UIDs.

```bash
# On node-a: register user alice (links UID 1001 to name "alice")
cortex identity register alice

# Share the claim token with node-b (out of band)
# On node-b: claim the identity
cortex identity claim <token>

# Now node-b can reference alice's tables via federated name
```

## Security Model

- **Local identity**: UID extracted via SO_PEERCRED/getpeereid (kernel-enforced, cannot be spoofed)
- **Remote identity**: mTLS certificate CN identifies the connecting node
- **Namespacing**: Tables prefixed with creator UID internally
- **Permissions**: Per-table ACLs (read, write, admin)
- **World access**: Special `*` identity for public tables
- **Root access**: UID 0 bypasses all ACL checks (scoped to local machine only)
- **Socket**: Mode 0666 (any local user can connect; security enforced by ACLs)

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `CORTEX_MESH_NODE_NAME` | Node name (enables mesh mode) | `node-a` |
| `CORTEX_MESH_HOST` | Host address for Erlang distribution | `192.168.1.10` |
| `CORTEX_MESH_TLS_PORT` | TLS listener port | `5528` |
| `CORTEX_MESH_CA_CERT` | Path to CA certificate | `/etc/cortex/mesh/ca.crt` |
| `CORTEX_MESH_NODE_CERT` | Path to node certificate | `/etc/cortex/mesh/nodes/node-a.crt` |
| `CORTEX_MESH_NODE_KEY` | Path to node private key | `/etc/cortex/mesh/nodes/node-a.key` |
| `CORTEX_MESH_NODES` | Comma-separated peer list | `node-b:192.168.1.20:5528` |
| `CORTEX_SOCKET_PATH` | Unix socket path | `/run/cortex/cortex.sock` |
| `CORTEX_DATA_DIR` | Mnesia data directory | `/var/lib/cortex/mnesia` |

## Agent Deployment

AI agents get isolated storage by running as separate Unix users. Each user's UID becomes their Cortex identity (kernel-enforced, cannot be spoofed).

```bash
# Create agent user
sudo useradd -r -s /usr/sbin/nologin agent-coder

# Run as agent
sudo -u agent-coder claude -p "do agent stuff"
```

The agent's UID becomes its Cortex identity automatically.

## Usage Patterns

### Agent Memory (Public + Private)

```bash
# Agent creates its memory tables
cortex create-table private id,type,content,ts
cortex create-table public id,type,content,ts

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
| `/usr/local/bin/cortex` | CLI tool (standalone Rust binary, ~900KB, no dependencies) |
| `/var/lib/cortex/bin/` | The daemon (Elixir release with bundled Erlang runtime) |
| `/var/lib/cortex/mnesia/` | Database storage - all your tables and data |
| `/run/cortex/cortex.sock` | Unix socket - how the CLI talks to the daemon |
| `/etc/systemd/system/cortexd.service` | systemd service file |

## License

MIT
