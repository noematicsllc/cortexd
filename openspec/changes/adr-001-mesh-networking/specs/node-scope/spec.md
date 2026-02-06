## ADDED Requirements

### Requirement: Node scope field on table metadata
Every table SHALL have a `node_scope` field in its metadata controlling which nodes can hold a copy of the table's data. Valid values are `:local`, `:all`, or a list of specific node names.

#### Scenario: Default node scope for local tables
- **WHEN** a table is created with the `{uid}:{name}` namespace (no `@` prefix)
- **THEN** the node scope SHALL default to `:local`

#### Scenario: Default node scope for federated tables
- **WHEN** a table is created with the `@{fed_id}:{name}` namespace
- **THEN** the node scope SHALL default to `:all`

#### Scenario: Explicit scope on table creation
- **WHEN** a user runs `cortex create @secrets id content --scope local`
- **THEN** the table SHALL be created with `node_scope: :local` regardless of namespace defaults

#### Scenario: Specific node list scope
- **WHEN** a user runs `cortex create @docs id body --scope home,office`
- **THEN** the table SHALL be created with `node_scope: ["home", "office"]`

### Requirement: Node scope authorization check
The system SHALL deny access to a table when the requesting node is not permitted by the table's node scope. This check SHALL be independent of identity ACL checks — both MUST pass.

#### Scenario: Local scope denies remote access
- **WHEN** a request for a table with `node_scope: :local` arrives from a remote node
- **THEN** the system SHALL deny access with `:access_denied`

#### Scenario: All scope allows any node
- **WHEN** a request for a table with `node_scope: :all` arrives from any mesh node
- **THEN** the node scope check SHALL pass (identity ACL still applies)

#### Scenario: Specific node list allows listed nodes
- **WHEN** a request for a table with `node_scope: ["home", "office"]` arrives from node "home"
- **THEN** the node scope check SHALL pass

#### Scenario: Specific node list denies unlisted nodes
- **WHEN** a request for a table with `node_scope: ["home", "office"]` arrives from node "cloud"
- **THEN** the system SHALL deny access with `:access_denied`

#### Scenario: Local access always passes node scope
- **WHEN** a request arrives over the Unix socket (local)
- **THEN** the node scope check SHALL always pass (the data is on this node by definition)

### Requirement: Node scope management
Table owners SHALL be able to view and change a table's node scope after creation.

#### Scenario: View node scope
- **WHEN** a user runs `cortex scope <table>`
- **THEN** the system SHALL display the table's current node scope

#### Scenario: Change node scope
- **WHEN** a table owner runs `cortex scope <table> all`
- **THEN** the system SHALL update the table's node scope to `:all`
- **AND** trigger replication changes accordingly

#### Scenario: Non-owner cannot change scope
- **WHEN** a non-owner (without admin permission) runs `cortex scope <table> local`
- **THEN** the system SHALL deny the operation

#### Scenario: Table info includes scope
- **WHEN** a user runs `cortex info <table>`
- **THEN** the output SHALL include the table's node scope alongside ACL information

### Requirement: Backward-compatible metadata migration
Existing tables created before mesh networking SHALL continue to work with `node_scope: :local` applied automatically.

#### Scenario: Upgrade from v1 metadata
- **WHEN** cortexd starts and finds `cortex_meta` records with 5 elements (no node_scope)
- **THEN** the system SHALL treat the missing field as `:local`
- **AND** writes to metadata SHALL use the 6-element format
