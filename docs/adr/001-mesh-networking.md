# ADR-001: Mesh Networking with mTLS and Federated Identity

**Status:** Proposed
**Date:** 2026-02-01
**Authors:** Marshall Scott, Claude

## Context

Cortex v1 is a single-machine storage daemon using Unix domain sockets with UID-based authentication via `SO_PEERCRED`. This provides kernel-enforced identity that cannot be spoofed locally.

Users want to expand Cortex to multiple machines to:
- Sync agent data across nodes (e.g., home server ↔ cloud VPS)
- Provide redundancy and fault tolerance
- Allow agents to access their data from any node in the mesh

The challenge: Unix socket UID authentication doesn't work over the network. We need a secure way to:
1. Authenticate nodes to each other
2. Link user identities across nodes
3. Sync data while preserving the ownership model

## Decision Drivers

- **Security first**: No regression from current kernel-enforced auth
- **Simplicity**: Small mesh (2-10 nodes), not hyperscale
- **Backward compatibility**: Local Unix socket access unchanged
- **Agent-friendly**: Agents shouldn't need to manage credentials manually
- **Offline resilience**: Nodes should function independently during network partitions

## Considered Options

### Option 1: Shared Secret / API Tokens
- Nodes share a pre-shared key or issue tokens
- Simple to implement
- **Rejected**: Tokens can leak, no cryptographic node identity, rotation is painful

### Option 2: mTLS with Federated Identity (Selected)
- Nodes authenticate via mutual TLS certificates
- User identities linked across nodes via federation registry
- Certificates provide strong cryptographic identity

### Option 3: Erlang Distribution + Cookie
- Use built-in Erlang clustering with shared cookie
- **Rejected**: Cookie is a weak shared secret, designed for trusted networks only

### Option 4: External Identity Provider (OAuth/OIDC)
- Delegate to external IdP (Keycloak, Auth0, etc.)
- **Rejected**: Adds operational complexity, external dependency, overkill for small mesh

## Decision

Implement **mTLS for node authentication** with a **federated identity registry** for cross-node user linking.

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Cortex Mesh                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐          mTLS           ┌──────────────┐      │
│  │  cortex-a    │◄────────────────────────►│  cortex-b    │      │
│  │              │                          │              │      │
│  │ Unix: UID    │                          │ Unix: UID    │      │
│  │ TCP:  cert   │                          │ TCP:  cert   │      │
│  │              │          mTLS            │              │      │
│  └──────┬───────┘◄────────────────────────►└──────────────┘      │
│         │                                          ▲              │
│         │ mTLS                                     │              │
│         ▼                                          │              │
│  ┌──────────────┐                                  │              │
│  │  cortex-c    │◄─────────────────────────────────┘              │
│  └──────────────┘                                                │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Identity Layers

| Layer | Scope | Mechanism | Example |
|-------|-------|-----------|---------|
| Node Identity | Inter-node | mTLS certificate CN | `cortex-node-a` |
| Local Identity | Intra-node | SO_PEERCRED UID | `1000` |
| Federated Identity | Cross-node | Identity registry | `alice` |

### Access Control Layers

Access control has two independent dimensions:

| Dimension | Question | Controls |
|-----------|----------|----------|
| **Identity ACL** | "Who can access this table?" | Users/identities and their permissions |
| **Node Scope** | "Where can this table exist?" | Which nodes can hold/access the data |

Both checks must pass for access to be granted.

#### Node Scope Values

| Scope | Meaning | Use Case |
|-------|---------|----------|
| `:local` | Local node only, no replication | Sensitive data, scratch tables |
| `:all` | Replicate to all mesh nodes | Public knowledge bases, shared data |
| `["node-a", "node-b"]` | Specific nodes only | Team data, regional compliance |

#### Examples

