## ADDED Requirements

### Requirement: Federated identity registry
The system SHALL maintain a `cortex_identities` system table that maps federated identity names to local UIDs on each node. This table SHALL be replicated to all mesh nodes.

#### Scenario: Registry structure
- **WHEN** the mesh is initialized
- **THEN** the `cortex_identities` table SHALL exist with records of the form `{fed_id, mappings, metadata}` where `mappings` is a map of `node_name → local_uid`

#### Scenario: Registry replication
- **WHEN** an identity mapping is created or modified on any node
- **THEN** the change SHALL replicate to all mesh nodes

### Requirement: Identity registration
A user SHALL be able to create a federated identity on their local node, linking their local UID to a chosen name.

#### Scenario: Register a new federated identity
- **WHEN** a user runs `cortex identity register <name>`
- **THEN** the system SHALL create a federated identity record mapping the current node and UID to that name
- **AND** output a claim token for linking this identity on other nodes

#### Scenario: Reject duplicate federated identity names
- **WHEN** a user attempts to register a federated identity name that already exists
- **THEN** the system SHALL return an error

#### Scenario: Reject registration without mesh
- **WHEN** a user runs `cortex identity register` on a node without mesh configuration
- **THEN** the system SHALL return an error explaining that federated identity requires mesh networking

### Requirement: Identity claim tokens
The system SHALL generate short-lived claim tokens signed by the origin node's private key, allowing users to link their identity on other nodes.

#### Scenario: Claim token generation
- **WHEN** a federated identity is registered
- **THEN** the system SHALL output a claim token containing the federated ID, origin node, origin UID, issued-at timestamp, and expiry
- **AND** the token SHALL be signed by the node's TLS private key

#### Scenario: Claim token expiry
- **WHEN** a claim token is used after its expiry time (default 24 hours)
- **THEN** the system SHALL reject it

### Requirement: Identity claiming on remote nodes
A user SHALL be able to link their local UID on a remote node to an existing federated identity using a claim token.

#### Scenario: Successful identity claim
- **WHEN** a user runs `cortex identity claim <token>` on a different node
- **THEN** the system SHALL verify the token signature by contacting the origin node over mTLS
- **AND** add a mapping from the current node and UID to the federated identity
- **AND** replicate the updated identity record to all nodes

#### Scenario: Claim with invalid or expired token
- **WHEN** a user presents a token with an invalid signature or past expiry
- **THEN** the system SHALL reject the claim with an error

#### Scenario: Claim when origin node is unreachable
- **WHEN** the origin node is not reachable for token verification
- **THEN** the system SHALL return an error indicating the origin node must be available to verify the claim

### Requirement: Identity resolution for remote requests
The system SHALL resolve incoming remote requests to a federated identity when one exists.

#### Scenario: Remote request with registered identity
- **WHEN** a request arrives over TLS from node-a claiming to be from UID 1000
- **AND** the identity registry maps (node-a, 1000) to federated identity "alice"
- **THEN** the system SHALL resolve the request identity to "alice" for ACL checks

#### Scenario: Remote request without registered identity
- **WHEN** a request arrives over TLS from node-a claiming to be from UID 1000
- **AND** no federated identity mapping exists for (node-a, 1000)
- **THEN** the system SHALL treat the request as identity "node-a:1000" (unfederated)

### Requirement: Identity management commands
The system SHALL provide CLI commands to list and revoke federated identity mappings.

#### Scenario: List identity mappings
- **WHEN** a user runs `cortex identity list`
- **THEN** the system SHALL display all federated identities and their node-to-UID mappings

#### Scenario: Revoke an identity mapping
- **WHEN** a user runs `cortex identity revoke <name> [node]`
- **THEN** the system SHALL remove the mapping for the specified node (or all mappings if no node specified)
- **AND** replicate the change to all nodes

### Requirement: Federated table namespace
The system SHALL support a `@{fed_id}:{name}` table namespace for tables owned by federated identities, in addition to the existing `{uid}:{name}` local namespace.

#### Scenario: Create a federated table
- **WHEN** a user with federated identity "alice" runs `cortex create @memories id content`
- **THEN** the system SHALL create a table namespaced as `@alice:memories`
- **AND** the table's default node scope SHALL be `:all`

#### Scenario: Access federated table by short name
- **WHEN** a user with federated identity "alice" runs `cortex put @memories ...`
- **THEN** the system SHALL resolve to `@alice:memories`

#### Scenario: Access another user's federated table
- **WHEN** a user runs `cortex get @bob:knowledge somekey`
- **THEN** the system SHALL resolve to `@bob:knowledge` and apply ACL checks as normal

#### Scenario: Reject federated namespace without federated identity
- **WHEN** a user without a federated identity attempts to create a table with `@` prefix
- **THEN** the system SHALL return an error
