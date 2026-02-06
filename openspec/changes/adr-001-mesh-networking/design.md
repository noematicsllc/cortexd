## Context

Cortex v1 is a single-node storage daemon. All connections arrive over a Unix domain socket, identity is a UID integer extracted via `SO_PEERCRED`, tables are namespaced as `{uid}:{name}` atoms, and ACLs map `uid:{n}` identity strings to permission lists. The handler, server, identity, ACL, and store modules all assume this single-node, UID-only model.

ADR-001 expands cortexd to a mesh of 2-10 nodes. The design must preserve local Unix socket behavior unchanged while adding TCP+mTLS for inter-node communication, a way to link UIDs across machines, node-level data scoping, and Mnesia-based replication.

### Current module responsibilities

| Module | Does today | Must change |
|--------|-----------|-------------|
| `Server` | Listens on Unix socket, spawns handlers | Add a second TLS listener |
| `Handler` | Per-connection GenServer, dispatches RPC | Accept connections from either transport, resolve identity differently per transport |
| `Identity` | Extracts UID from socket via peercred NIF | Add TLS path: extract CN from peer cert, resolve to federated identity |
| `ACL` | Checks `uid:{n}` against permission table | Add node scope check as second authorization gate; accept federated identity strings |
| `Store` | Mnesia CRUD, `{uid}:{name}` namespacing | Extend `cortex_meta` with `node_scope`, add `cortex_identities` table, support `@{fed_id}:{name}` namespace |
| `Application` | Supervision tree: Store → HandlerSupervisor → Server | Add TLS server, mesh manager |

## Goals / Non-Goals

**Goals:**
- Nodes authenticate each other cryptographically (mTLS) — no shared secrets
- Users link their identity across nodes once; it works everywhere automatically after that
- Table owners control where their data exists (local only, all nodes, or specific nodes)
- Data replicates automatically based on node scope — no manual sync commands
- Local Unix socket access is completely unchanged (backward compatible)
- The system works on a small mesh (2-10 nodes) without complex coordination

**Non-Goals:**
- Dynamic node discovery (static config for now; gossip/DNS-SRV is future work)
- Conflict resolution beyond last-write-wins (CRDTs, vector clocks are future work)
- Remote CLI access (CLI always talks to local cortexd; mesh handles the rest)
- Certificate auto-rotation (provide tooling to generate/rotate; automation is future work)
- Cross-mesh federation (a mesh is one trust domain with one CA)

## Decisions

### 1. Two listeners, one handler pool

**Decision:** Run a `Cortex.TLSServer` alongside `Cortex.Server`, both spawning handlers into the same `HandlerSupervisor`.

**Why:** Handlers already manage per-connection state. The only difference is how identity is resolved at connection start. By tagging handler state with transport type (`:unix` or `:tls`), the same dispatch logic works for both.

**Alternative considered:** Separate handler modules for Unix vs TLS. Rejected — 95% of handler code (dispatch, buffer management, protocol) is identical. A transport tag on the state struct avoids duplicating all of it.

**Shape:**
```elixir
# Handler state gains a transport field
defstruct [:socket, :uid, :transport, :node_id, :buffer]

# Identity resolution branches on transport
def handle_info(:start, %{transport: :unix} = state) do
  {:ok, uid} = Identity.get_uid(state.socket)
  {:noreply, %{state | uid: uid}}
end

def handle_info(:start, %{transport: :tls} = state) do
  {:ok, cn} = Identity.get_node_cn(state.socket)
  {:noreply, %{state | node_id: cn}}
end
```

### 2. Federated identity as a system table

**Decision:** Store identity mappings in `cortex_identities`, a Mnesia system table replicated to all nodes.

**Schema:** `{:cortex_identities, fed_id, mappings, metadata}` where `mappings` is `%{"node-a" => 1000, "node-b" => 1001}`.

**Why:** Identity data must be available on every node for authorization to work without cross-node calls. Mnesia replication gives us this automatically. Storing it as a system table (like `cortex_acls`) means it uses the same infrastructure — no new storage mechanism.

**Alternative considered:** External identity store (etcd, consul). Rejected — adds an operational dependency for a simple lookup table.

### 3. Two namespace schemes

**Decision:** Keep `{uid}:{name}` for local tables. Add `@{fed_id}:{name}` for federated tables.

**Why:** Local tables must keep working unchanged. Federated tables need a different namespace because the same federated identity may map to different UIDs on different nodes. The `@` prefix is unambiguous — it can't collide with UID-prefixed names (UIDs are numeric).

**Resolution logic:**
- `cortex put memories ...` → resolves to `{uid}:memories` (local, same as today)
- `cortex put @memories ...` → resolves to `@{fed_id}:memories` (requires federated identity)
- `cortex put @alice:memories ...` → resolves to `@alice:memories` (explicit federated owner)

### 4. Node scope as table metadata, not ACL

**Decision:** Add `node_scope` to `cortex_meta` as a separate field, not as part of the ACL system.