```
┌─────────────────────────────────────────────────────────┐
│  Table: @alice:knowledge (public knowledge base)        │
├─────────────────────────────────────────────────────────┤
│  Identity ACL:     * → [:read]      (world readable)    │
│                    alice → [:read, :write, :admin]      │
│                                                         │
│  Node Scope:       :all             (replicate everywhere)
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Table: @alice:secrets (private, local only)            │
├─────────────────────────────────────────────────────────┤
│  Identity ACL:     alice → [:read, :write, :admin]      │
│                                                         │
│  Node Scope:       :local           (never leaves home) │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Table: @team:projects (shared, specific nodes)         │
├─────────────────────────────────────────────────────────┤
│  Identity ACL:     alice → [:read, :write, :admin]      │
│                    bob → [:read, :write]                │
│                    * → [:read]      (world readable)    │
│                                                         │
│  Node Scope:       ["home", "office"]  (team nodes only)│
└─────────────────────────────────────────────────────────┘
```

#### Authorization Flow

```elixir
def authorize(identity, table, operation, requesting_node) do
  with :ok <- check_node_scope(table, requesting_node),
       :ok <- check_identity_acl(identity, table, operation) do
    :ok
  end
end

defp check_node_scope(table, node) do
  case Store.get_table_meta(table) do
    {:ok, %{node_scope: :all}} -> :ok
    {:ok, %{node_scope: :local}} when node == Node.self() -> :ok
    {:ok, %{node_scope: :local}} -> {:error, :access_denied}
    {:ok, %{node_scope: nodes}} when is_list(nodes) ->
      if node in nodes, do: :ok, else: {:error, :access_denied}
  end
end
```

### Component Design

#### 1. Certificate Authority (CA)

Each mesh has a self-signed CA. All node certificates are signed by this CA.

```
cortex-mesh-ca/
├── ca.key          # CA private key (keep secure!)
├── ca.crt          # CA certificate (distribute to all nodes)
└── nodes/
    ├── cortex-a.key
    ├── cortex-a.crt
    ├── cortex-b.key
    ├── cortex-b.crt
    └── ...
```

Certificates include:
- **CN (Common Name)**: Node identifier (e.g., `cortex-node-a`)
- **SAN (Subject Alt Name)**: DNS/IP for connection validation
- **Validity**: Recommend 1 year, with rotation tooling

#### 2. Network Listeners

Each node runs two listeners:

```elixir
# Unix socket (local only, UID auth)
{:local, "/run/cortex/cortex.sock"}

# TCP + TLS (remote, mTLS auth)
{:tcp, {0, 0, 0, 0}, 4711, [
  certfile: "certs/node.crt",
  keyfile: "certs/node.key",
  cacertfile: "certs/ca.crt",
  verify: :verify_peer,
  fail_if_no_peer_cert: true
]}
```

#### 3. Identity Resolution

```elixir
defmodule Cortex.Identity do
  # Local connection: extract UID from socket
  def resolve(%{transport: :unix, socket: sock}) do
    {:ok, uid} = Cortex.Peercred.get_uid(sock)
    {:local, uid}
  end

  # Remote connection: extract node ID from certificate
  def resolve(%{transport: :tls, socket: sock}) do
    {:ok, cert} = :ssl.peercert(sock)
    {:ok, cn} = extract_cn(cert)
    {:remote, cn}
  end

  # Map to federated identity if registered
  def to_federated({:local, uid}, node) do
    case Store.lookup_federated_by_local(node, uid) do
      {:ok, fed_id} -> {:federated, fed_id}
      :not_found -> {:local, node, uid}
    end
  end
end
```

#### 4. Federated Identity Registry

New system table `cortex_identities`, replicated to all nodes:

```elixir
# Schema
{:cortex_identities, federated_id, mappings, metadata}

# Example record
{:cortex_identities,
  "alice",
  %{
    "cortex-node-a" => 1000,
    "cortex-node-b" => 1001
  },
  %{
    created_at: ~U[2026-02-01 12:00:00Z],
    created_by: "cortex-node-a"
  }
}
```

#### 5. Identity Linking Protocol

**Registration (on home node):**
```
User (UID 1000) on cortex-node-a:
$ cortex identity register alice

→ Creates federated identity "alice"
→ Maps cortex-node-a:1000 → alice
→ Outputs claim token (JWT signed by node)
```

**Claim token structure:**
```json
{
  "fed_id": "alice",
  "origin_node": "cortex-node-a",
  "origin_uid": 1000,
  "issued_at": 1706788800,
  "expires_at": 1706875200,
  "sig": "<node-a signature>"
}
```

