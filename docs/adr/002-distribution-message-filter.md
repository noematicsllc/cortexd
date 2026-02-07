# ADR-002: Erlang Distribution Message Filter

## Status

Proposed (investigation needed)

## Context

ADR-001 introduced mesh networking with mTLS for inter-node communication. The TLS distribution channel (`-proto_dist inet_tls`) encrypts and authenticates node connections using the mesh CA. However, any certificate signed by the CA grants the connecting node **full Erlang distribution access**, including:

- `:rpc.call/4` / `:erpc.call/4` — execute arbitrary functions on any node
- `Node.spawn/4` — spawn arbitrary processes on remote nodes
- `:code.load_binary/3` — load compiled modules into the remote VM
- Direct PID message sends — inject messages into any process

This is inherent to Erlang distribution's trust model (designed for same-admin clusters). The practical risk: a compromised node cert grants full RCE on every node in the mesh.

## Decision

Two complementary mechanisms, designed to work together with no race window:

1. **Distribution message filter** — active from node startup, restricts the channel to Mnesia replication + a small set of safe read-only RPC calls
2. **Code attestation** — uses those safe RPC calls to verify remote nodes are running genuine code, on connection and periodically thereafter

The filter makes attestation safe (rogue nodes can't attack during verification). Attestation makes the filter meaningful (verified nodes won't try to circumvent it). Neither requires a trust window.

## Part 1: Distribution Message Filter

### RCE Vectors in Erlang Distribution

| Vector | Protocol mechanism | Mitigation |
|---|---|---|
| `:rpc.call` | `REG_SEND` to `rex` — `{:call, Mod, Fun, Args, GL}` | Content-filter `rex`: allow only safe calls |
| `:rpc.cast` | `REG_SEND` to `rex` — `{:cast, Mod, Fun, Args, GL}` | Block (no safe casts needed) |
| `:rpc.block_call` | `REG_SEND` to `rex` — `{:block_call, Mod, Fun, Args, GL}` | Block (no safe block_calls needed) |
| `:erpc.call` | `SPAWN_REQUEST` control message | Block entirely |
| `Node.spawn` | `SPAWN_REQUEST` control message | Block entirely |
| Direct PID send | `SEND` / `SEND_SENDER` control message | Evaluate (Mnesia may need) |
| Code loading | Via `rpc`/`erpc` to `code_server` | Covered by `rex` filter + `SPAWN_REQUEST` block |

### Library: tcp_filter_dist

