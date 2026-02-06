## 1. mTLS Infrastructure

- [x] 1.1 Add `:ssl` and `:public_key` to `extra_applications` in mix.exs
- [x] 1.2 Add mesh configuration schema to `config/config.exs` (nodes list, cert paths, TLS port)
- [x] 1.3 Create `Cortex.TLSServer` GenServer — TLS listen socket, accept loop, spawns handlers into existing `HandlerSupervisor` with `transport: :tls` tag
- [x] 1.4 Add `Cortex.TLSServer` to supervision tree in `Application` (after Store, conditional on mesh config being present)
- [x] 1.5 Implement `cortex mesh init-ca` CLI command — generates CA key + self-signed cert using openssl
- [x] 1.6 Implement `cortex mesh add-node <name> <host>` CLI command — generates node key, CSR, signs with CA, sets CN and SAN
- [x] 1.7 Implement `cortex mesh list-nodes` CLI command — reads mesh config, displays node list
- [x] 1.8 Implement `cortex mesh status` CLI command — shows each peer's connectivity status
- [x] 1.9 Write tests for TLS listener: accepts mTLS connections, rejects no-cert, rejects wrong-CA

## 2. Handler Transport Abstraction

- [x] 2.1 Add `:transport` and `:node_id` fields to `Handler` struct
- [x] 2.2 Update `Cortex.Server` to pass `transport: :unix` when spawning handlers
- [x] 2.3 Update `Cortex.TLSServer` to pass `transport: :tls` when spawning handlers
- [x] 2.4 Branch `handle_info(:start, ...)` on transport — Unix path uses `Identity.get_uid/1`, TLS path uses `Identity.get_node_cn/1`
- [x] 2.5 Implement `Identity.get_node_cn/1` — extract CN from peer certificate via `:ssl.peercert/1` and `:public_key` decoding
- [x] 2.6 Update handler to handle `:ssl` messages (`:ssl, socket, data` / `:ssl_closed` / `:ssl_error`) alongside existing `:tcp` messages
- [x] 2.7 Write tests for handler accepting both transport types with correct identity resolution

## 3. Federated Identity

- [x] 3.1 Create `cortex_identities` system table in `Store.setup_mnesia/0` — schema: `{fed_id, mappings, metadata}`
- [x] 3.2 Add `Store` functions: `register_identity/3`, `claim_identity/3`, `lookup_federated/2`, `lookup_federated_by_local/2`, `list_identities/0`, `revoke_identity/2`
- [x] 3.3 Implement claim token generation — sign payload (fed_id, origin node, origin UID, timestamps) with node's TLS private key using `:public_key`
- [x] 3.4 Implement claim token verification — verify signature using origin node's certificate
- [x] 3.5 Add RPC methods in handler: `identity_register`, `identity_claim`, `identity_list`, `identity_revoke`
- [x] 3.6 Implement CLI commands: `cortex identity register <name>`, `cortex identity claim <token>`, `cortex identity list`, `cortex identity revoke <name> [node]`
- [x] 3.7 Write tests for identity registration, claiming, lookup, and revocation

## 4. Federated Table Namespace

- [x] 4.1 Update `Store.resolve_table/2` to handle `@` prefix — resolve `@name` to `@{fed_id}:name` using caller's federated identity, resolve `@owner:name` directly
- [x] 4.2 Update `Store.create_table/3` to support federated namespace — `@{fed_id}:{name}` atom creation with `:all` default node scope
- [x] 4.3 Update `Store.tables/1` to include federated tables owned by the caller's federated identity
- [x] 4.4 Update `Identity` module with `resolve_federated/2` — given a (node, uid) pair, return federated ID or nil
- [x] 4.5 Update handler dispatch to resolve federated identity for remote requests before passing to ACL
- [x] 4.6 Write tests for federated table creation, resolution, and cross-namespace access

## 5. Node Scope

- [x] 5.1 Extend `cortex_meta` schema to 6 elements — add `node_scope` field (`:local`, `:all`, or node name list)
- [x] 5.2 Add backward-compatible read in `Store.get_table_meta/1` — detect 5-element records, treat as `node_scope: :local`
- [x] 5.3 Update `Store.create_table/3` to accept and store `node_scope` option (default `:local` for UID tables, `:all` for `@` tables)
- [x] 5.4 Add `Store.set_node_scope/2` for changing a table's node scope after creation
- [x] 5.5 Implement `ACL.check_node_scope/2` — check requesting node against table's node scope, local requests always pass
- [x] 5.6 Update `ACL.authorize/3` to call `check_node_scope/2` before identity ACL check (both must pass)
- [x] 5.7 Add `--scope` flag to `cortex create` CLI command
- [x] 5.8 Implement CLI commands: `cortex scope <table>`, `cortex scope <table> <scope>`, `cortex info <table>`
- [x] 5.9 Write tests for node scope enforcement, migration of old records, scope changes

## 6. Erlang Distribution over TLS

- [x] 6.1 Configure Erlang distribution to use TLS — create `inet_tls.conf` generator with mesh CA/cert/key
- [x] 6.2 Set up `vm.args` or runtime config for `-proto_dist inet_tls` with fixed port (configurable, default 4712)
- [x] 6.3 Implement mesh node connection on startup — connect to peer Erlang nodes listed in mesh config
- [x] 6.4 Handle node up/down events via `:net_kernel.monitor_nodes/1`
- [x] 6.5 Write tests for Erlang distribution TLS setup and node connectivity

## 7. Data Replication

- [x] 7.1 Create `Cortex.Sync` module — manages Mnesia table replication based on node scope
- [x] 7.2 Implement `Sync.apply_node_scope/1` — add/remove `disc_copies` on nodes to match table's node_scope
- [x] 7.3 Implement `Sync.on_node_join/1` — replicate appropriate tables when a new node connects
- [x] 7.4 Implement `Sync.on_node_leave/1` — handle cleanup when a node disconnects
- [x] 7.5 Ensure system tables (`cortex_identities`, `cortex_acls`, `cortex_meta`) replicate to all mesh nodes on setup
- [x] 7.6 Trigger `Sync.apply_node_scope/1` when node scope changes (hook into `Store.set_node_scope/2`)
- [x] 7.7 Implement CLI commands: `cortex sync status`, `cortex sync status <table>`, `cortex sync repair <table>`
- [x] 7.8 Write tests for replication setup, scope-driven replica management, node join/leave handling

## 8. Integration Testing

- [x] 8.1 Set up multi-node test infrastructure — helper to start 2-3 cortexd nodes with mTLS in test environment
- [x] 8.2 Test end-to-end: register identity on node-a, claim on node-b, create federated table, read from both nodes
- [x] 8.3 Test node scope enforcement: local table inaccessible from remote, :all table accessible everywhere
- [x] 8.4 Test replication: put on node-a, read on node-b after sync
- [x] 8.5 Test partition resilience: disconnect nodes, verify local ops continue, reconnect and verify reconciliation