**Claiming (on remote node):**
```
User (UID 1001) on cortex-node-b:
$ cortex identity claim <token>

→ Verify token signature via mTLS to cortex-node-a
→ Add mapping: cortex-node-b:1001 → alice
→ Replicate updated registry to all nodes
```

#### 6. Table Namespacing and Metadata

Two namespace types:

| Prefix | Scope | Default Node Scope |
|--------|-------|-------------------|
| `1000:table` | Local UID | `:local` (no sync) |
| `@alice:table` | Federated | `:all` (sync everywhere) |

**Extended table metadata schema:**

```elixir
# cortex_meta record (extended for mesh)
{:cortex_meta, table_name, owner_uid, key_field, attributes, node_scope}

# Examples:
{:cortex_meta, :"1000:scratch", 1000, :id, [:data], :local}
{:cortex_meta, :"@alice:memories", 1000, :id, [:content], :all}
{:cortex_meta, :"@alice:secrets", 1000, :id, [:content], :local}
{:cortex_meta, :"@team:docs", 1000, :id, [:title, :body], ["home", "office"]}
```

**CLI examples:**

```elixir
# Local table (backward compatible, defaults to :local scope)
cortex create users id name email
# → Creates table "1000:users", node_scope: :local

# Federated table (defaults to :all scope)
cortex create @memories id content timestamp
# → Creates table "@alice:memories", node_scope: :all

# Federated table with restricted node scope
cortex create @secrets id content --scope local
# → Creates table "@alice:secrets", node_scope: :local

# Federated table with specific nodes
cortex create @team:docs id title body --scope home,office
# → Creates table "@team:docs", node_scope: ["home", "office"]
```

#### 7. Data Replication

Mnesia-based replication driven by node scope:

```elixir
defmodule Cortex.Sync do
  @doc """
  Set up replication based on table's node_scope.
  Called when:
  - Table is created with non-local scope
  - Node scope is changed
  - New node joins the mesh
  """
  def apply_node_scope(table) do
    case Store.get_table_meta(table) do
      {:ok, %{node_scope: :local}} ->
        # Remove any existing replicas
        remove_all_replicas(table)

      {:ok, %{node_scope: :all}} ->
        # Replicate to all mesh nodes
        for node <- Mesh.connected_nodes() do
          setup_replication(table, node)
        end

      {:ok, %{node_scope: nodes}} when is_list(nodes) ->
        # Replicate to specific nodes, remove from others
        for node <- Mesh.connected_nodes() do
          if node in nodes do
            setup_replication(table, node)
          else
            remove_replica(table, node)
          end
        end
    end
  end

  def setup_replication(table, target_node) do
    :mnesia.add_table_copy(table, target_node, :disc_copies)
  end

  def remove_replica(table, node) do
    :mnesia.del_table_copy(table, node)
  end

  @doc """
  Called when a new node joins the mesh.
  Replicates all tables where node_scope includes the new node.
  """
  def on_node_join(new_node) do
    for table <- Store.all_tables() do
      case Store.get_table_meta(table) do
        {:ok, %{node_scope: :all}} ->
          setup_replication(table, new_node)

        {:ok, %{node_scope: nodes}} when is_list(nodes) ->
          if new_node in nodes, do: setup_replication(table, new_node)

        _ ->
          :ok
      end
    end
  end
end
```

**Replication strategy:** Async multi-master with last-write-wins conflict resolution.

**Public table replication:** Tables with `node_scope: :all` and world-readable ACLs (`* → [:read]`) are automatically replicated to all nodes, enabling shared knowledge bases accessible from anywhere in the mesh.

#### 8. Node Discovery

Static configuration for v2 (simple and predictable):

```elixir
# config/runtime.exs
config :cortex, :mesh,
  nodes: [
    {"cortex-node-a", "192.168.1.10", 4711},
    {"cortex-node-b", "192.168.1.11", 4711},
    {"cortex-node-c", "home.example.com", 4711}
  ],
  ca_cert: "/etc/cortex/ca.crt",
  node_cert: "/etc/cortex/node.crt",
  node_key: "/etc/cortex/node.key"
```

