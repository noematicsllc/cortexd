## ADDED Requirements

### Requirement: Mnesia clustering over TLS
The system SHALL configure Erlang distribution to use TLS with the same CA and certificates used for the mTLS RPC listener. Mnesia replication SHALL operate over this encrypted channel.

#### Scenario: Erlang distribution uses mesh certificates
- **WHEN** cortexd starts with mesh configuration
- **THEN** Erlang distribution SHALL be configured to use TLS with the mesh CA certificate, node certificate, and node private key

#### Scenario: Mnesia connects to peer nodes
- **WHEN** cortexd starts and peer nodes are reachable
- **THEN** Mnesia SHALL establish connections to peer nodes for replication

### Requirement: Replication driven by node scope
The system SHALL add or remove Mnesia table copies on nodes based on each table's `node_scope` value.

#### Scenario: Table with scope :all replicates everywhere
- **WHEN** a table has `node_scope: :all`
- **THEN** the system SHALL ensure a `disc_copies` replica exists on every connected mesh node

#### Scenario: Table with scope :local has no replicas
- **WHEN** a table has `node_scope: :local`
- **THEN** the system SHALL NOT create replicas on any other node

#### Scenario: Table with specific node list replicates to listed nodes
- **WHEN** a table has `node_scope: ["home", "office"]`
- **THEN** the system SHALL ensure replicas exist on nodes "home" and "office"
- **AND** remove replicas from any other nodes

#### Scenario: Scope change triggers replication update
- **WHEN** a table's `node_scope` is changed (e.g., from `:local` to `:all`)
- **THEN** the system SHALL add or remove replicas to match the new scope

### Requirement: Node join handling
The system SHALL set up appropriate table replicas when a new node joins the mesh.

#### Scenario: New node receives replicas for :all tables
- **WHEN** a new node joins the mesh
- **THEN** all tables with `node_scope: :all` SHALL be replicated to the new node

#### Scenario: New node receives replicas for tables listing it
- **WHEN** a new node named "office" joins the mesh
- **AND** a table has `node_scope: ["home", "office"]`
- **THEN** that table SHALL be replicated to the new node

#### Scenario: New node does not receive :local tables
- **WHEN** a new node joins the mesh
- **THEN** tables with `node_scope: :local` SHALL NOT be replicated to it

### Requirement: System table replication
The `cortex_identities`, `cortex_acls`, and `cortex_meta` system tables SHALL be replicated to all mesh nodes so that identity resolution and authorization work locally on every node.

#### Scenario: System tables replicate on mesh setup
- **WHEN** mesh networking is configured and nodes connect
- **THEN** `cortex_identities`, `cortex_acls`, and `cortex_meta` SHALL have copies on all nodes

#### Scenario: ACL changes propagate across mesh
- **WHEN** an ACL is granted on node-a
- **THEN** the ACL change SHALL be visible on all other mesh nodes after replication

### Requirement: Conflict resolution
Data conflicts from concurrent writes on different nodes SHALL be resolved using last-write-wins semantics.

#### Scenario: Concurrent writes to same key
- **WHEN** two nodes write different values to the same key in the same table concurrently
- **THEN** Mnesia's built-in conflict resolution SHALL pick one value (last write wins)
- **AND** all nodes SHALL converge to the same value

### Requirement: Sync status and repair
The system SHALL provide CLI commands to inspect replication status and force re-synchronization.

#### Scenario: View sync status
- **WHEN** a user runs `cortex sync status`
- **THEN** the system SHALL display each replicated table, which nodes hold copies, and whether they are in sync

#### Scenario: View sync status for a specific table
- **WHEN** a user runs `cortex sync status <table>`
- **THEN** the system SHALL display replication details for that table

#### Scenario: Force re-sync
- **WHEN** a user runs `cortex sync repair <table>`
- **THEN** the system SHALL force Mnesia to re-synchronize that table across its replica nodes

### Requirement: Offline resilience
Nodes SHALL continue to function independently during network partitions, with data reconciling when connectivity is restored.

#### Scenario: Node operates during partition
- **WHEN** a node loses connectivity to other mesh nodes
- **THEN** local operations (Unix socket and local data) SHALL continue unaffected

#### Scenario: Data reconciles after partition heals
- **WHEN** a network partition heals and nodes reconnect
- **THEN** Mnesia SHALL reconcile replicated tables across the reconnected nodes
