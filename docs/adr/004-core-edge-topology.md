# ADR-004: Core-Edge Node Topology

## Status

Proposed

## Context

ADR-001 designed the mesh as a flat cluster of fully connected nodes, each running cortexd with Mnesia replication over Erlang distribution. This works well for a small number of nodes (2-10) but creates scaling pressure at higher counts:

- Erlang distribution creates a full mesh of TCP connections (100 nodes = ~5,000 connections)
- Mnesia replication to all nodes is expensive and unnecessary when most only need read access
- Certificate revocation via allowlist is manageable for a small cluster but not for 100+ dynamic nodes
- The security surface grows with every node that joins the Erlang cluster (ADR-002 mitigates RCE, but Mnesia data poisoning remains a risk per connected node)

Meanwhile, many participants don't need the full scope of cortexd. They need authenticated access to specific tables — reading announcements, receiving alerts, reporting status — over a channel that isn't the open internet. Running a full cortexd instance with Mnesia, Erlang distribution, and local storage is unnecessary overhead for these use cases.

## Decision

Introduce two node roles that share the same mTLS certificate infrastructure but differ in capability and trust level.

### Core Nodes

A small, stable cluster (2-10 nodes) that runs full cortexd:

- Participates in Erlang distribution over TLS (ADR-001 task 6)
- Full Mnesia replication based on node scope
- Distribution message filter active (ADR-002)
- Code attestation (ADR-002)
- Local Unix socket access with UID-based auth
- Allowlisted by CN — only known core nodes can join the Erlang cluster

Core nodes are the source of truth. They are individually administered machines whose operators know each other.

### Edge Nodes

Lightweight clients (potentially 100+) that connect via the TLS handler:

- Authenticate via mTLS (cert signed by the mesh CA)
- Connect to one or more core nodes over the existing TLS handler (MessagePack-RPC)
- No Erlang distribution, no Mnesia participation
- Access restricted to explicitly granted tables
- Identified by their certificate CN, same as any TLS connection (ADR-003)

Edge nodes do not run cortexd. They are any process that can speak MessagePack-RPC over TLS — the existing `cortex` CLI, a script, a service in any language.

### Access Model

| | Core node | Edge node |
|---|---|---|
| Identity | mTLS CN, allowlisted | mTLS CN |
| Erlang cluster | Yes | No |
| Mnesia replication | Yes (per node scope) | No |
| Local Unix socket | Yes | No |
| Table read | All (per ACL + node scope) | Granted tables only |
| Table write | All (per ACL + node scope) | Granted tables only |
| Data path | Local Mnesia replica | RPC to core node |

### Edge Grants

Edge node access is controlled by per-node grants on specific tables. A grant specifies:

- **Node CN** (or pattern): which edge node(s)
- **Table**: which table
- **Permission**: `read` or `read_write`

This extends the existing `node_scope` concept. A table with `node_scope: :all` is accessible to all core nodes via replication. Edge grants add a second layer: which edge nodes can query that table through the TLS handler.

Grants are stored in a system Mnesia table on core nodes, replicated across the core cluster.

### Certificate Management

| | Core nodes | Edge nodes |
|---|---|---|
| Issued by | Mesh CA | Mesh CA |
| Lifetime | Long-lived | Short-lived (hours/days) or long-lived |
| Revocation | Allowlist update (rare, manual) | Non-renewal or revocation list |
| Scale | 2-10, static | 100+, dynamic |

For edge nodes at scale, short-lived certificates are preferred. An edge node requests a cert from a core node (which acts as a CA endpoint), receives a cert valid for N hours, and renews before expiry. Revocation becomes non-renewal — stop issuing certs to a compromised node, and it drops off when the current cert expires.

### What Cortex Provides

Cortex remains infrastructure, not application:

- Authenticated access to tables over TLS
- Table semantics: create, read, write, match, delete
- mTLS as the sole authentication mechanism
- No push notifications, no subscriptions, no delivery guarantees beyond "the data is in the table"

What the data means, how often clients poll, and what they do with the results is outside cortex's scope. Announcements, alerts, coordination, config distribution — these are usage patterns, not features.

### What This Does Not Include

- **Push/subscription mechanism** — clients poll or use their own notification layer
- **Client SDK** — the protocol is MessagePack-RPC over TLS, any language can implement it
- **Automatic failover** — if a core node goes down, edge nodes reconnect to another core node (client responsibility)
- **Edge-to-edge communication** — edge nodes talk to core nodes, not to each other

## Consequences

- **Positive**: Scales to 100+ participants without scaling Erlang distribution or Mnesia
- **Positive**: Minimal blast radius for edge node compromise — limited to granted table reads, no Mnesia poisoning, no cluster access
- **Positive**: Simplifies certificate revocation — core nodes use a small allowlist, edge nodes use short-lived certs
- **Positive**: Low barrier to entry — an edge client is any TLS + msgpack implementation, no cortexd required
- **Positive**: Stays infrastructure — table access over authenticated TLS, no application-level features
- **Negative**: Two-tier model adds conceptual complexity (node role, edge grants, different cert lifetimes)
- **Negative**: Edge nodes depend on core node availability for data access (no local replica)
- **Negative**: Grant management at scale needs tooling (`cortex mesh grant <node> <table> <perm>`)
