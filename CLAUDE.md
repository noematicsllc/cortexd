# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

Cortex is a local storage daemon providing an embedded Mnesia database accessible via Unix socket or CLI. Version 1 focuses on single-machine operation.

**Core philosophy:** Infrastructure, not framework. Generic storage primitives with no opinions on schema or usage patterns.

## Technology Stack

- **Language:** Elixir (OTP supervision, Mnesia access)
- **Database:** Mnesia (embedded, transactions, pattern matching)
- **IPC:** Unix socket + MessagePack-RPC
- **Socket:** `gen_tcp` with local address family
- **Auth:** UID-based via SO_PEERCRED/getpeereid (kernel-enforced, cross-platform NIF)
- **Packaging:** Mix release + escript CLI

## Build Commands

```bash
mix deps.get              # Get dependencies
mix compile               # Compile
mix test                  # Run tests
MIX_ENV=prod mix release  # Build release
sudo ./install.sh         # Install system service
```

## Architecture

```
App / CLI → Unix socket → cortexd → Mnesia
```

### Key Modules

- `lib/cortex/store.ex` - Mnesia operations
- `lib/cortex/server.ex` - Socket accept loop (`gen_tcp`)
- `lib/cortex/handler.ex` - Connection handler (DynamicSupervisor child)
- `lib/cortex/protocol.ex` - MessagePack-RPC
- `lib/cortex/identity.ex` - UID extraction via peercred NIF
- `lib/cortex/peercred.ex` - NIF wrapper for peer credentials
- `lib/cortex/acl.ex` - Per-table access control
- `lib/cortex/client.ex` - Client for CLI
- `lib/cortex/cli.ex` - CLI interface
- `c_src/peercred_nif.c` - Cross-platform peercred NIF (Linux + macOS)

### Security Model

- **Identity:** UID via peer credentials (kernel-enforced, cannot be spoofed; Linux + macOS)
- **Namespacing:** Tables prefixed with creator UID internally (`1000:users`)
- **Access:** Per-table ACLs (read, write, admin)
- **World access:** Special `*` identity for public tables
- **Root access:** UID 0 bypasses all ACL checks (for backup/recovery and agent auditing)
- **Socket:** Mode 0666 (any local user can connect; security enforced by ACLs)

### Agent Deployment

Each AI agent runs as a dedicated system user:
```bash
sudo useradd -r -s /usr/sbin/nologin agent-coder
sudo -u agent-coder claude -p "do agent stuff"
```
The agent's UID becomes its Cortex identity automatically.

## RPC Protocol

MessagePack-RPC format:
- Request: `[0, msgid, method, params]`
- Response: `[1, msgid, error, result]`

Methods: `ping`, `status`, `tables`, `create_table`, `drop_table`, `put`, `get`, `delete`, `match`, `all`, `acl_grant`, `acl_revoke`, `acl_list`

## Data Model

- Records stored as `{table_atom, key, data_map}` tuples
- First attribute in `create_table` is the primary key field
- Remaining attributes are documentation only (not enforced)
- `match` operations scan the table (no secondary indexes in v1)
- ACLs stored in system Mnesia table `cortex_acls`

## Usage Patterns

**Agent Memory** - Public and private memories for AI agents:
- `{agent}_private` - internal state, owner only
- `{agent}_public` - shared knowledge, world-readable

**State Machine + Commands** - Workflows with discoverable command templates:
- `sm_definitions` - state machine schemas
- `sm_instances` - workflow instances
- `commands` - documented query templates

See README.md for full examples.

## File Locations

- **CLI:** `/usr/local/bin/cortex`
- **Daemon:** `/var/lib/cortex/bin/`
- **Socket:** `/run/cortex/cortex.sock` (mode 0666)
- **Data:** `/var/lib/cortex/mnesia/`
- **Service:** `/etc/systemd/system/cortexd.service`

## Future Work (v2+)

- TCP/remote access
- Mesh networking
- Certificates / mTLS
- Token authentication
- Backup/export
