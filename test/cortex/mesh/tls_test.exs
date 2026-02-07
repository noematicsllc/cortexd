defmodule Cortex.Mesh.TLSTest do
  use ExUnit.Case

  alias Cortex.TestHelpers.Mesh, as: MH

  @moduletag :mesh

  setup do
    dir = Path.join(System.tmp_dir!(), "cortex_tls_test_#{:erlang.unique_integer([:positive])}")
    certs = MH.generate_test_certs(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, certs: certs}
  end

  # Task 1.9: TLS listener accepts mTLS connections, rejects no-cert, rejects wrong-CA

  describe "mTLS enforcement" do
    test "accepts connection with valid mutual TLS certs", %{certs: certs} do
      {:ok, listen_socket, port} = MH.start_tls_listener(certs, :node_a)

      # Connect as node-b with valid certs from same CA
      task =
        Task.async(fn ->
          MH.tls_connect(port, certs, :node_b)
        end)

      {:ok, transport_socket} = :ssl.transport_accept(listen_socket, 5_000)
      {:ok, _server_socket} = :ssl.handshake(transport_socket, 5_000)

      {:ok, _client_socket} = Task.await(task)

      :ssl.close(listen_socket)
    end

    test "rejects connection without client certificate", %{certs: certs} do
      # Use TLS 1.2 where fail_if_no_peer_cert is enforced at handshake time
      # (TLS 1.3 uses post-handshake auth which behaves differently)
      node = Map.fetch!(certs, :node_a)

      ssl_opts = [
        certfile: node.cert,
        keyfile: node.key,
        cacertfile: certs.ca_cert,
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        versions: [:"tlsv1.2"],
        active: false,
        reuseaddr: true
      ]

      {:ok, listen_socket} = :ssl.listen(0, ssl_opts)
      {:ok, {_addr, port}} = :ssl.sockname(listen_socket)

      task =
        Task.async(fn ->
          client_opts = [
            cacertfile: certs.ca_cert,
            verify: :verify_peer,
            versions: [:"tlsv1.2"],
            active: false
          ]

          :ssl.connect(~c"127.0.0.1", port, client_opts, 5_000)
        end)

      {:ok, transport_socket} = :ssl.transport_accept(listen_socket, 5_000)

      # Handshake should fail because server requires client cert
      result = :ssl.handshake(transport_socket, 5_000)
      assert {:error, _reason} = result

      # Client should also fail
      client_result = Task.await(task)
      assert {:error, _} = client_result

      :ssl.close(listen_socket)
    end

    test "rejects connection with certificate from wrong CA", %{dir: dir, certs: certs} do
      {:ok, listen_socket, port} = MH.start_tls_listener(certs, :node_a)

      # Generate certs from a completely different CA
      rogue_dir = Path.join(dir, "rogue")
      rogue = MH.generate_rogue_certs(rogue_dir)

      # Try to connect with rogue cert (signed by different CA)
      task =
        Task.async(fn ->
          client_opts = [
            certfile: rogue.cert,
            keyfile: rogue.key,
            cacertfile: rogue.ca_cert,
            verify: :verify_peer,
            versions: [:"tlsv1.3", :"tlsv1.2"],
            active: false
          ]

          :ssl.connect(~c"127.0.0.1", port, client_opts, 5_000)
        end)

      {:ok, transport_socket} = :ssl.transport_accept(listen_socket, 5_000)

      # Handshake should fail — wrong CA
      result = :ssl.handshake(transport_socket, 5_000)
      assert {:error, _reason} = result

      client_result = Task.await(task)
      assert {:error, _} = client_result

      :ssl.close(listen_socket)
    end
  end

  # Task 2.7: Handler accepting TLS transport with correct identity resolution

  describe "TLS handler pipeline" do
    test "TLS connection through handler returns correct response", %{certs: certs} do
      test_port = 15_528 + rem(:erlang.unique_integer([:positive]), 10_000)

      # Set up mesh config
      mesh_config =
        MH.mesh_config_for(certs, :node_a, "node-a", test_port, [])

      original_mesh = Application.get_env(:cortex, :mesh)
      Application.put_env(:cortex, :mesh, mesh_config)

      on_exit(fn ->
        if original_mesh,
          do: Application.put_env(:cortex, :mesh, original_mesh),
          else: Application.delete_env(:cortex, :mesh)
      end)

      # Start TLS server (it reads from Application env)
      {:ok, pid} = Cortex.TLSServer.start_link([])

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      # Give the accept loop a moment to start
      Process.sleep(100)

      # Connect as node-b
      {:ok, client} = MH.tls_connect(test_port, certs, :node_b)

      # Send a ping via MsgPack-RPC
      {:ok, result} = MH.rpc_call(client, "ping")
      assert result == "pong"

      # Status should also work
      {:ok, status} = MH.rpc_call(client, "status")
      assert is_map(status)
      assert status["status"] == "running"

      :ssl.close(client)
    end

    test "TLS handler extracts node CN as identity", %{certs: certs} do
      # Test Identity.get_node_cn with a real TLS connection
      {:ok, listen_socket, port} = MH.start_tls_listener(certs, :node_a)

      task =
        Task.async(fn ->
          {:ok, client} = MH.tls_connect(port, certs, :node_b)
          client
        end)

      {:ok, transport_socket} = :ssl.transport_accept(listen_socket, 5_000)
      {:ok, server_socket} = :ssl.handshake(transport_socket, 5_000)

      # Extract CN from the client's certificate (as seen by server)
      {:ok, cn} = Cortex.Identity.get_node_cn(server_socket)
      assert cn == "node-b"

      client = Task.await(task)
      :ssl.close(client)
      :ssl.close(server_socket)
      :ssl.close(listen_socket)
    end
  end
end
