# ADR-006: Token-Based Mesh Join

**Status:** Proposal
**Date:** 2026-02-08

## Context

Setting up a mesh currently requires manual certificate generation, file distribution via SSH/SCP, and per-node configuration editing. This is error-prone for humans and assumes nodes have SSH access to each other or to a shared control machine.

We need a join protocol that:
- Requires no pre-existing secure channel (no SSH between nodes)
- Works with two commands total (one per side)
- Bootstraps trust from a single shared token
- Handles CA creation, cert signing, and config in one flow

## Decision

Introduce a **token-based mesh join** protocol with two operations:

### `cortex mesh init`

Run on the first node to bootstrap the mesh:

1. Generate a CA keypair and self-signed CA certificate
2. Generate this node's keypair and CA-signed certificate
3. Write certs to `/etc/cortex/mesh/` (or configured path)
4. Generate a **join token** encoding:
   - This node's host and TLS port
   - A one-time pairing secret (32 bytes, cryptographically random)
   - The CA certificate fingerprint (SHA-256)
5. Open a **pairing endpoint** on the TLS port that accepts join requests authenticated by valid pairing secrets
6. Configure and restart the local daemon with mesh enabled
7. Print the join token to stdout

The join token format: `cxm_<base64url({host}:{port}:{secret}:{ca_fingerprint})>`

The `cxm_` prefix makes tokens identifiable and greppable.

### `cortex mesh join <token>`

Run on each additional node to join an existing mesh:

1. Decode the token to extract host, port, secret, and CA fingerprint
2. Generate a local keypair
3. Generate a CSR with CN set to a node name (derived from hostname or user-provided)
4. Connect to the seed node's pairing endpoint over TLS
   - The seed serves its CA-signed cert
   - The joining node verifies the cert against the CA fingerprint from the token (trust-on-first-use, anchored by the token)
5. Authenticate by sending the one-time secret over the encrypted channel
6. Send the CSR
7. Seed node validates the secret, signs the CSR with its CA, returns:
   - The signed node certificate
   - The full CA certificate
   - The current mesh peer list
8. Joining node writes certs to `/etc/cortex/mesh/`
9. Configure and restart the local daemon with mesh enabled
10. Seed node adds the new node to its peer list and invalidates the used secret

### Operator experience

```
# On node 1 (first node):
sudo cortex mesh init
# → Mesh initialized on 158.69.220.39:5528
# → Join token: cxm_MTU4LjY5LjIyMC4zOTo1NTI4Omth...
# → Share this token with other nodes to join the mesh.

# On node 2 (copy-paste the token via any channel):
sudo cortex mesh join cxm_MTU4LjY5LjIyMC4zOTo1NTI4Omth...
# → Connected to 158.69.220.39:5528
# → Certificate signed by mesh CA
# → Mesh configured. Node name: vps-6c46c9af
# → Restarting cortexd...
# → Joined mesh. Connected peers: node1
```

### Multi-node join

After the first join, any existing mesh node can generate new join tokens:

```
cortex mesh invite
# → Join token: cxm_...
```

This allows the mesh to grow without returning to the original seed node.

### Security properties

- **Token is the trust root.** Whoever possesses the token can join the mesh once. Treat it like a password.
- **One-time use.** Each pairing secret is invalidated after successful use. Replay is not possible.
- **CA fingerprint verification.** The joining node verifies the seed's certificate against the fingerprint embedded in the token, preventing MITM during the join handshake.
- **No long-lived secrets.** After join, all authentication is via mTLS with CA-signed certificates. The pairing secret is discarded.
- **Channel security.** The join handshake occurs over TLS. The pairing secret never travels in plaintext.

### What the token does NOT provide

- **Authorization.** Any valid token grants full mesh membership. There is no role or permission distinction at join time.
- **Revocation.** A joined node stays in the mesh until its certificate is revoked (see ADR future work on certificate revocation).
- **Confidentiality of the token itself.** The token should be shared via a reasonably secure channel (DM, not public chat), but compromise only allows one unauthorized join (one-time use).

## Implementation scope

| Component | Changes |
|-----------|---------|
| `Cortex.Mesh.Certs` | Add `init_mesh/1` (CA + self cert), `sign_csr/2` |
| `Cortex.Mesh.Pairing` | New GenServer: pairing endpoint, secret store, CSR signing |
| `Cortex.TLSServer` | Route pairing requests to Pairing module |
| `Cortex.Mesh.Token` | Encode/decode join tokens (separate from identity claim tokens) |
| Rust CLI | `mesh init`, `mesh join`, `mesh invite` commands |
| `install.sh` / systemd | `mesh init` and `mesh join` must write env config and restart the service |

## Alternatives considered

**SSH-based cert distribution.** Requires SSH access between nodes or from a control machine. Not always available, especially for edge nodes or nodes managed by different operators.

**Diffie-Hellman with visual verification.** Both nodes display a short code, operator verifies they match (like Signal safety numbers). More complex UX — requires simultaneous access to both nodes. DH is also unnecessary when we have a shared secret from the token.

**Pre-shared CA bundle.** Operator generates CA offline, distributes ca.crt manually, nodes generate their own certs and self-sign. Doesn't provide mutual trust — nodes can't verify each other without CA-signed certs.

## Consequences

- Mesh setup becomes a two-command operation
- No SSH access required between nodes
- Join tokens must be treated as sensitive (one-time secrets)
- The seed node must be reachable on its TLS port during join (firewall consideration)
- `cortex mesh invite` enables mesh growth from any node, not just the original seed
