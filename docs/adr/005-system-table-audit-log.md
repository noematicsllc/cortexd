# ADR-005: System Table Audit Log

## Status

Proposed

## Context

Cortex system tables (`cortex_acls`, `cortex_identities`, `cortex_meta`) control access, identity, and table configuration across the mesh. Changes to these tables replicate to all core nodes via Mnesia.

Currently, writes to system tables leave no trace. If an operator grants world-write on a private table, revokes a federated identity, or changes a table's node scope, there is no record of:

- What changed
- When it changed
- Which node originated the change
- Which local user initiated it
- What the previous value was

This means:

1. **No forensics.** After an incident (rogue operator, compromised node caught by attestation), there's no way to determine what was modified.
2. **No rollback.** Without knowing the previous state, restoring correct ACLs or identities requires manual reconstruction or a full backup restore.
3. **No detection.** Subtle changes (e.g., adding a permissive ACL entry) may go unnoticed because nothing surfaces them.

ADR-004 limits Mnesia write access to 2-10 trusted core nodes, making the risk manageable. But "manageable" is not "auditable."

## Decision

Add an append-only audit log for all writes to system tables. The log records what changed, when, where, and by whom, enabling forensics and rollback.

### What Gets Logged

Every write to a system table produces an audit entry:

| Operation | Table | Example |
|---|---|---|
| `acl_grant` | `cortex_acls` | Grant read access on table X to UID Y |
| `acl_revoke` | `cortex_acls` | Revoke access |
| `identity_register` | `cortex_identities` | Register federated identity |
| `identity_claim` | `cortex_identities` | Claim identity on a node |
| `identity_revoke` | `cortex_identities` | Revoke identity |
| `create_table` | `cortex_meta` | New table metadata |
| `drop_table` | `cortex_meta` | Table removal |
| `set_node_scope` | `cortex_meta` | Change replication scope |

### Audit Entry Schema

```
{cortex_audit, id, timestamp, node, uid, operation, table, key, old_value, new_value}
```

| Field | Type | Description |
|---|---|---|
| `id` | integer | Monotonic ID (unique per node, ordered) |
| `timestamp` | integer | `:erlang.system_time(:millisecond)` |
| `node` | string | Originating core node CN |
| `uid` | integer or nil | Local UID that initiated the change (nil if via replication or system) |
| `operation` | atom | `:acl_grant`, `:acl_revoke`, `:identity_register`, etc. |
| `table` | atom | Which system table was modified |
| `key` | term | The record key that changed |
| `old_value` | term or nil | Previous record (nil for creates) |
| `new_value` | term or nil | New record (nil for deletes) |

### Storage

The `cortex_audit` table is a Mnesia table with:
- `disc_copies` on all core nodes (survives restarts)
- `node_scope: :all` (replicates across the core cluster)
- Append-only by convention — the application never updates or deletes audit entries
- Ordered by `{timestamp, node, id}` for consistent cross-node ordering

### Implementation

Audit entries are written inside the same Mnesia transaction as the change they record. This ensures atomicity — if the change commits, the audit entry commits. If the transaction aborts, neither is written.

```elixir
def acl_grant(table, grantee, permission, uid, node) do
  :mnesia.transaction(fn ->
    old = :mnesia.read(:cortex_acls, {table, grantee})
    # ... apply the grant ...
    write_audit(:acl_grant, :cortex_acls, {table, grantee}, old, new, uid, node)
  end)
end
```

### Retention

Audit entries accumulate indefinitely by default. A future `cortex audit prune --before <date>` command can remove old entries. No automatic pruning — the operator decides what history to keep.

### What This Does Not Provide

**Tamper-proofing.** The audit log is a regular Mnesia table. A rogue core node can write to both the system table and the audit log simultaneously — deleting or modifying audit entries to cover tracks. This is an accepted limitation for the core cluster trust model (ADR-004). The audit log protects against mistakes and enables forensics for detected incidents. It does not protect against a sophisticated attacker with sustained Mnesia write access.

**Real-time alerting.** The audit log is passive. Detection requires something reading the log — a periodic scan, an operator running `cortex audit list`, or a Mnesia subscription-based monitor. Building an alerting system is out of scope.

**Non-repudiation.** Entries are not cryptographically signed. A node claims it wrote an entry, but there's no proof. Signed entries (each node signs its audit entries with its TLS private key) would provide non-repudiation but add complexity. This can be added later if needed without changing the schema — the `new_value` field could hold a signed envelope.

## Consequences

- **Positive**: Every system table change is recorded with full context (who, what, when, where, before/after)
- **Positive**: Enables rollback — `old_value` contains the previous state for any change
- **Positive**: Enables forensics — after an incident, the audit log shows exactly what was modified
- **Positive**: Atomic with the change — no window where a change exists without its audit entry
- **Positive**: Simple implementation — one additional Mnesia write per system table operation
- **Negative**: Storage growth — audit entries accumulate (mitigated by manual pruning)
- **Negative**: Not tamper-proof — accepted trade-off for core cluster trust model
- **Negative**: Slight write amplification — every system table write becomes two Mnesia writes (data + audit)
