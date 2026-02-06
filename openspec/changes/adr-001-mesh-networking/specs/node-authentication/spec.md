## ADDED Requirements

### Requirement: TLS listener alongside Unix socket
The system SHALL run a TCP+TLS listener alongside the existing Unix domain socket listener. The TLS listener SHALL accept connections from other mesh nodes authenticated via mutual TLS. The Unix socket listener SHALL continue to function unchanged.

#### Scenario: TLS listener starts when mesh is configured
- **WHEN** cortexd starts with mesh configuration (node list, certificate paths)
- **THEN** a TLS listener SHALL bind to the configured address and port (default 4711)
- **AND** the Unix socket listener SHALL start as before

#### Scenario: TLS listener does not start without mesh config
- **WHEN** cortexd starts without mesh configuration
- **THEN** only the Unix socket listener SHALL start (single-node mode, backward compatible)

#### Scenario: TLS listener rejects non-mTLS connections
- **WHEN** a client connects to the TLS port without presenting a client certificate
- **THEN** the TLS handshake SHALL fail with `fail_if_no_peer_cert`

#### Scenario: TLS listener rejects certificates from unknown CAs
- **WHEN** a client presents a certificate not signed by the mesh CA
- **THEN** the TLS handshake SHALL fail

### Requirement: Mesh CA and certificate management
The system SHALL provide CLI commands to create a mesh Certificate Authority and generate node certificates signed by that CA.

#### Scenario: Initialize a new mesh CA
- **WHEN** a user runs `cortex mesh init-ca`
- **THEN** the system SHALL generate a CA private key and self-signed CA certificate
- **AND** output the CA certificate path for distribution to other nodes

#### Scenario: Generate a node certificate
- **WHEN** a user runs `cortex mesh add-node <name> <host>`
- **THEN** the system SHALL generate a private key and certificate signing request for the node
- **AND** sign the certificate with the mesh CA
- **AND** set the CN to the node name and SAN to the host address

#### Scenario: Refuse to overwrite existing CA
- **WHEN** a user runs `cortex mesh init-ca` and a CA already exists
- **THEN** the system SHALL refuse and display an error unless `--force` is provided

### Requirement: Node identity extraction from TLS
The system SHALL extract the connecting node's identity from the peer certificate's Common Name (CN) during TLS connection setup.

#### Scenario: Identify remote node from certificate
- **WHEN** a TLS connection is accepted and the handshake succeeds
- **THEN** the handler SHALL extract the CN from the peer certificate
- **AND** store the node identity in connection state

#### Scenario: Handler dispatches RPC for both transports
- **WHEN** an RPC request arrives over either Unix socket or TLS
- **THEN** the handler SHALL dispatch it through the same RPC method routing
- **AND** the only difference SHALL be how the caller's identity is resolved

### Requirement: Mesh topology configuration
The system SHALL accept a static list of mesh nodes via configuration, specifying node name, host, and port for each peer.

#### Scenario: Configure mesh peers
- **WHEN** cortexd starts with a `mesh.nodes` configuration listing peer nodes
- **THEN** the system SHALL know how to reach each peer for mTLS connections

#### Scenario: Show mesh status
- **WHEN** a user runs `cortex mesh status`
- **THEN** the system SHALL display each configured node with its connectivity status (connected, unreachable, certificate error)

#### Scenario: List mesh nodes
- **WHEN** a user runs `cortex mesh list-nodes`
- **THEN** the system SHALL display all configured mesh nodes with their name, host, and port