[tcp_filter_dist](https://github.com/otp-interop/tcp_filter_dist) (0.1.x) implements a custom `-proto_dist` module that intercepts distribution control messages before delivery. It supports a `TCPFilter.Filter` behaviour with callbacks that receive the raw [distribution protocol control messages](https://www.erlang.org/doc/apps/erts/erl_dist_protocol.html) and can allow, block, or ignore them.

Supports TLS transport via `TCPFilter.SSLSocket`.

### Filter Design

Three tiers: Mnesia/kernel processes are fully allowed, `rex` is content-filtered to safe read-only calls, everything else is blocked.

**Tier 1 — Fully allowed `REG_SEND` targets (Mnesia + kernel):**
| Process | Role |
|---|---|
| `mnesia_controller` | Schema ops, table loading, add_table_copy |
| `mnesia_tm` | Transaction coordination, 2-phase commit |
| `mnesia_locker` | Distributed lock acquisition |
| `mnesia_recover` | Transaction recovery after partition |
| `mnesia_rpc` | Mnesia's own RPC server (avoids system `rex`) |
| `mnesia_monitor` | Node monitoring, partition detection |
| `mnesia_checkpoint_sup` | Checkpoint coordination |
| `mnesia_late_loader` | Delayed table loading |
| `mnesia_event` | Event notifications |
| `mnesia_subscr` | Subscription forwarding |
| `net_kernel` | Heartbeat, connection management |
| `global_name_server` | Global process registry |

**Tier 2 — Content-filtered `rex` (safe read-only calls for attestation):**

The `rex` process receives messages in the format `{:call, Module, Function, Args, GroupLeader}` (confirmed from [OTP rpc.erl source](https://github.com/erlang/otp/blob/master/lib/kernel/src/rpc.erl)). The filter inspects the payload and allows only known-safe read-only calls:

| Allowed call | Purpose | Why safe |
|---|---|---|
| `{:call, :code, :get_object_code, [_mod], _}` | Fetch loaded beam bytecode | Read-only, returns bytecodes |
| `{:call, :code, :module_md5, [_mod], _}` | Module checksum | Read-only, returns hash |
| `{:call, :erlang, :system_info, [_], _}` | OTP version, node info | Read-only system metadata |

All other `rex` messages are blocked — `{:cast, ...}`, `{:block_call, ...}`, and `{:call, ...}` with non-allowlisted modules.

**Tier 3 — Blocked entirely:**
| Mechanism | Control message type | Why block |
|---|---|---|
| `erpc` / `Node.spawn` | `SPAWN_REQUEST` (29, 30) | Executes arbitrary code via spawned process |
| Direct PID sends | `SEND` / `SEND_SENDER` (2, 22) | Message injection (evaluate — Mnesia may need) |
| `code_server` | `REG_SEND` to `code_server` | Remote code loading |
| Any other named process | `REG_SEND` to unlisted name | Unknown/untrusted |

### Filter Implementation

```elixir
defmodule Cortex.DistFilter do
  @behaviour TCPFilter.Filter

  @mnesia_processes [
    :mnesia_controller, :mnesia_tm, :mnesia_locker,
    :mnesia_recover, :mnesia_rpc, :mnesia_monitor,
    :mnesia_checkpoint_sup, :mnesia_late_loader,
    :mnesia_event, :mnesia_subscr
  ]

  @kernel_processes [:net_kernel, :global_name_server]

  @tier1_allowed @mnesia_processes ++ @kernel_processes

  # Safe read-only calls allowed through rex (for attestation)
  @safe_rex_calls [
    {:code, :get_object_code, 1},
    {:code, :module_md5, 1},
    {:erlang, :system_info, 1}
  ]

  # --- Tier 1: Mnesia + kernel (fully allowed) ---
  def filter({:reg_send, _from, _unused, name}, _msg)
      when name in @tier1_allowed, do: :ok
  def filter({:reg_send_tt, _from, _unused, name, _token}, _msg)
      when name in @tier1_allowed, do: :ok

  # --- Tier 2: rex content filter (safe read-only calls only) ---
  def filter({:reg_send, _from, _unused, :rex},
             {:call, mod, fun, args, _gl}) do
    if {mod, fun, length(args)} in @safe_rex_calls, do: :ok,
      else: {:error, :unauthorized}
  end
  def filter({:reg_send, _from, _unused, :rex}, _msg),
      do: {:error, :unauthorized}

  # --- Process monitors/links (needed for supervision) ---
  def filter({:monitor_p, _, _, _}), do: :ok
  def filter({:demonitor_p, _, _, _}), do: :ok
  def filter({:monitor_p_exit, _, _, _}), do: :ok
  def filter({:link, _, _}), do: :ok
  def filter({:unlink_id, _, _, _}), do: :ok
  def filter({:unlink_id_ack, _, _, _}), do: :ok
  def filter({:exit, _, _, _}), do: :ok
  def filter({:exit2, _, _, _}), do: :ok

  # --- Tier 3: Block everything else ---
  def filter(_), do: {:error, :unauthorized}
  def filter(_, _), do: {:error, :unauthorized}
end
```

## Part 2: Code Attestation

### Concept

The Tier 2 safe calls exist specifically to enable attestation. Since `:code.get_object_code/1` and `:code.module_md5/1` are permanently allowed through the filter, any node can verify any other node's loaded code at any time — no windows, no phases, no state transitions.

```elixir
# This works even with the filter fully active, because
# {:call, :code, :get_object_code, [Cortex.Handler], _} is in @safe_rex_calls
remote_beam = :rpc.call(remote_node, :code, :get_object_code, [Cortex.Handler])
```

The remote node can't fake the result because we're executing `:code.get_object_code` on their VM — they don't control what we call.

### Implementation

```elixir
defmodule Cortex.Mesh.Attestation do
  @critical_modules [
    Cortex.Handler, Cortex.Store, Cortex.ACL,
    Cortex.Identity, Cortex.Mesh.Token, Cortex.TLSServer
  ]

  @doc "Verify remote node is running genuine cortex code."
  def verify(node) do
    Enum.all?(@critical_modules, fn mod ->
      case :rpc.call(node, :code, :get_object_code, [mod]) do
        {^mod, remote_beam, _filename} ->
          {^mod, local_beam, _} = :code.get_object_code(mod)
          remote_beam == local_beam
        _ ->
          false
      end
    end)
  end
end
```

### When to Attest

- **On connection:** In `Mesh.Manager.handle_info({:nodeup, node}, ...)`, attest immediately. If attestation fails, disconnect with `Node.disconnect/1`.
- **Periodically:** Run attestation on a timer (e.g., every 5 minutes) for all connected nodes. Detects a hypothetical scenario where a node is compromised after joining — though with `SPAWN_REQUEST` and unsafe `rex` calls blocked, hot-loading new code remotely is not possible. The periodic check guards against local compromise where an attacker with shell access to a mesh node replaces beam files and triggers a code reload.
- **On suspicion:** Expose an RPC method or CLI command (`cortex mesh attest <node>`) for manual verification.

### Rolling Upgrades

Bytecode comparison means all nodes must run the same release. For rolling upgrades, the attestation module should accept both current and previous release hashes:

```elixir
@accepted_hashes %{
  Cortex.Handler => [current_md5, previous_md5],
  # ...
}
```

Or compare a release manifest hash rather than individual modules.

### Key Risk: Direct PID Sends

Mnesia may internally spawn unnamed processes that communicate cross-node using direct PID sends (`SEND` control messages) rather than named process `REG_SEND`. This could happen during:

- Table loading / copy operations
- Checkpoint retainers
- Transaction participant processes

If the filter blocks `SEND`, these operations would silently fail. This is the primary unknown that requires empirical testing.

### Testing Plan

**A. Verify Mnesia works through the filter:**
1. Set up a 2-node mesh with the filter active from startup
2. Exercise all Mnesia operations:
   - `create_table` with `disc_copies` on both nodes
   - `add_table_copy` / `del_table_copy`
   - Transactions spanning both nodes
   - Dirty reads/writes from remote node
   - `mnesia:sync_transaction` across nodes
   - Table loading after node restart
   - Checkpoint creation and activation
3. If `SEND` blocking breaks Mnesia, options:
   a. Allow `SEND` but block `SPAWN_REQUEST` and `REG_SEND` to `rex`/`code_server` (weaker but still blocks the main RCE vectors)
   b. Inspect Mnesia source to enumerate specific PID send patterns and allow only those

**B. Verify RCE vectors are blocked:**
1. `:rpc.call(remote, System, :cmd, ["whoami", []])` — must fail
2. `:rpc.cast(remote, System, :cmd, ["whoami", []])` — must fail
3. `:erpc.call(remote, fn -> System.cmd("whoami", []) end)` — must fail
4. `Node.spawn(remote, fn -> File.write!("/tmp/pwned", "yes") end)` — must fail
5. `:rpc.call(remote, :code, :load_binary, [...])` — must fail

**C. Verify attestation works through the filter:**
1. `:rpc.call(remote, :code, :get_object_code, [Cortex.Handler])` — must succeed
2. `:rpc.call(remote, :code, :module_md5, [Cortex.Handler])` — must succeed
3. `Cortex.Mesh.Attestation.verify(remote)` — must return true for genuine node
4. Attestation of a node running modified code — must return false

**D. Verify periodic attestation:**
1. Connect genuine node, verify attestation passes
2. (Simulate) replace a beam file on the remote node, reload module
3. Next periodic attestation should fail and disconnect the node

### Maturity Concern

`tcp_filter_dist` is 0.1.x with 9 commits. Before depending on it:
- Audit the source (it's small)
- Verify it correctly wraps `inet_tls_dist` for TLS support
- Consider vendoring or forking if upstream is inactive

Alternatively, implement the filter directly using OTP's [distribution controller process API](https://www.erlang.org/doc/apps/erts/alt_dist.html) and the example implementations in `$ERL_TOP/lib/kernel/examples/`.

## Consequences

- **Positive:** Blocks the primary RCE vector from compromised node certs
- **Positive:** Defense-in-depth — even with a valid cert, a rogue node can only participate in Mnesia replication
- **Positive:** Code attestation detects tampered or non-genuine nodes before they can act
- **Positive:** The two mechanisms reinforce each other — attestation proves legitimacy, the filter maintains it
- **Negative:** Adds a dependency (or vendored code) in the distribution path
- **Negative:** Risk of breaking Mnesia operations if the whitelist is incomplete
- **Negative:** Performance overhead from message inspection (likely negligible for Mnesia traffic volumes)
- **Negative:** Attestation requires all mesh nodes to run the same release version (beam bytecode must match). Rolling upgrades would need a version-aware attestation that accepts N and N-1
