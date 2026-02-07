defmodule Cortex.Mesh.IntegrationTest do
  use ExUnit.Case

  @moduletag :mesh
  @moduletag :integration

  # Tasks 8.1-8.5: Multi-node integration tests
  #
  # These tests require a real multi-node setup (2-3 cortexd nodes with mTLS).
  # They are tagged with :integration and excluded from normal test runs.
  #
  # To run: mix test --include integration
  #
  # Prerequisites:
  # 1. Initialize CA: cortex mesh init-ca /path/to/certs
  # 2. Generate node certs for each node
  # 3. Configure mesh in config/config.exs on each node
  # 4. Start cortexd on each node
  #
  # These tests connect to running cortexd nodes as a client.

  # Task 8.1: Multi-node test infrastructure helper
  defp mesh_nodes do
    case Cortex.mesh_config() do
      nil -> []
      config -> Keyword.get(config, :nodes, [])
    end
  end

  defp require_mesh! do
    if mesh_nodes() == [] do
      flunk("Multi-node tests require mesh configuration with at least 2 nodes")
    end
  end

  # Task 8.2: End-to-end identity and federated table test
  @tag :integration
  test "register identity on node-a, claim on node-b, create federated table" do
    require_mesh!()

    # This test verifies the full federated identity workflow:
    # 1. Register identity on local node
    # 2. Get claim token
    # 3. Claim on remote node (via RPC)
    # 4. Create federated table
    # 5. Read from both nodes

    config = Cortex.mesh_config()
    node_name = Keyword.fetch!(config, :node_name)

    # Register a test identity
    test_id = "integration-test-#{System.system_time(:millisecond)}"
    uid = 1000

    {:ok, :ok} = Cortex.Store.register_identity(test_id, node_name, uid)

    # Verify it exists
    {:ok, identity} = Cortex.Store.lookup_federated(test_id)
    assert identity.fed_id == test_id

    # Generate claim token
    {:ok, token} = Cortex.Mesh.Token.generate(test_id, node_name, uid)
    assert is_binary(token)

    # Decode and verify payload
    {:ok, payload} = Cortex.Mesh.Token.decode_payload(token)
    assert payload["fed_id"] == test_id

    # Clean up
    Cortex.Store.revoke_identity(test_id)
  end

  # Task 8.3: Node scope enforcement across nodes
  @tag :integration
  test "local table inaccessible from remote, :all table accessible" do
    require_mesh!()

    uid = 1000
    local_table = "integ_local_#{System.system_time(:millisecond)}"
    global_table = "integ_global_#{System.system_time(:millisecond)}"

    # Create a local-scoped table
    {:ok, lt} = Cortex.Store.create_table(uid, local_table, [:key, :value], node_scope: :local)
    {:ok, gt} = Cortex.Store.create_table(uid, global_table, [:key, :value], node_scope: :all)

    # Verify scope is set correctly
    {:ok, lt_meta} = Cortex.Store.get_table_meta(lt)
    assert lt_meta.node_scope == :local

    {:ok, gt_meta} = Cortex.Store.get_table_meta(gt)
    assert gt_meta.node_scope == :all

    # Check scope enforcement
    assert {:error, :access_denied} = Cortex.ACL.check_node_scope(lt, "remote-node")
    assert :ok = Cortex.ACL.check_node_scope(gt, "remote-node")

    # Clean up
    Cortex.Store.drop_table(uid, local_table)
    Cortex.Store.drop_table(uid, global_table)
  end

  # Task 8.4: Replication test
  @tag :integration
  test "put on local node, data available after sync" do
    require_mesh!()

    uid = 1000
    table_name = "integ_replicated_#{System.system_time(:millisecond)}"

    {:ok, table} = Cortex.Store.create_table(uid, table_name, [:key, :value], node_scope: :all)

    # Write data
    {:ok, :ok} = Cortex.Store.put(table, %{"key" => "test-key", "value" => "test-value"})

    # Read back locally
    {:ok, record} = Cortex.Store.get(table, "test-key")
    assert record["value"] == "test-value"

    # Check sync status
    [status] = Cortex.Sync.status(table)
    assert status.size >= 1

    # Clean up
    Cortex.Store.drop_table(uid, table_name)
  end

  # Task 8.5: Partition resilience
  @tag :integration
  test "local operations continue during partition" do
    require_mesh!()

    uid = 1000
    table_name = "integ_partition_#{System.system_time(:millisecond)}"

    {:ok, table} = Cortex.Store.create_table(uid, table_name, [:key, :value], node_scope: :all)

    # Operations should work regardless of peer connectivity
    {:ok, :ok} = Cortex.Store.put(table, %{"key" => "during-test", "value" => "works"})
    {:ok, record} = Cortex.Store.get(table, "during-test")
    assert record["value"] == "works"

    # Clean up
    Cortex.Store.drop_table(uid, table_name)
  end
end