Future: Add gossip-based discovery or DNS SRV records.

### CLI Extensions

```bash
# Certificate management
cortex mesh init-ca                    # Create new CA
cortex mesh add-node <name> <host>     # Generate node cert
cortex mesh list-nodes                 # Show mesh topology
cortex mesh status                     # Show connectivity to all nodes

# Identity management
cortex identity register <name>        # Create federated ID
cortex identity claim <token>          # Link local UID to federated ID
cortex identity list                   # Show identity mappings
cortex identity revoke <name> [node]   # Remove mapping

# Table creation with node scope
cortex create <table> <fields...> [--scope <scope>]
# --scope local         Only on this node
# --scope all           Replicate to all nodes (default for @tables)
# --scope node1,node2   Specific nodes only

# Node scope management
cortex scope <table>                   # Show current node scope
cortex scope <table> local             # Restrict to local only
cortex scope <table> all               # Replicate everywhere
cortex scope <table> node1,node2       # Specific nodes

# Table info (shows both ACLs and node scope)
cortex info <table>
# → owner: alice
# → node_scope: ["home", "office"]
# → replicas: [home (primary), office (synced)]
# → acl:
# →   alice: [read, write, admin]
# →   *: [read]

# Sync management
cortex sync status                     # Show replication status across mesh
cortex sync status <table>             # Show replication for specific table
cortex sync repair <table>             # Force re-sync if inconsistent
```

## Consequences

### Positive

- **Strong security**: mTLS provides cryptographic node identity, no shared secrets
- **Backward compatible**: Local Unix socket auth unchanged
- **User-friendly**: Agents don't manage credentials; UID is identity
- **Flexible**: Users control which nodes have their data via identity claims
- **Auditable**: Federation registry shows exactly who can access what where

### Negative

- **Certificate management**: Need tooling for cert generation, distribution, rotation
- **Complexity**: Three identity layers (node, local, federated) adds cognitive load
- **Eventual consistency**: Async replication means temporary inconsistency
- **Bootstrap chicken-egg**: First node setup requires manual CA creation

### Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| CA key compromise | Low | Critical | Document secure storage, consider HSM for production |
| Stale identity mappings | Medium | Low | Add TTL/refresh mechanism, admin revocation |
| Replication conflicts | Medium | Medium | Last-write-wins with vector clocks for debugging |
| Network partition | Medium | Medium | Nodes function independently, reconcile on reconnect |

## Implementation Plan

### Phase 1: mTLS Infrastructure
- [ ] Add TCP+TLS listener alongside Unix socket
- [ ] Implement certificate verification
- [ ] Extract node identity from peer certificate
- [ ] CLI: `cortex mesh init-ca`, `cortex mesh add-node`

### Phase 2: Federated Identity
- [ ] Create `cortex_identities` system table
- [ ] Implement identity registration and claim flow
- [ ] Update ACL checks to resolve federated identity
- [ ] CLI: `cortex identity register/claim/list`

### Phase 3: Node Scope & Access Control
- [ ] Extend `cortex_meta` schema with `node_scope` field
- [ ] Implement `check_node_scope/2` authorization check
- [ ] Add `--scope` flag to `cortex create`
- [ ] CLI: `cortex scope <table> <scope>`
- [ ] CLI: `cortex info <table>` (show ACLs + node scope)

### Phase 4: Data Replication
- [ ] Configure Mnesia clustering with Erlang distribution
- [ ] Implement `@federated:table` namespace
- [ ] Implement `Cortex.Sync.apply_node_scope/1`
- [ ] Handle node join/leave events
- [ ] CLI: `cortex sync status/repair`

### Phase 5: Operational Tooling
- [ ] Certificate rotation tooling
- [ ] Monitoring and health checks
- [ ] Backup/restore across mesh
- [ ] Documentation and runbooks

## References

- [Erlang SSL Module](https://www.erlang.org/doc/man/ssl.html)
- [Mnesia Clustering](https://www.erlang.org/doc/man/mnesia.html)
- [mTLS Explained](https://www.cloudflare.com/learning/access-management/what-is-mutual-tls/)
- [SPIFFE/SPIRE](https://spiffe.io/) (future consideration for dynamic cert issuance)