**Why per prior decision (decision-node-scope):** These are two independent concerns: *who can access* (identity ACL) vs *where data can exist* (node scope). Mixing them in the ACL table would conflate authorization with replication topology. Both checks must pass, but they're evaluated independently.

**Schema change:** `cortex_meta` gains a 6th element:
```elixir
# Before: {:cortex_meta, table_name, owner, key_field, attributes}
# After:  {:cortex_meta, table_name, owner, key_field, attributes, node_scope}
```

**Migration:** On startup, if existing `cortex_meta` records have 5 elements, backfill with `node_scope: :local`. This preserves existing behavior — no table suddenly starts replicating.

### 5. Mnesia clustering for replication

**Decision:** Use Mnesia's built-in multi-node replication (`add_table_copy/3`) driven by each table's `node_scope`.

**Why:** Mnesia already supports multi-master replication with automatic conflict resolution. Since cortexd already uses Mnesia, this avoids adding a separate replication layer. The `node_scope` field drives which nodes get copies via `add_table_copy/del_table_copy`.

**Alternative considered:** Custom replication over the mTLS connections (forwarding RPC writes). Rejected — reimplements what Mnesia already does, and loses transaction guarantees.

**Trade-off:** This means Erlang distribution must run between nodes, not just our TLS connections. We configure Erlang distribution to use TLS with the same certificates, so the security model is consistent. The mTLS RPC listener handles client-facing requests; Erlang distribution handles Mnesia sync.

### 6. Claim token for identity linking

**Decision:** Use a short-lived JWT-like token signed by the origin node's private key to link identities across nodes.

**Flow:**
1. On node-a: `cortex identity register alice` → creates federated identity, outputs claim token
2. On node-b: `cortex identity claim <token>` → node-b verifies signature by contacting node-a over mTLS, adds local UID mapping

**Why:** The user needs a way to prove on node-b that they own the identity created on node-a. A token signed by node-a's key provides this proof. Verification happens over the mTLS channel (already authenticated), so the token itself doesn't need to be a secret — it just needs to be unforgeable.

**Alternative considered:** Direct node-to-node identity linking via admin command. Rejected — requires the user to have admin access on both nodes simultaneously. Tokens work asynchronously.

### 7. Authorization flow for remote requests

**Decision:** Remote requests carry the requesting node's identity. The receiving node resolves the node CN to a federated identity (if registered) and runs both identity ACL and node scope checks.

```
Remote request arrives →
  Extract node CN from TLS cert →
  Look up federated identity for (requesting_node, request_uid) →
  check_node_scope(table, requesting_node) →
  check_identity_acl(federated_identity, table, operation) →
  Execute or deny
```

**Key point:** Remote requests include the originating UID alongside the node CN. The receiving node trusts this because the connection is mTLS-authenticated — node-a wouldn't lie about which local user made the request. This is the network equivalent of trusting `SO_PEERCRED`.

## Risks / Trade-offs

**Erlang distribution as a dependency** → Mnesia replication requires Erlang distribution between nodes. This is a second network channel alongside our mTLS RPC listener. Mitigation: Configure Erlang distribution to use TLS with the same CA/certs, so security is consistent. Document clearly that the Erlang distribution port must also be accessible between nodes.

**Atom exhaustion with federated namespaces** → Federated table names (`@alice:memories`) become atoms. With many federated users, this could grow. Mitigation: Same `String.to_existing_atom` guard already in place for table resolution. New tables must go through `create_table` which controls atom creation.

**`cortex_meta` schema migration** → Adding a field to `cortex_meta` is a breaking change to the Mnesia record format. Mitigation: Detect 5-element records on read and treat missing 6th field as `:local`. Write always uses 6-element format. No destructive migration needed.

**Last-write-wins data loss** → Concurrent writes to the same key on different nodes will lose one write. Mitigation: Acceptable for v2 target use cases (agent data, config). Document the limitation. Add vector clock support in a future version for conflict detection.

**Certificate management burden** → Users must generate a CA, issue node certs, and distribute them. Mitigation: Provide `cortex mesh init-ca` and `cortex mesh add-node` commands that handle the openssl invocations. For a 2-10 node mesh this is a one-time setup.

**Trust model for remote UID claims** → When node-a says "this request is from UID 1000," node-b trusts it because the mTLS connection authenticates node-a. If node-a is compromised, it could impersonate any local user. Mitigation: Same trust model as Erlang distribution cookies, but with stronger authentication (mTLS vs shared secret). Node compromise is a high-impact event regardless.

## Open Questions

- **Erlang distribution port:** Should we use a fixed port (e.g., 4712) or let it be dynamic? Fixed is simpler for firewall rules.
- **Token format:** Full JWT with a library dependency, or a simpler `base64({payload}|{signature})` with `:crypto` directly? The token is short-lived and single-purpose.
- **System table replication timing:** Should `cortex_identities` and `cortex_meta` replicate eagerly (synchronous) while user tables replicate lazily (async)? This would ensure identity/scope changes propagate before data operations depend on them.
