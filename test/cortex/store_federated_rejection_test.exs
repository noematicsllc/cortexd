defmodule Cortex.StoreFederatedRejectionTest do
  use ExUnit.Case

  alias Cortex.Store

  @moduletag :mesh

  # Task 9.2: Verify @-prefix tables without federated identity return errors

  setup do
    uid = 50_000 + :erlang.unique_integer([:positive])
    {:ok, uid: uid}
  end

  describe "create_table with @ prefix" do
    test "returns :federated_identity_required without federated identity", %{uid: uid} do
      result = Store.create_table(uid, "@memories", [:id, :content])
      assert {:error, :federated_identity_required} = result
    end

    test "returns :federated_identity_required for fully-qualified without identity", %{uid: uid} do
      result = Store.create_table(uid, "@alice:memories", [:id, :content])
      assert {:error, :federated_identity_required} = result
    end

    test "returns :unauthorized when claiming another identity's namespace", %{uid: uid} do
      # Register a federated identity for this UID
      fed_id = "rejection-test-#{uid}"
      node_name = "test-node-#{uid}"
      {:ok, :ok} = Store.register_identity(fed_id, node_name, uid)

      on_exit(fn ->
        try do
          Store.revoke_identity(fed_id)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

      # Try to create a table under a different federated identity's namespace
      result =
        Store.create_table(uid, "@other-identity:memories", [:id, :content], node_name: node_name)

      assert {:error, :unauthorized} = result
    end

    test "succeeds with valid federated identity", %{uid: uid} do
      fed_id = "rejection-ok-#{uid}"
      node_name = "test-node-#{uid}"
      {:ok, :ok} = Store.register_identity(fed_id, node_name, uid)

      on_exit(fn ->
        try do
          Store.revoke_identity(fed_id)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        try do
          :mnesia.delete_table(String.to_existing_atom("@#{fed_id}:memories"))
        rescue
          _ -> :ok
        end
      end)

      result = Store.create_table(uid, "@memories", [:id, :content], node_name: node_name)
      assert {:ok, table_name} = result
      assert table_name == String.to_atom("@#{fed_id}:memories")
    end
  end

  describe "resolve_table with @ prefix" do
    test "returns :table_does_not_exist without federated identity", %{uid: uid} do
      result = Store.resolve_table(uid, "@memories")
      assert result == :table_does_not_exist
    end

    test "returns :table_does_not_exist for non-existent fully-qualified table" do
      # Even with a valid format, if the atom doesn't exist, returns :table_does_not_exist
      result = Store.resolve_table(nil, "@nonexistent_fed_id_xyz:memories")
      assert result == :table_does_not_exist
    end
  end

  describe "handler-level create_table with @ prefix" do
    test "returns error for @-prefixed table without federated identity" do
      # This tests the handler path via the store layer
      uid = 50_000 + :erlang.unique_integer([:positive])
      result = Store.create_table(uid, "@data", [:id, :value])
      assert {:error, :federated_identity_required} = result
    end
  end
end
