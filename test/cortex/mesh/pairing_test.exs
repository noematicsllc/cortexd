defmodule Cortex.Mesh.PairingTest do
  use ExUnit.Case

  alias Cortex.Mesh.{Pairing, Certs}

  @moduletag :mesh

  # Setup: create a temp CA and start Pairing with test mesh config
  setup do
    dir = Path.join(System.tmp_dir!(), "pairing_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # Generate CA + node cert
    {:ok, %{ca_cert: ca_cert, node_cert: node_cert, node_key: node_key}} =
      Certs.init_mesh(dir, node_name: "test-seed", host: "127.0.0.1")

    tls_port = 15_528 + rem(:erlang.unique_integer([:positive]), 10_000)

    mesh_config = [
      node_name: "test-seed",
      tls_port: tls_port,
      ca_cert: ca_cert,
      node_cert: node_cert,
      node_key: node_key,
      host: "127.0.0.1",
      nodes: []
    ]

    # Set mesh config for the Pairing GenServer
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

    {:ok, dir: dir, tls_port: tls_port, pairing_port: tls_port + 1, ca_cert: ca_cert}
  end

  describe "secret management" do
    test "add_secret returns a 64-char hex string" do
      {:ok, secret} = Pairing.add_secret()
      assert String.length(secret) == 64
      assert Regex.match?(~r/^[0-9a-f]{64}$/, secret)
    end

    test "validate_secret succeeds for a pending secret" do
      {:ok, secret} = Pairing.add_secret()
      assert {:ok, :valid} = Pairing.validate_secret(secret)
    end

    test "validate_secret rejects an already-used secret" do
      {:ok, secret} = Pairing.add_secret()
      {:ok, :valid} = Pairing.validate_secret(secret)
      assert {:error, "invalid or expired secret"} = Pairing.validate_secret(secret)
    end

    test "validate_secret rejects an unknown secret" do
      assert {:error, "invalid or expired secret"} = Pairing.validate_secret("nonexistent")
    end

    test "multiple secrets are independent" do
      {:ok, s1} = Pairing.add_secret()
      {:ok, s2} = Pairing.add_secret()
      assert s1 != s2

      {:ok, :valid} = Pairing.validate_secret(s1)
      # s2 should still be valid
      {:ok, :valid} = Pairing.validate_secret(s2)
    end
  end

  describe "pairing listener" do
    test "accepts TLS connections without client certificate", %{
      pairing_port: port,
      ca_cert: ca_cert
    } do
      # Connect without a client cert — should succeed
      ssl_opts = [
        verify: :verify_peer,
        cacertfile: String.to_charlist(ca_cert),
        versions: [:"tlsv1.2"],
        active: false
      ]

      assert {:ok, socket} = :ssl.connect(~c"127.0.0.1", port, ssl_opts, 5_000)
      :ssl.close(socket)
    end

    test "rejects non-mesh.pair RPC methods", %{pairing_port: port, ca_cert: ca_cert} do
      ssl_opts = [
        verify: :verify_peer,
        cacertfile: String.to_charlist(ca_cert),
        versions: [:"tlsv1.2"],
        active: false
      ]

      {:ok, socket} = :ssl.connect(~c"127.0.0.1", port, ssl_opts, 5_000)

      # Send a non-pairing RPC
      request = Msgpax.pack!([0, 1, "ping", []])
      :ok = :ssl.send(socket, request)

      {:ok, response_data} = :ssl.recv(socket, 0, 5_000)
      {:ok, [1, 1, error, nil]} = Msgpax.unpack(response_data)

      assert error =~ "method not available on pairing endpoint"
      :ssl.close(socket)
    end
  end

  describe "full pairing flow" do
    test "mesh.pair with valid secret and CSR returns signed cert + CA + peers",
         %{pairing_port: port, ca_cert: ca_cert, dir: dir} do
      # Generate a secret
      {:ok, secret} = Pairing.add_secret()

      # Generate a CSR for the joining node
      key_path = Path.join(dir, "joiner.key")
      csr_path = Path.join(dir, "joiner.csr")
      {_, 0} = System.cmd("openssl", ["genrsa", "-out", key_path, "2048"], stderr_to_stdout: true)

      {_, 0} =
        System.cmd(
          "openssl",
          ["req", "-new", "-key", key_path, "-out", csr_path, "-subj", "/CN=joiner-node"],
          stderr_to_stdout: true
        )

      csr_pem = File.read!(csr_path)

      # Connect to pairing port
      ssl_opts = [
        verify: :verify_peer,
        cacertfile: String.to_charlist(ca_cert),
        versions: [:"tlsv1.2"],
        active: false
      ]

      {:ok, socket} = :ssl.connect(~c"127.0.0.1", port, ssl_opts, 5_000)

      # Send mesh.pair request
      request = Msgpax.pack!([0, 1, "mesh.pair", [secret, csr_pem, "joiner-node"]])
      :ok = :ssl.send(socket, request)

      {:ok, response_data} = :ssl.recv(socket, 0, 10_000)
      {:ok, [1, 1, nil, result]} = Msgpax.unpack(response_data)

      assert is_map(result)
      assert result["cert"] =~ "BEGIN CERTIFICATE"
      assert result["ca_cert"] =~ "BEGIN CERTIFICATE"
      assert is_list(result["peers"])
      assert length(result["peers"]) >= 1

      # Verify the returned cert is signed by the CA
      cert_tmp = Path.join(dir, "joiner_signed.crt")
      File.write!(cert_tmp, result["cert"])
      {_output, 0} = System.cmd("openssl", ["verify", "-CAfile", ca_cert, cert_tmp])

      :ssl.close(socket)
    end

    test "successful pair adds new node to seed's mesh config",
         %{pairing_port: port, ca_cert: ca_cert, dir: dir} do
      {:ok, secret} = Pairing.add_secret()

      key_path = Path.join(dir, "peer_add.key")
      csr_path = Path.join(dir, "peer_add.csr")
      {_, 0} = System.cmd("openssl", ["genrsa", "-out", key_path, "2048"], stderr_to_stdout: true)

      {_, 0} =
        System.cmd(
          "openssl",
          ["req", "-new", "-key", key_path, "-out", csr_path, "-subj", "/CN=new-peer"],
          stderr_to_stdout: true
        )

      csr_pem = File.read!(csr_path)

      ssl_opts = [
        verify: :verify_peer,
        cacertfile: String.to_charlist(ca_cert),
        versions: [:"tlsv1.2"],
        active: false
      ]

      # Before pairing, seed has no peers
      config_before = Application.get_env(:cortex, :mesh)
      assert Keyword.get(config_before, :nodes, []) == []

      {:ok, socket} = :ssl.connect(~c"127.0.0.1", port, ssl_opts, 5_000)
      request = Msgpax.pack!([0, 1, "mesh.pair", [secret, csr_pem, "new-peer"]])
      :ok = :ssl.send(socket, request)
      {:ok, response_data} = :ssl.recv(socket, 0, 10_000)
      {:ok, [1, 1, nil, _result]} = Msgpax.unpack(response_data)
      :ssl.close(socket)

      # Give the spawned handler process time to update config
      Process.sleep(100)

      # After pairing, seed should have the new peer in its config
      config_after = Application.get_env(:cortex, :mesh)
      nodes = Keyword.get(config_after, :nodes, [])
      assert Enum.any?(nodes, fn {name, _, _} -> name == "new-peer" end)
    end

    test "mesh.pair with invalid secret returns error", %{pairing_port: port, ca_cert: ca_cert} do
      ssl_opts = [
        verify: :verify_peer,
        cacertfile: String.to_charlist(ca_cert),
        versions: [:"tlsv1.2"],
        active: false
      ]

      {:ok, socket} = :ssl.connect(~c"127.0.0.1", port, ssl_opts, 5_000)

      request = Msgpax.pack!([0, 1, "mesh.pair", ["invalid_secret", "fake_csr", "node"]])
      :ok = :ssl.send(socket, request)

      {:ok, response_data} = :ssl.recv(socket, 0, 5_000)
      {:ok, [1, 1, error, nil]} = Msgpax.unpack(response_data)

      assert error =~ "invalid or expired secret"
      :ssl.close(socket)
    end
  end
end
