defmodule Cortex.Mesh.TLSHandlerIdentityTest do
  use ExUnit.Case

  alias Cortex.TestHelpers.Mesh, as: MH
  alias Cortex.Store

  @moduletag :mesh

  # TLS handler identity tests (ADR-003: remote connections identify as nodes only)

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

  describe "4-element RPC on TLS" do
    test "TLS connection has uid=nil and requesting_node=node_id", %{
      certs: certs,
      port: port
    } do
      {:ok, client} = MH.tls_connect(port, certs, :node_b)

      # 4-element RPC on TLS — uid is nil, requesting_node is the CN
      {:ok, result} = MH.rpc_call(client, "ping")
      assert result == "pong"

      # Status works (doesn't require uid)
      {:ok, status} = MH.rpc_call(client, "status")
      assert status["status"] == "running"

      :ssl.close(client)
    end

    test "TLS connection can list identities", %{certs: certs, port: port} do
      {:ok, client} = MH.tls_connect(port, certs, :node_b)

      {:ok, result} = MH.rpc_call(client, "identity_list")
      assert is_list(result)

      :ssl.close(client)
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

      # Remote request to a :local table should be denied (uid=nil on TLS)
      {:error, error_msg} = MH.rpc_call(client, "get", [table_name, "key1"])

      assert error_msg =~ "access_denied" or error_msg =~ "not_found" or
               error_msg =~ "table_does_not_exist"

      :ssl.close(client)
    end

    test "TLS request to :all scope world-readable table is allowed", %{
      certs: certs,
      port: port
    } do
      uid = 50_000 + :erlang.unique_integer([:positive])
      table_name = "all_scope_test_#{:erlang.unique_integer([:positive])}"

      {:ok, table_atom} = Store.create_table(uid, table_name, [:id, :value], node_scope: :all)

      # Grant world-read so TLS connections (uid=nil) can access
      Store.acl_grant("*", table_atom, [:read])
      Store.put(table_atom, %{"id" => "key1", "value" => "hello"})

      # TLS connections must use fully-qualified name (uid:name) since uid=nil
      fq_name = "#{uid}:#{table_name}"

      on_exit(fn ->
        try do
          :mnesia.delete_table(table_atom)
        rescue
          _ -> :ok
        end
      end)

      {:ok, client} = MH.tls_connect(port, certs, :node_b)

      # Remote request using fully-qualified name to :all scope + world-readable table
      {:ok, result} = MH.rpc_call(client, "get", [fq_name, "key1"])

      assert result["id"] == "key1"
      assert result["value"] == "hello"

      :ssl.close(client)
    end

    test "TLS request to named-node scope world-readable table with matching node succeeds", %{
      certs: certs,
      port: port
    } do
      uid = 50_000 + :erlang.unique_integer([:positive])
      table_name = "node_scope_test_#{:erlang.unique_integer([:positive])}"

      # Create table with scope allowing "node-b" (the connecting node's CN)
      {:ok, table_atom} =
        Store.create_table(uid, table_name, [:id, :value], node_scope: ["node-b"])

      # Grant world-read so TLS connections (uid=nil) can access
      Store.acl_grant("*", table_atom, [:read])
      Store.put(table_atom, %{"id" => "key1", "value" => "scoped"})

      # TLS connections must use fully-qualified name
      fq_name = "#{uid}:#{table_name}"

      on_exit(fn ->
        try do
          :mnesia.delete_table(table_atom)
        rescue
          _ -> :ok
        end
      end)

      {:ok, client} = MH.tls_connect(port, certs, :node_b)

      {:ok, result} = MH.rpc_call(client, "get", [fq_name, "key1"])

      assert result["value"] == "scoped"

      :ssl.close(client)
    end
  end
end
