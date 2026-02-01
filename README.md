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

Each AI agent can run as a dedicated system user:

```bash
sudo useradd -r -s /usr/sbin/nologin agent-coder
sudo -u agent-coder claude -p "do agent stuff"
```

The agent's UID becomes its Cortex identity automatically. No tokens or API keys needed.

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

## Future Work

- TCP/remote access
- Mesh networking / clustering
- Certificates / mTLS
- Token authentication
- Backup/export commands

## License

MIT
