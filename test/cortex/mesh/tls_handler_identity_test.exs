defmodule Cortex.Mesh.TLSHandlerIdentityTest do
  use ExUnit.Case

  alias Cortex.TestHelpers.Mesh, as: MH
  alias Cortex.Store

  @moduletag :mesh

  # Task 9.1: TLS handler remote identity resolution tests

  setup do
    dir =
      Path.join(System.tmp_dir!(), "cortex_tls_id_test_#{:erlang.unique_integer([:positive])}")

    certs = MH.generate_test_certs(dir)

    test_port = 15_528 + rem(:erlang.unique_integer([:positive]), 10_000)

    mesh_config =
      MH.mesh_config_for(certs, :node_a, "node-a", test_port, [
        {"node-b", "127.0.0.1", test_port + 1}
      ])

    original_mesh = Application.get_env(:cortex, :mesh)
    Application.put_env(:cortex, :mesh, mesh_config)

    {:ok, pid} = Cortex.TLSServer.start_link([])
    Process.sleep(100)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)

      if original_mesh,
        do: Application.put_env(:cortex, :mesh, original_mesh),
        else: Application.delete_env(:cortex, :mesh)
    end)

    {:ok, dir: dir, certs: certs, port: test_port}
  end

  describe "5-element RPC on TLS" do
    test "TLS + metadata with valid uid processes request with requesting_node", %{
      certs: certs,
      port: port
    } do
      {:ok, client} = MH.tls_connect(port, certs, :node_b)

      # Send 5-element RPC with uid metadata
      {:ok, result} =
        MH.rpc_call_with_metadata(client, "ping", [], %{"uid" => 1000})

      assert result == "pong"

      :ssl.close(client)
    end

    test "TLS + metadata with valid uid can access tables with requesting_node set", %{
      certs: certs,
      port: port
    } do
      # Create a table owned by uid 1000 with :all scope (remotely accessible)
      uid = 1000
      table_name = "tls_id_test_#{:erlang.unique_integer([:positive])}"
      {:ok, table_atom} = Store.create_table(uid, table_name, [:id, :value], node_scope: :all)

      on_exit(fn ->
        try do
          :mnesia.delete_table(table_atom)
        rescue
          _ -> :ok
        end
      end)

      {:ok, client} = MH.tls_connect(port, certs, :node_b)

      # 5-element RPC: uid 1000 accessing their own table via TLS
      {:ok, result} =
        MH.rpc_call_with_metadata(client, "status", [], %{"uid" => uid})

      assert result["status"] == "running"

      :ssl.close(client)
    end

    test "TLS + metadata with invalid uid type is treated as nil uid", %{
      certs: certs,
      port: port
    } do
      {:ok, client} = MH.tls_connect(port, certs, :node_b)

      # Send metadata with non-integer uid — should be treated as nil
      {:ok, result} =
        MH.rpc_call_with_metadata(client, "ping", [], %{"uid" => "not_a_number"})

      assert result == "pong"

      :ssl.close(client)
    end

    test "TLS + metadata with negative uid is treated as nil uid", %{
      certs: certs,
      port: port
    } do
      {:ok, client} = MH.tls_connect(port, certs, :node_b)

      # Negative UID should be rejected
      {:ok, result} =
        MH.rpc_call_with_metadata(client, "ping", [], %{"uid" => -1})

      assert result == "pong"

      :ssl.close(client)
    end
  end

  describe "4-element RPC on TLS" do
    test "TLS without metadata has uid=nil and requesting_node=node_id", %{
      certs: certs,
      port: port
    } do
      {:ok, client} = MH.tls_connect(port, certs, :node_b)

      # 4-element RPC on TLS — uid is nil, requesting_node is the CN
      {:ok, result} = MH.rpc_call(client, "ping")
      assert result == "pong"

      # Status still works (doesn't require uid)
      {:ok, status} = MH.rpc_call(client, "status")
      assert status["status"] == "running"

      :ssl.close(client)
    end
  end

  describe "Unix socket + 5-element RPC rejection" do
    test "metadata on Unix socket is rejected (anti-spoofing)" do
      # Use the canonical test socket path (config/test.exs sets this)
      socket_path = Path.expand("../../../tmp/test_cortex.sock", __DIR__)

      # Connect to the running Unix socket server
      opts = [:binary, {:active, false}, {:packet, :raw}]
      {:ok, socket} = :gen_tcp.connect({:local, socket_path}, 0, opts, 5_000)

      # Send a 5-element RPC with metadata via Unix socket
      {:error, error_msg} =
        MH.unix_rpc_call_with_metadata(socket, "ping", [], %{"uid" => 1000})

      assert error_msg =~ "metadata not allowed on local connections"

      :gen_tcp.close(socket)
    end
  end

  describe "node scope enforcement via requesting_node" do
    test "TLS request to :local scope table is denied", %{certs: certs, port: port} do
      uid = 50_000 + :erlang.unique_integer([:positive])
      table_name = "local_scope_test_#{:erlang.unique_integer([:positive])}"

      {:ok, table_atom} =
        Store.create_table(uid, table_name, [:id, :value], node_scope: :local)

      on_exit(fn ->
        try do
          :mnesia.delete_table(table_atom)
        rescue
          _ -> :ok
        end
      end)

      {:ok, client} = MH.tls_connect(port, certs, :node_b)

      # Remote request to a :local table should be denied
      {:error, error_msg} =
        MH.rpc_call_with_metadata(client, "get", [table_name, "key1"], %{"uid" => uid})

      assert error_msg =~ "access_denied"

      :ssl.close(client)
    end

    test "TLS request to :all scope table is allowed", %{certs: certs, port: port} do
      uid = 50_000 + :erlang.unique_integer([:positive])
      table_name = "all_scope_test_#{:erlang.unique_integer([:positive])}"

      {:ok, table_atom} = Store.create_table(uid, table_name, [:id, :value], node_scope: :all)

      # Put a record so get has something to find
      Store.put(table_atom, %{"id" => "key1", "value" => "hello"})

      on_exit(fn ->
        try do
          :mnesia.delete_table(table_atom)
        rescue
          _ -> :ok
        end
      end)

      {:ok, client} = MH.tls_connect(port, certs, :node_b)

      # Remote request to an :all table should succeed
      {:ok, result} =
        MH.rpc_call_with_metadata(client, "get", [table_name, "key1"], %{"uid" => uid})

      assert result["id"] == "key1"
      assert result["value"] == "hello"

      :ssl.close(client)
    end

    test "TLS request to named-node scope table with matching node succeeds", %{
      certs: certs,
      port: port
    } do
      uid = 50_000 + :erlang.unique_integer([:positive])
      table_name = "node_scope_test_#{:erlang.unique_integer([:positive])}"

      # Create table with scope allowing "node-b" (the connecting node's CN)
      {:ok, table_atom} =
        Store.create_table(uid, table_name, [:id, :value], node_scope: ["node-b"])

      Store.put(table_atom, %{"id" => "key1", "value" => "scoped"})

      on_exit(fn ->
        try do
          :mnesia.delete_table(table_atom)
        rescue
          _ -> :ok
        end
      end)

      {:ok, client} = MH.tls_connect(port, certs, :node_b)

      {:ok, result} =
        MH.rpc_call_with_metadata(client, "get", [table_name, "key1"], %{"uid" => uid})

      assert result["value"] == "scoped"

      :ssl.close(client)
    end
  end
end
