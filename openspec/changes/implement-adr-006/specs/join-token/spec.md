## ADDED Requirements

### Requirement: Join token encoding
The system SHALL encode join tokens in the format `cxm_<base64url(host|port|secret|cert_fingerprint)>` (pipe-delimited to support IPv6 addresses) where:
- `host` is the seed node's IP address or hostname
- `port` is the TLS port (the pairing port is derived as tls_port + 1 by the joining client)
- `secret` is a 32-byte cryptographically random value, hex-encoded (64 hex characters)
- `cert_fingerprint` is the SHA-256 hash of the node certificate's DER encoding, hex-encoded (this is the certificate presented during TLS handshake, verifiable via `:ssl.peercert/1`)

The `cxm_` prefix SHALL be present on all join tokens.

#### Scenario: Encode a join token with an IP host
- **WHEN** encoding a join token with host `158.69.220.39`, port `5529`, a 32-byte secret, and a cert fingerprint
- **THEN** the result starts with `cxm_` followed by base64url encoding of `158.69.220.39|5529|<secret_hex>|<fingerprint_hex>`

#### Scenario: Encode a join token with a hostname
- **WHEN** encoding a join token with host `node1.example.com`, port `5529`, a 32-byte secret, and a cert fingerprint
- **THEN** the result starts with `cxm_` followed by base64url encoding of `node1.example.com|5529|<secret_hex>|<fingerprint_hex>`

### Requirement: Join token decoding
The system SHALL decode a valid join token and return the host, port, secret, and certificate fingerprint as separate fields.

#### Scenario: Decode a valid join token
- **WHEN** decoding a token that starts with `cxm_` and contains valid base64url of a pipe-delimited payload with 4 fields
- **THEN** the system returns `{:ok, %{host: host, port: port, secret: secret, cert_fingerprint: fingerprint}}`

#### Scenario: Reject a token with wrong prefix
- **WHEN** decoding a token that does not start with `cxm_`
- **THEN** the system returns `{:error, "invalid join token prefix"}`

#### Scenario: Reject a token with invalid base64
- **WHEN** decoding a token that starts with `cxm_` but contains invalid base64url data
- **THEN** the system returns an error indicating invalid encoding

#### Scenario: Reject a token with wrong field count
- **WHEN** decoding a token whose base64url payload contains fewer or more than 4 pipe-delimited fields
- **THEN** the system returns an error indicating invalid token format

### Requirement: Join token secret generation
The system SHALL generate secrets using 32 bytes from a cryptographically secure random number generator (`:crypto.strong_rand_bytes/1`).

#### Scenario: Generate a secret
- **WHEN** generating a join token secret
- **THEN** the secret is 32 bytes of cryptographically random data, hex-encoded to 64 characters

### Requirement: Certificate fingerprint computation
The system SHALL compute the certificate fingerprint as the SHA-256 hash of the node certificate's DER-encoded bytes, hex-encoded. This is the leaf certificate presented during TLS handshake (retrievable via `:ssl.peercert/1`), not the CA certificate.

#### Scenario: Compute fingerprint from PEM file
- **WHEN** computing the certificate fingerprint from a PEM-encoded certificate file
- **THEN** the system decodes the PEM to DER, computes SHA-256 of the DER bytes, and returns the result as a lowercase hex string

### Requirement: Join tokens are distinct from identity claim tokens
The `Cortex.Mesh.JoinToken` module SHALL be separate from `Cortex.Mesh.Token`. Join tokens use pipe-delimited fields with a `cxm_` prefix (pipes chosen over colons to support IPv6 addresses). Identity claim tokens use signed JSON payloads with a `.` separator.

#### Scenario: Module separation
- **WHEN** the system encodes or decodes a join token
- **THEN** it uses `Cortex.Mesh.JoinToken`, not `Cortex.Mesh.Token`
