defmodule Cortex.ACLScopeTest do
  use ExUnit.Case

  alias Cortex.{ACL, Store}

  @moduletag :mesh

  # Task 5.9: Node scope enforcement, migration of old records, scope changes

  setup do
    test_id = :erlang.unique_integer([:positive])
    uid = 60_000 + test_id
    table_name = "scope_test_#{test_id}"

    {:ok, table} = Store.create_table(uid, table_name, [:key, :value])

    on_exit(fn ->
      try do
        :mnesia.delete_table(table)
        :mnesia.transaction(fn ->
          :mnesia.delete({:cortex_meta, table})
          :mnesia.delete({:cortex_acls, {"uid:#{uid}", table}})
        end)
      catch
        _, _ -> :ok
      end
    end)

    {:ok, uid: uid, table: table, test_id: test_id}
  end

  describe "check_node_scope/2" do
    test "local requests always pass (requesting_node=nil)", %{table: table} do
      assert :ok = ACL.check_node_scope(table, nil)
    end

    test "rejects remote request on :local scope table", %{table: table} do
      # Default scope is :local for non-federated tables
      assert {:error, :access_denied} = ACL.check_node_scope(table, "remote-node")
    end

    test "allows remote request on :all scope table", %{table: table} do
      {:ok, :ok} = Store.set_node_scope(table, :all)

      assert :ok = ACL.check_node_scope(table, "any-node")
    end

    test "allows remote request from node in scope list", %{table: table} do
      {:ok, :ok} = Store.set_node_scope(table, ["node-a", "node-b"])

      assert :ok = ACL.check_node_scope(table, "node-a")
      assert :ok = ACL.check_node_scope(table, "node-b")
    end

    test "rejects remote request from node not in scope list", %{table: table} do
      {:ok, :ok} = Store.set_node_scope(table, ["node-a", "node-b"])

      assert {:error, :access_denied} = ACL.check_node_scope(table, "node-c")
    end

    test "rejects request for non-existent table" do
      assert {:error, :access_denied} = ACL.check_node_scope(:nonexistent_table_xyz, "node-a")
    end
  end

  describe "authorize/4 with node scope" do
    test "local request bypasses node scope check", %{uid: uid, table: table} do
      # Owner, local request — should pass even on :local scope
      assert :ok = ACL.authorize(uid, table, :get, nil)
      assert :ok = ACL.authorize(uid, table, :get)
    end

    test "remote request blocked by :local scope", %{uid: uid, table: table} do
      # Owner, but remote — node scope blocks first
      assert {:error, :access_denied} = ACL.authorize(uid, table, :get, "remote-node")
    end

    test "remote request allowed on :all scope with valid ACL", %{uid: uid, table: table} do
      {:ok, :ok} = Store.set_node_scope(table, :all)

      # Owner can access remotely when scope allows
      assert :ok = ACL.authorize(uid, table, :get, "any-node")
    end

    test "remote request on :all scope still requires ACL", %{table: table} do
      {:ok, :ok} = Store.set_node_scope(table, :all)

      # Non-owner, no ACL grant — should fail on ACL (not scope)
      other_uid = 99998
      assert {:error, :access_denied} = ACL.authorize(other_uid, table, :get, "any-node")
    end

    test "root bypasses both scope and ACL", %{table: table} do
      assert :ok = ACL.authorize(0, table, :get, "any-node")
    end
  end

  describe "set_node_scope/2" do
    test "changes scope from :local to :all", %{table: table} do
      {:ok, meta_before} = Store.get_table_meta(table)
      assert meta_before.node_scope == :local

      {:ok, :ok} = Store.set_node_scope(table, :all)

      {:ok, meta_after} = Store.get_table_meta(table)
      assert meta_after.node_scope == :all
    end

    test "changes scope to specific node list", %{table: table} do
      {:ok, :ok} = Store.set_node_scope(table, ["node-x", "node-y"])

      {:ok, meta} = Store.get_table_meta(table)
      assert meta.node_scope == ["node-x", "node-y"]
    end

    test "changes scope back to :local", %{table: table} do
      {:ok, :ok} = Store.set_node_scope(table, :all)
      {:ok, :ok} = Store.set_node_scope(table, :local)

      {:ok, meta} = Store.get_table_meta(table)
      assert meta.node_scope == :local
    end

    test "fails for non-existent table" do
      assert {:error, :not_found} = Store.set_node_scope(:nonexistent_scope_table, :all)
    end
  end

  describe "backward compatibility" do
    test "new tables always include node_scope in meta" do
      uid = 60_000 + :erlang.unique_integer([:positive])
      {:ok, table} = Store.create_table(uid, "compat_tbl", [:key, :value])

      on_exit(fn ->
        :mnesia.delete_table(table)
        :mnesia.transaction(fn -> :mnesia.delete({:cortex_meta, table}) end)
      end)

      {:ok, meta} = Store.get_table_meta(table)
      # New tables always have a node_scope field
      assert meta.node_scope == :local
      assert meta.owner == uid
      assert meta.key_field == :key
      assert meta.attributes == [:key, :value]
    end

    test "get_table_meta returns :not_found for missing table" do
      assert {:error, :not_found} = Store.get_table_meta(:table_that_does_not_exist_at_all)
    end
  end

  describe "create_table with --scope" do
    test "creates table with explicit :all scope" do
      uid = 60_000 + :erlang.unique_integer([:positive])
      {:ok, table} = Store.create_table(uid, "pub_data", [:key, :value], node_scope: :all)

      on_exit(fn ->
        :mnesia.delete_table(table)
        :mnesia.transaction(fn -> :mnesia.delete({:cortex_meta, table}) end)
      end)

      {:ok, meta} = Store.get_table_meta(table)
      assert meta.node_scope == :all
    end

    test "creates table with node list scope" do
      uid = 60_000 + :erlang.unique_integer([:positive])
      {:ok, table} = Store.create_table(uid, "shared", [:key, :value], node_scope: ["a", "b"])

      on_exit(fn ->
        :mnesia.delete_table(table)
        :mnesia.transaction(fn -> :mnesia.delete({:cortex_meta, table}) end)
      end)

      {:ok, meta} = Store.get_table_meta(table)
      assert meta.node_scope == ["a", "b"]
    end
  end
end
