defmodule Cortex.StoreIdentityTest do
  use ExUnit.Case

  alias Cortex.Store

  @moduletag :mesh

  # Task 3.7: Identity registration, claiming, lookup, and revocation

  setup do
    test_id = :erlang.unique_integer([:positive])
    fed_id = "test-user-#{test_id}"

    on_exit(fn ->
      # Clean up any test identities
      try do
        Store.revoke_identity(fed_id)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    {:ok, fed_id: fed_id, test_id: test_id}
  end

  describe "register_identity/3" do
    test "registers a new federated identity", %{fed_id: fed_id} do
      assert {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)

      {:ok, identity} = Store.lookup_federated(fed_id)
      assert identity.fed_id == fed_id
      assert identity.mappings == %{"node-a" => 1000}
      assert identity.metadata[:created_by] == "node-a"
    end

    test "rejects duplicate registration", %{fed_id: fed_id} do
      {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)

      assert {:error, :already_exists} = Store.register_identity(fed_id, "node-b", 2000)
    end

    test "stores creation timestamp", %{fed_id: fed_id} do
      {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)

      {:ok, identity} = Store.lookup_federated(fed_id)
      assert is_binary(identity.metadata[:created_at])
      # Should be an ISO 8601 timestamp
      assert {:ok, _, _} = DateTime.from_iso8601(identity.metadata[:created_at])
    end
  end

  describe "claim_identity/3" do
    test "adds a node mapping to existing identity", %{fed_id: fed_id} do
      {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)
      {:ok, :ok} = Store.claim_identity(fed_id, "node-b", 2000)

      {:ok, identity} = Store.lookup_federated(fed_id)
      assert identity.mappings == %{"node-a" => 1000, "node-b" => 2000}
    end

    test "fails for non-existent identity" do
      assert {:error, :not_found} = Store.claim_identity("nonexistent", "node-x", 9999)
    end

    test "allows same node to update UID mapping", %{fed_id: fed_id} do
      {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)
      {:ok, :ok} = Store.claim_identity(fed_id, "node-a", 1001)

      {:ok, identity} = Store.lookup_federated(fed_id)
      assert identity.mappings["node-a"] == 1001
    end
  end

  describe "lookup_federated/1" do
    test "returns identity with all mappings", %{fed_id: fed_id} do
      {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)
      {:ok, :ok} = Store.claim_identity(fed_id, "node-b", 2000)

      {:ok, identity} = Store.lookup_federated(fed_id)
      assert identity.fed_id == fed_id
      assert map_size(identity.mappings) == 2
    end

    test "returns error for unknown identity" do
      assert {:error, :not_found} = Store.lookup_federated("nobody-#{System.unique_integer()}")
    end
  end

  describe "lookup_federated_by_local/2" do
    test "finds identity by node name and UID", %{fed_id: fed_id} do
      {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)

      assert {:ok, ^fed_id} = Store.lookup_federated_by_local("node-a", 1000)
    end

    test "returns error for unlinked node/UID pair", %{fed_id: fed_id} do
      {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)

      assert {:error, :not_found} = Store.lookup_federated_by_local("node-a", 9999)
      assert {:error, :not_found} = Store.lookup_federated_by_local("node-z", 1000)
    end
  end

  describe "list_identities/0" do
    test "lists all registered identities", %{fed_id: fed_id} do
      {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)

      {:ok, identities} = Store.list_identities()
      assert is_list(identities)

      found = Enum.find(identities, &(&1.fed_id == fed_id))
      assert found != nil
      assert found.mappings == %{"node-a" => 1000}
    end
  end

  describe "revoke_identity/1-2" do
    test "fully revokes an identity", %{fed_id: fed_id} do
      {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)
      {:ok, :ok} = Store.revoke_identity(fed_id)

      assert {:error, :not_found} = Store.lookup_federated(fed_id)
    end

    test "revokes a single node mapping", %{fed_id: fed_id} do
      {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)
      {:ok, :ok} = Store.claim_identity(fed_id, "node-b", 2000)

      {:ok, :ok} = Store.revoke_identity(fed_id, "node-a")

      {:ok, identity} = Store.lookup_federated(fed_id)
      assert identity.mappings == %{"node-b" => 2000}
    end

    test "revoking last node mapping deletes the identity", %{fed_id: fed_id} do
      {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)
      {:ok, :ok} = Store.revoke_identity(fed_id, "node-a")

      assert {:error, :not_found} = Store.lookup_federated(fed_id)
    end

    test "revoking non-existent identity returns error" do
      assert {:error, :not_found} = Store.revoke_identity("ghost-#{System.unique_integer()}")
    end
  end

  describe "Identity.resolve_federated/2" do
    test "resolves federated identity from node/UID", %{fed_id: fed_id} do
      {:ok, :ok} = Store.register_identity(fed_id, "node-a", 1000)

      assert {:ok, ^fed_id} = Cortex.Identity.resolve_federated("node-a", 1000)
    end

    test "returns :not_found for unlinked pair" do
      assert :not_found = Cortex.Identity.resolve_federated("unknown-node", 9999)
    end
  end
end
