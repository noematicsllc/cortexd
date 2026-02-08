## ADDED Requirements

### Requirement: mesh init command
`cortex mesh init` SHALL bootstrap a new mesh on the current node by generating a CA, generating a node certificate, writing mesh config, restarting the daemon, and printing a join token.

#### Scenario: Initialize mesh on a fresh node
- **WHEN** the operator runs `cortex mesh init` on a node with no existing mesh config
- **THEN** the system generates a CA keypair and certificate, generates a node keypair and CA-signed certificate, writes certs to `/etc/cortex/mesh/`, writes mesh environment config, restarts cortexd, and prints a join token to stdout

#### Scenario: mesh init with custom host
- **WHEN** the operator runs `cortex mesh init --host 10.0.0.5`
- **THEN** the node certificate includes `10.0.0.5` in its SAN entries and the join token encodes `10.0.0.5` as the host

#### Scenario: mesh init with custom node name
- **WHEN** the operator runs `cortex mesh init --name my-node`
- **THEN** the node certificate CN is `my-node`

#### Scenario: mesh init with custom port
- **WHEN** the operator runs `cortex mesh init --port 6600`
- **THEN** the TLS port is configured as 6600 and the join token encodes pairing port 6601

#### Scenario: mesh init fails if mesh already configured
- **WHEN** the operator runs `cortex mesh init` and mesh cert files already exist
- **THEN** the system prints an error and exits without overwriting, unless `--force` is provided

#### Scenario: mesh init detects host automatically
- **WHEN** the operator runs `cortex mesh init` without `--host`
- **THEN** the system detects the node's public or primary IP address and uses it as the host

### Requirement: mesh join command
`cortex mesh join <token>` SHALL join an existing mesh using a join token by generating a local keypair, performing the pairing handshake, installing certs, and configuring the daemon.

#### Scenario: Join a mesh with a valid token
- **WHEN** the operator runs `cortex mesh join cxm_<valid_token>` on a node with no existing mesh config
- **THEN** the system decodes the token, generates a local keypair and CSR, connects to the seed's pairing port over TLS, verifies the certificate fingerprint, sends the pairing request, receives a signed cert + CA cert + peer list, writes certs to `/etc/cortex/mesh/`, writes mesh config, and restarts cortexd

#### Scenario: Certificate fingerprint verification prevents MITM
- **WHEN** the joining node connects to the pairing port and the server's certificate fingerprint does not match the token's `cert_fingerprint`
- **THEN** the system aborts the connection before sending the secret, and prints an error

#### Scenario: mesh join with custom node name
- **WHEN** the operator runs `cortex mesh join <token> --name my-edge-node`
- **THEN** the CSR CN is set to `my-edge-node`

#### Scenario: Default node name from hostname
- **WHEN** the operator runs `cortex mesh join <token>` without `--name`
- **THEN** the node name defaults to the hostname with a random suffix (e.g., `vps-6c46c9af`)

#### Scenario: mesh join fails with invalid token
- **WHEN** the operator runs `cortex mesh join <invalid_token>`
- **THEN** the system prints an error indicating the token is invalid and exits

#### Scenario: mesh join fails if mesh already configured
- **WHEN** the operator runs `cortex mesh join <token>` and mesh cert files already exist
- **THEN** the system prints an error and exits without overwriting, unless `--force` is provided

### Requirement: mesh invite command
`cortex mesh invite` SHALL generate a new join token from any running mesh node by calling the daemon via RPC.

#### Scenario: Generate an invite token
- **WHEN** the operator runs `cortex mesh invite` on a node that is part of a mesh
- **THEN** the system calls the `mesh_invite` RPC method, which generates a new one-time secret and returns a join token encoding this node's host, pairing port, the secret, and the certificate fingerprint

#### Scenario: mesh invite fails if not in a mesh
- **WHEN** the operator runs `cortex mesh invite` on a node that is not part of a mesh
- **THEN** the system prints an error indicating mesh is not configured

### Requirement: mesh_invite RPC method
The daemon SHALL expose a `mesh_invite` RPC method that generates a new pairing secret and returns a join token.

#### Scenario: mesh_invite RPC on a mesh node
- **WHEN** the `mesh_invite` RPC method is called on a running mesh node
- **THEN** the daemon calls `Pairing.add_secret/0`, encodes a join token with the node's host, pairing port, the new secret, and certificate fingerprint, and returns the token string

#### Scenario: mesh_invite RPC on a non-mesh node
- **WHEN** the `mesh_invite` RPC method is called on a node without mesh config
- **THEN** the daemon returns an error: `"mesh networking not configured"`

### Requirement: Mesh config environment file
The CLI commands SHALL write mesh configuration as environment variables to `/etc/cortex/mesh.env` (or a configured path) that the release startup script reads.

#### Scenario: mesh init writes env config
- **WHEN** `cortex mesh init` completes cert generation
- **THEN** it writes a `mesh.env` file containing `CORTEX_MESH_NODE_NAME`, `CORTEX_MESH_TLS_PORT`, `CORTEX_MESH_CA_CERT`, `CORTEX_MESH_NODE_CERT`, `CORTEX_MESH_NODE_KEY`, and `CORTEX_MESH_NODES` (empty initially)

#### Scenario: mesh join writes env config with peers
- **WHEN** `cortex mesh join` completes the pairing handshake
- **THEN** it writes a `mesh.env` file containing the same variables, with `CORTEX_MESH_NODES` populated from the peer list received during pairing

### Requirement: Daemon restart after config change
Both `cortex mesh init` and `cortex mesh join` SHALL restart the cortexd systemd service after writing config, then verify the daemon is healthy.

#### Scenario: Restart and health check
- **WHEN** mesh config has been written
- **THEN** the CLI runs `systemctl restart cortexd`, then polls `cortex ping` until the daemon responds or a timeout (10 seconds) is reached

#### Scenario: Restart failure
- **WHEN** systemctl restart fails or the daemon does not become healthy within the timeout
- **THEN** the CLI prints an error with guidance to check `journalctl -u cortexd`
