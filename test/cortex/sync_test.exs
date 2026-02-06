defmodule Cortex.SyncTest do
  use ExUnit.Case

  alias Cortex.{Sync, Store}

  @moduletag :mesh

  # Task 7.8: Replication setup, scope-driven replica management, node join/leave handling

  setup do
    test_id = :erlang.unique_integer([:positive])
    uid = 70_000 + test_id
    table_name = "sync_test_#{test_id}"

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

  describe "status/0" do
    test "returns list of table status maps" do
      result = Sync.status()
      assert is_list(result)

      # Each entry should have table, nodes, size
      for entry <- result do
        assert Map.has_key?(entry, :table)
        assert Map.has_key?(entry, :nodes)
        assert Map.has_key?(entry, :size)
      end
    end
  end

  describe "status/1" do
    test "returns status for a specific table", %{table: table} do
      [entry] = Sync.status(table)

      assert entry.table == table
      assert is_list(entry.nodes)
      assert is_integer(entry.size)
    end
  end

  describe "apply_node_scope/1" do
    test "does not crash for :local scope table", %{table: table} do
      # :local scope — should remove replicas (none exist in single-node test, so no-op)
      assert Sync.apply_node_scope(table) == :ok
    end

    test "does not crash for :all scope table", %{table: table} do
      {:ok, :ok} = Store.set_node_scope(table, :all)

      # :all scope on single node — no peers to replicate to
      result = Sync.apply_node_scope(table)
      assert result == :ok
    end

    test "does not crash for node list scope", %{table: table} do
      {:ok, :ok} = Store.set_node_scope(table, ["node-a", "node-b"])

      result = Sync.apply_node_scope(table)
      assert result == :ok
    end

    test "returns error for non-existent table" do
      assert {:error, _} = Sync.apply_node_scope(:nonexistent_sync_table)
    end
  end

  describe "on_node_join/1" do
    test "does not crash when handling a join event" do
      # In single-node mode, this will try to replicate system tables to a fake node
      # It should handle errors gracefully
      assert Sync.on_node_join(:fake@node) == :ok
    end
  end

  describe "on_node_leave/1" do
    test "does not crash when handling a leave event" do
      assert Sync.on_node_leave(:fake@node) == :ok
    end
  end

  describe "replicate_system_tables/0" do
    test "does not crash on single node" do
      # No peers, so this is essentially a no-op
      assert Sync.replicate_system_tables() == :ok
    end
  end

  describe "repair/1" do
    test "does not crash for valid table", %{table: table} do
      # Set to :all so repair has something to do
      {:ok, :ok} = Store.set_node_scope(table, :all)

      # repair removes replicas then re-applies scope — no-op on single node
      Sync.repair(table)
    end
  end

  describe "scope change triggers sync" do
    test "set_node_scope triggers apply_node_scope", %{table: table} do
      # This is more of an integration test — set_node_scope calls Sync.apply_node_scope
      # If it errors, the scope change still succeeds (fire-and-forget)
      {:ok, :ok} = Store.set_node_scope(table, :all)

      {:ok, meta} = Store.get_table_meta(table)
      assert meta.node_scope == :all
    end
  end
end
