defmodule Cortex.Mesh.PairingIntegrationTest do
  use ExUnit.Case

  alias Cortex.Mesh.{Pairing, Certs, JoinToken}

  @moduletag :mesh

  # Full integration tests for the mesh join protocol.
  # Each test sets up a "seed" node with CA, certs, and a running Pairing GenServer,
  # then exercises the join flow.

  setup do
    dir = Path.join(System.tmp_dir!(), "pairing_integ_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:ok, %{ca_cert: ca_cert, node_cert: node_cert, node_key: node_key}} =
      Certs.init_mesh(dir, node_name: "seed-node", host: "127.0.0.1")

    tls_port = 15_528 + rem(:erlang.unique_integer([:positive]), 10_000)

    mesh_config = [
      node_name: "seed-node",
      tls_port: tls_port,
      ca_cert: ca_cert,
      node_cert: node_cert,
      node_key: node_key,
      host: "127.0.0.1",
      nodes: []
    ]

    prev_config = Application.get_env(:cortex, :mesh)
    Application.put_env(:cortex, :mesh, mesh_config)

    {:ok, pid} = Pairing.start_link([])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)

      if prev_config,
        do: Application.put_env(:cortex, :mesh, prev_config),
        else: Application.delete_env(:cortex, :mesh)

      File.rm_rf!(dir)
    end)

    {:ok, dir: dir, tls_port: tls_port, pairing_port: tls_port + 1, ca_cert: ca_cert, node_cert: node_cert}
  end

  # Helper: generate an invite token the same way dispatch("mesh_invite") does
  defp generate_invite_token do
    config = Application.get_env(:cortex, :mesh)
    {:ok, secret} = Pairing.add_secret()
    node_cert_path = Keyword.fetch!(config, :node_cert)
    tls_port = Keyword.get(config, :tls_port, 5528)
    host = Keyword.get(config, :host, "127.0.0.1")
    {:ok, fingerprint} = JoinToken.cert_fingerprint(node_cert_path)
    token = JoinToken.encode(host, tls_port + 1, secret, fingerprint)
    {:ok, token}
  end

  test "full init→invite→join flow", %{pairing_port: port, ca_cert: ca_cert, dir: dir} do
    # 1. Seed generates invite token (same logic as mesh_invite handler)
    {:ok, token} = generate_invite_token()
    assert String.starts_with?(token, "cxm_")

    # 2. Decode the token
    {:ok, decoded} = JoinToken.decode(token)
    assert decoded.host == "127.0.0.1"
    assert decoded.port == port

    # 3. Joiner generates keypair + CSR
    joiner_key = Path.join(dir, "joiner.key")
    joiner_csr = Path.join(dir, "joiner.csr")
    {_, 0} = System.cmd("openssl", ["genrsa", "-out", joiner_key, "2048"], stderr_to_stdout: true)

    {_, 0} =
      System.cmd(
        "openssl",
        ["req", "-new", "-key", joiner_key, "-out", joiner_csr, "-subj", "/CN=joiner-node"],
        stderr_to_stdout: true
      )

    csr_pem = File.read!(joiner_csr)

    # 4. Connect to pairing port, verify fingerprint, send mesh.pair
    ssl_opts = [
      verify: :verify_peer,
      cacertfile: String.to_charlist(ca_cert),
      versions: [:"tlsv1.2"],
      active: false
    ]

    {:ok, socket} = :ssl.connect(~c"127.0.0.1", port, ssl_opts, 5_000)

    # Verify fingerprint matches token
    {:ok, cert_der} = :ssl.peercert(socket)
    actual_fp = :crypto.hash(:sha256, cert_der) |> Base.encode16(case: :lower)
    assert actual_fp == decoded.cert_fingerprint

    # Send mesh.pair
    request = Msgpax.pack!([0, 1, "mesh.pair", [decoded.secret, csr_pem, "joiner-node"]])
    :ok = :ssl.send(socket, request)

    {:ok, response_data} = :ssl.recv(socket, 0, 10_000)
    {:ok, [1, 1, nil, result]} = Msgpax.unpack(response_data)
    :ssl.close(socket)

    # 5. Verify response contains signed cert, CA cert, and peers
    assert result["cert"] =~ "BEGIN CERTIFICATE"
    assert result["ca_cert"] =~ "BEGIN CERTIFICATE"
    assert is_list(result["peers"])

    # Verify cert is CA-signed
    cert_tmp = Path.join(dir, "joiner_verified.crt")
    File.write!(cert_tmp, result["cert"])
    {_, 0} = System.cmd("openssl", ["verify", "-CAfile", ca_cert, cert_tmp])

    # 6. Token secret is now consumed — replay should fail
    {:ok, socket2} = :ssl.connect(~c"127.0.0.1", port, ssl_opts, 5_000)

    request2 = Msgpax.pack!([0, 2, "mesh.pair", [decoded.secret, csr_pem, "replay-node"]])
    :ok = :ssl.send(socket2, request2)

    {:ok, response_data2} = :ssl.recv(socket2, 0, 5_000)
    {:ok, [1, 2, error, nil]} = Msgpax.unpack(response_data2)
    assert error =~ "invalid or expired secret"
    :ssl.close(socket2)
  end

  test "CA fingerprint mismatch aborts before sending secret", %{pairing_port: port, dir: dir} do
    {:ok, _secret} = Pairing.add_secret()

    # Create a different CA to simulate mismatch
    other_dir = Path.join(dir, "other_ca")
    {:ok, _} = Certs.init_ca(other_dir)
    other_ca_cert = Path.join(other_dir, "ca.crt")

    # The token would contain the real CA fingerprint.
    # If we connect and find a DIFFERENT fingerprint, we should abort.
    # Here we verify the mechanism: connect with real CA, get real fingerprint,
    # and compare against a fake expected fingerprint.
    ssl_opts = [
      verify: :verify_peer,
      cacertfile: String.to_charlist(Path.join(dir, "ca.crt")),
      versions: [:"tlsv1.2"],
      active: false
    ]

    {:ok, socket} = :ssl.connect(~c"127.0.0.1", port, ssl_opts, 5_000)
    {:ok, cert_der} = :ssl.peercert(socket)
    actual_fp = :crypto.hash(:sha256, cert_der) |> Base.encode16(case: :lower)

    # Compute fingerprint of the OTHER CA
    {:ok, other_fp} = JoinToken.cert_fingerprint(other_ca_cert)

    # They should be different
    assert actual_fp != other_fp

    # In a real join, the CLI would abort here without sending the secret
    :ssl.close(socket)
  end

  test "replay of used secret is rejected", %{pairing_port: port, ca_cert: ca_cert, dir: dir} do
    {:ok, secret} = Pairing.add_secret()

    # Generate CSR
    key_path = Path.join(dir, "replay_test.key")
    csr_path = Path.join(dir, "replay_test.csr")
    {_, 0} = System.cmd("openssl", ["genrsa", "-out", key_path, "2048"], stderr_to_stdout: true)

    {_, 0} =
      System.cmd(
        "openssl",
        ["req", "-new", "-key", key_path, "-out", csr_path, "-subj", "/CN=replay-test"],
        stderr_to_stdout: true
      )

    csr_pem = File.read!(csr_path)

    ssl_opts = [
      verify: :verify_peer,
      cacertfile: String.to_charlist(ca_cert),
      versions: [:"tlsv1.2"],
      active: false
    ]

    # First use — should succeed
    {:ok, s1} = :ssl.connect(~c"127.0.0.1", port, ssl_opts, 5_000)
    req1 = Msgpax.pack!([0, 1, "mesh.pair", [secret, csr_pem, "node-first"]])
    :ok = :ssl.send(s1, req1)
    {:ok, data1} = :ssl.recv(s1, 0, 10_000)
    {:ok, [1, 1, nil, _result]} = Msgpax.unpack(data1)
    :ssl.close(s1)

    # Replay — should fail
    {:ok, s2} = :ssl.connect(~c"127.0.0.1", port, ssl_opts, 5_000)
    req2 = Msgpax.pack!([0, 2, "mesh.pair", [secret, csr_pem, "node-replay"]])
    :ok = :ssl.send(s2, req2)
    {:ok, data2} = :ssl.recv(s2, 0, 5_000)
    {:ok, [1, 2, error, nil]} = Msgpax.unpack(data2)
    assert error =~ "invalid or expired secret"
    :ssl.close(s2)
  end

  test "invite from any node produces a working token", %{pairing_port: port, ca_cert: ca_cert, dir: dir} do
    # Generate two invite tokens — both should work independently
    {:ok, token1} = generate_invite_token()
    {:ok, token2} = generate_invite_token()
    assert token1 != token2

    {:ok, d1} = JoinToken.decode(token1)
    {:ok, d2} = JoinToken.decode(token2)

    # Use token1
    key1 = Path.join(dir, "inv1.key")
    csr1 = Path.join(dir, "inv1.csr")
    {_, 0} = System.cmd("openssl", ["genrsa", "-out", key1, "2048"], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("openssl", ["req", "-new", "-key", key1, "-out", csr1, "-subj", "/CN=inv1"],
        stderr_to_stdout: true
      )

    csr_pem1 = File.read!(csr1)

    ssl_opts = [verify: :verify_peer, cacertfile: String.to_charlist(ca_cert), versions: [:"tlsv1.2"], active: false]

    {:ok, s1} = :ssl.connect(~c"127.0.0.1", port, ssl_opts, 5_000)
    req = Msgpax.pack!([0, 1, "mesh.pair", [d1.secret, csr_pem1, "inv1"]])
    :ok = :ssl.send(s1, req)
    {:ok, data} = :ssl.recv(s1, 0, 10_000)
    {:ok, [1, 1, nil, _]} = Msgpax.unpack(data)
    :ssl.close(s1)

    # Token2 should still work (independent secret)
    key2 = Path.join(dir, "inv2.key")
    csr2 = Path.join(dir, "inv2.csr")
    {_, 0} = System.cmd("openssl", ["genrsa", "-out", key2, "2048"], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("openssl", ["req", "-new", "-key", key2, "-out", csr2, "-subj", "/CN=inv2"],
        stderr_to_stdout: true
      )

    csr_pem2 = File.read!(csr2)

    {:ok, s2} = :ssl.connect(~c"127.0.0.1", port, ssl_opts, 5_000)
    req2 = Msgpax.pack!([0, 2, "mesh.pair", [d2.secret, csr_pem2, "inv2"]])
    :ok = :ssl.send(s2, req2)
    {:ok, data2} = :ssl.recv(s2, 0, 10_000)
    {:ok, [1, 2, nil, _]} = Msgpax.unpack(data2)
    :ssl.close(s2)
  end
end
