# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cortex is a distributed storage daemon for local-first applications. It provides a mesh-networked Mnesia database accessible via Unix socket, TCP, or CLI. The project is in early development (Phase 1).

**Core philosophy:** Infrastructure, not framework. Generic storage primitives with no opinions on schema or usage patterns.

## Technology Stack

- **Language:** Elixir (OTP supervision, distribution, Mnesia access)
- **Database:** Mnesia (embedded, distributed replication built-in)
- **IPC:** Unix socket + MessagePack-RPC (local), TCP + MessagePack (remote)
- **Distribution:** Erlang clustering for mesh networking
- **Packaging:** Mix release (self-contained binary)

## Build Commands

```bash
# Build release
MIX_ENV=prod mix release

# Development
mix deps.get
mix compile
mix test

# Install (system service)
sudo ./install.sh

# Install (user service, no root)
./install.sh --user
```

## Architecture

```
App / CLI → Unix socket / TCP → cortexd daemon → Mnesia (embedded)
                                       ↓
                              Erlang distribution → mesh peers
```

### Key Modules (planned structure)

- `lib/cortex/store.ex` - Mnesia operations (create_table, put, get, delete, match, all)
- `lib/cortex/server/unix_socket.ex` - Local MessagePack-RPC server
- `lib/cortex/server/tcp.ex` - Remote TLS server
- `lib/cortex/auth/` - UID-based local identity, tokens, ACLs
- `lib/cortex/cluster/` - Erlang clustering, mTLS for mesh peers
- `lib/cortex/cli.ex` - CLI interface

### Security Model

- **Local identity:** UID-based via `SO_PEERCRED` (kernel-enforced, no tokens needed)
- **Remote identity:** Bearer tokens or client certificates
- **Transport:** TLS for TCP connections, Unix sockets use kernel access control
- **Data access:** Per-table ACLs attached to identity

## RPC Protocol

MessagePack-RPC format:
- Request: `[0, msgid, method, params]`
- Response: `[1, msgid, error, result]`

Core methods: `ping`, `status`, `create_table`, `put`, `get`, `delete`, `match`, `all`
Mesh methods: `cluster_status`, `cluster_connect`, `cluster_disconnect`, `query_mesh`

## File Locations

**System service:**
- Binary: `/usr/local/bin/cortex`
- Data: `/var/lib/cortex/`
- Socket: `/run/cortex/cortex.sock`
- Config: `/etc/cortex/`

**User service:**
- Data: `~/.local/share/cortex/`
- Socket: `~/.local/run/cortex.sock`
- Config: `~/.config/cortex/`
