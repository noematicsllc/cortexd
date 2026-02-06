defmodule Cortex.StoreFederatedTest do
  use ExUnit.Case

  alias Cortex.Store

  @moduletag :mesh

  # Task 4.6: Federated table creation, resolution, and cross-namespace access

  setup do
    test_id = :erlang.unique_integer([:positive])
    uid = 50_000 + test_id
    fed_id = "fed-user-#{test_id}"

    # Set up mesh config so resolve_caller_fed_id works
    original_mesh = Application.get_env(:cortex, :mesh)
    Application.put_env(:cortex, :mesh, [node_name: "test-node", tls_port: 5528])

    # Register a federated identity for this test
    {:ok, :ok} = Store.register_identity(fed_id, "test-node", uid)

    on_exit(fn ->
      if original_mesh, do: Application.put_env(:cortex, :mesh, original_mesh),
      else: Application.delete_env(:cortex, :mesh)

      # Clean up identity
      try do
        Store.revoke_identity(fed_id)
      catch
        _, _ -> :ok
      end

      # Clean up any created tables
      for table <- :mnesia.system_info(:tables) do
        name = Atom.to_string(table)
        if String.starts_with?(name, "@#{fed_id}:") or String.starts_with?(name, "#{uid}:") do
          :mnesia.delete_table(table)
          :mnesia.transaction(fn ->
            :mnesia.delete({:cortex_meta, table})
          end)
        end
      end
    end)

    {:ok, uid: uid, fed_id: fed_id, test_id: test_id}
  end

  describe "federated table creation" do
    test "creates table with @ prefix using caller's federated identity", %{uid: uid, fed_id: fed_id} do
      table_name = "memories"
      {:ok, created} = Store.create_table(uid, "@#{table_name}", [:key, :value])

      expected_atom = String.to_atom("@#{fed_id}:#{table_name}")
      assert created == expected_atom
    end

    test "creates table with explicit @owner:name", %{uid: uid, fed_id: fed_id} do
      {:ok, created} = Store.create_table(uid, "@#{fed_id}:notes", [:id, :text])

      expected_atom = String.to_atom("@#{fed_id}:notes")
      assert created == expected_atom
    end

    test "federated tables default to :all node scope", %{uid: uid} do
      {:ok, table} = Store.create_table(uid, "@settings", [:key, :value])

      {:ok, meta} = Store.get_table_meta(table)
      assert meta.node_scope == :all
    end

    test "local tables default to :local node scope", %{uid: uid} do
      {:ok, table} = Store.create_table(uid, "local_data", [:key, :value])

      {:ok, meta} = Store.get_table_meta(table)
      assert meta.node_scope == :local
    end

    test "can override federated table scope", %{uid: uid} do
      {:ok, table} = Store.create_table(uid, "@scoped", [:key, :value], node_scope: :local)

      {:ok, meta} = Store.get_table_meta(table)
      assert meta.node_scope == :local
    end
  end

  describe "federated table resolution" do
    test "resolves @name to @fed_id:name for caller with federated identity", %{uid: uid, fed_id: fed_id} do
      {:ok, table} = Store.create_table(uid, "@mydata", [:key, :value])

      resolved = Store.resolve_table(uid, "@mydata")
      assert resolved == table
      assert resolved == String.to_atom("@#{fed_id}:mydata")
    end

    test "resolves fully qualified @owner:name directly", %{uid: uid, fed_id: fed_id} do
      {:ok, table} = Store.create_table(uid, "@#{fed_id}:explicit", [:key, :value])

      resolved = Store.resolve_table(uid, "@#{fed_id}:explicit")
      assert resolved == table
    end

    test "unresolvable @ name returns :table_does_not_exist for unknown user" do
      # UID with no federated identity
      resolved = Store.resolve_table(99999, "@something")

      # Without federated identity, it can't resolve — the atom won't exist
      assert resolved == :table_does_not_exist
    end
  end

  describe "federated table data operations" do
    test "put and get work on federated tables", %{uid: uid} do
      {:ok, table} = Store.create_table(uid, "@docs", [:id, :content])

      {:ok, :ok} = Store.put(table, %{"id" => "doc1", "content" => "hello"})
      {:ok, record} = Store.get(table, "doc1")

      assert record["id"] == "doc1"
      assert record["content"] == "hello"
    end

    test "match works on federated tables", %{uid: uid} do
      {:ok, table} = Store.create_table(uid, "@items", [:name, :type])

      {:ok, :ok} = Store.put(table, %{"name" => "a", "type" => "fruit"})
      {:ok, :ok} = Store.put(table, %{"name" => "b", "type" => "veggie"})
      {:ok, :ok} = Store.put(table, %{"name" => "c", "type" => "fruit"})

      {:ok, matches} = Store.match(table, %{"type" => "fruit"})
      assert length(matches) == 2
    end
  end

  describe "tables/1 includes federated tables" do
    test "lists both local and federated tables", %{uid: uid, fed_id: fed_id} do
      {:ok, _} = Store.create_table(uid, "local_tbl", [:key, :value])
      {:ok, _} = Store.create_table(uid, "@fed_tbl", [:key, :value])

      tables = Store.tables(uid)

      assert "local_tbl" in tables
      assert "@#{fed_id}:fed_tbl" in tables
    end
  end
end
