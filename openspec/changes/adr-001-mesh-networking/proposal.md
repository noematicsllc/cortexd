## Why

Cortex v1 is single-machine only. Users want to sync agent data across nodes (home server, laptop, cloud VPS), access their data from any machine, and provide redundancy. The Unix socket UID authentication model doesn't work over the network, so we need secure node-to-node communication with a way to link user identities across machines.

## What Changes

- Nodes authenticate to each other via mutual TLS (mTLS) with a per-mesh self-signed CA
- A new TCP+TLS listener runs alongside the existing Unix socket (local access unchanged)
- User identities can be linked across nodes via a federated identity registry — UID 1000 on desktop and UID 1001 on laptop both resolve to "alice"
- Tables gain a `node_scope` field controlling where data can exist: `:local`, `:all`, or a specific node list
- Authorization checks gain a second dimension: identity ACL (who) AND node scope (where) must both pass
- Data replicates across nodes via Mnesia clustering, driven by each table's node scope
- **BREAKING**: `cortex_meta` schema gains a `node_scope` field (migration needed for existing tables, defaulting to `:local`)
- New CLI commands for mesh management, identity linking, node scope control, and sync status
- Table namespacing extended: `@alice:memories` for federated tables alongside existing `1000:memories` for local-only

## Capabilities

### New Capabilities
- `node-authentication`: mTLS between nodes — CA management, certificate generation, TCP+TLS listener, node identity extraction from peer certificates, mesh topology configuration.
- `federated-identity`: Linking user identities across nodes — identity registry (`cortex_identities` system table), registration and claim-token flow, identity resolution (local UID → federated ID), revocation.
- `node-scope`: Controlling where table data can exist — `node_scope` field on table metadata, node scope authorization check, `--scope` flag on table creation, scope management commands.
- `data-replication`: Syncing data across the mesh — Mnesia clustering setup, replication driven by node scope, node join/leave handling, sync status and repair tooling. Async multi-master with last-write-wins conflict resolution.

### Modified Capabilities
<!-- No existing specs — cortexd has no formal specs yet. All capabilities listed as new. -->

## Impact

- **Identity module**: Extended to resolve both local (UID) and remote (certificate CN → federated ID) identities
- **ACL module**: Authorization gains `check_node_scope/2` as a second gate alongside identity ACL checks
- **Handler module**: Must handle connections from both Unix socket and TLS, with different identity resolution paths
- **Store module**: `cortex_meta` schema extended with `node_scope`; new `cortex_identities` and `cortex_services` system tables
- **Server module**: New TLS listener alongside Unix socket listener
- **Supervision tree**: New processes for mesh connections, replication management
- **Dependencies**: Erlang `:ssl` module, possibly `:public_key` for certificate handling; JWT library for claim tokens
- **CLI**: New command groups (`mesh`, `identity`, `scope`, `sync`) plus `--scope` flag on `create`
- **Config**: New `mesh` config section for node list, certificate paths
- **Data migration**: Existing tables need `node_scope: :local` backfilled on upgrade
