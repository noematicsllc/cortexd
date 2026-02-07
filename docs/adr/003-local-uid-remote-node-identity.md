# ADR-003: Local UID, Remote Node Identity

## Status

Proposed

## Context

ADR-001 introduced a 5-element RPC protocol extension for TLS connections:

```
[0, msgid, method, params, %{"uid" => remote_uid}]
```

This allows a remote node to claim it is acting on behalf of a specific UID. The receiving node extracts the UID from the metadata, optionally resolves it to a federated identity, and uses it for ACL checks.

This design has inherent security problems:

1. **UID spoofing**: A remote node can claim any UID, including UID 0 (root), which bypasses all ACL checks. The receiving node must trust the claim. Even with code attestation (ADR-002), a compromised node can lie about who is making a request.

2. **Root escalation across the mesh**: UID 0 bypasses all ACLs by design (appropriate locally — root already has disk access to Mnesia files). But with remote UID claims, root on any single node becomes root on every node. Compromising one machine's root grants mesh-wide god-mode access.

3. **Trust inversion**: Unix socket auth is kernel-enforced (peercred cannot be spoofed). The 5-element RPC replaces this with an honor system over TLS — a strictly weaker guarantee that contradicts the project's security-first principle.

Meanwhile, agents don't need to talk directly to remote cortexd instances. They connect to their local cortexd via Unix socket and get cross-node data through Mnesia replication. The TLS mesh exists for node-to-node infrastructure, not end-user access.

## Decision

**Remote connections identify as nodes, not users.** The 5-element RPC protocol extension is removed.

### Identity Model

| Connection | Identity source | Identity type | Scope |
|---|---|---|---|
| Unix socket | `SO_PEERCRED` (kernel) | UID (integer) | Local machine only |
| TLS mesh | mTLS certificate CN | Node name (string) | Mesh infrastructure |
| Federated | Identity registry (Mnesia) | Federated ID (string) | Cross-node, via replication |

### How Cross-Node Access Works

An agent on node-b wants to read `@alice:memories`:

1. Agent connects to **local** cortexd on node-b via Unix socket (peercred: uid 1001)
2. cortexd resolves uid 1001 on node-b → federated identity "alice"
3. cortexd reads `@alice:memories` from local Mnesia replica
4. Data was replicated to node-b via Erlang distribution (because `node_scope: :all`)

The agent never talks to node-a's cortexd. The TLS mesh handles replication transparently.

### What TLS Connections Are For

The TLS mesh is node-to-node infrastructure only:

- **Mnesia replication** — Erlang distribution over TLS (ADR-001 task 6)
- **Identity operations** — `identity_register`, `identity_claim`, `identity_revoke`
- **Sync operations** — `sync_status`, `sync_repair`
- **Attestation** — code verification via safe RPC calls (ADR-002)

TLS connections authenticate as their node CN. The `requesting_node` parameter remains for node scope enforcement. There is no remote UID.

### What This Removes

- 5-element RPC protocol (`[0, msgid, method, params, metadata]`)
- `extract_remote_uid/1` in handler
- `resolve_remote_identity/2` in handler
- Remote UID metadata handling in `handle_message`
- Anti-spoofing check (Unix socket + 5-element rejection) — no longer needed since the protocol doesn't exist

### Root Access Scoping

| Before | After |
|---|---|
| UID 0 on any node can claim root via 5-element RPC | UID 0 is scoped to the local machine |
| Root on node-a = root on node-b | Root on node-a has no special access to node-b |
| One compromised root = mesh-wide compromise | One compromised root = one machine compromised |

Root retaining full local access is appropriate — they already have OS-level access to Mnesia data files on that machine. The change ensures this power doesn't extend across the network.

## Consequences

- **Positive**: Eliminates UID spoofing by design (the protocol can't express it)
- **Positive**: Root access scoped to local machine — one compromised node doesn't escalate to mesh-wide root
- **Positive**: Simpler handler — no metadata parsing, no remote UID validation, no identity resolution for remote requests
- **Positive**: Security model is consistent — all user identity is kernel-enforced (peercred), never claimed over the network
- **Positive**: Cleaner separation of concerns — UIDs are local, nodes are remote, federated identity bridges the two via Mnesia
- **Negative**: A TLS-connected admin tool can't act as a specific user — must go through the local Unix socket on the target machine
- **Negative**: Removes code that was just implemented (ADR-001 tasks 2.7, 4.5, 9.1 partially) — necessary churn for a better security model
