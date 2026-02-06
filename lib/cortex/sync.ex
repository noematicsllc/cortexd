defmodule Cortex.Sync do
  @moduledoc """
  Manages Mnesia table replication based on node scope.

  Adds or removes table copies on nodes to match each table's
  `node_scope` setting. Called when:
  - A table's node scope changes
  - A new node joins the mesh
  - System tables need to be replicated
  """

  require Logger

  alias Cortex.Store

  @system_tables [:cortex_acls, :cortex_meta, :cortex_identities]

  @doc """
  Apply replication for a table based on its node_scope.
  """
  def apply_node_scope(table) do
    case Store.get_table_meta(table) do
      {:ok, %{node_scope: :local}} ->
        remove_all_replicas(table)

      {:ok, %{node_scope: :all}} ->
        results = for node <- mesh_nodes(), do: setup_replication(table, node)
        errors = Enum.filter(results, &match?({:error, _}, &1))
        if errors == [], do: :ok, else: {:error, {:partial_failure, errors}}

      {:ok, %{node_scope: nodes}} when is_list(nodes) ->
        mesh = mesh_nodes()

        results =
          for node <- mesh do
            if node_name(node) in nodes do
              setup_replication(table, node)
            else
              remove_replica(table, node)
            end
          end

        errors = Enum.filter(results, &match?({:error, _}, &1))
        if errors == [], do: :ok, else: {:error, {:partial_failure, errors}}

      {:error, reason} ->
        Logger.error("Cannot apply node scope for #{table}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Called when a new node joins the mesh.
  Replicates appropriate tables to the new node.
  """
  def on_node_join(new_node) do
    # Always replicate system tables
    for table <- @system_tables do
      setup_replication(table, new_node)
    end

    # Replicate user tables based on scope
    for table <- all_user_tables() do
      case Store.get_table_meta(table) do
        {:ok, %{node_scope: :all}} ->
          setup_replication(table, new_node)

        {:ok, %{node_scope: nodes}} when is_list(nodes) ->
          if node_name(new_node) in nodes do
            setup_replication(table, new_node)
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  @doc """
  Called when a node leaves the mesh.
  """
  def on_node_leave(node) do
    Logger.info("Node left mesh: #{inspect(node)}")
    :ok
  end

  @doc """
  Ensure all system tables are replicated to all mesh nodes.
  Called during mesh initialization.
  """
  def replicate_system_tables do
    for table <- @system_tables, node <- mesh_nodes() do
      setup_replication(table, node)
    end

    :ok
  end

  @doc """
  Get sync status for all replicated tables or a specific table.
  """
  def status(table \\ nil) do
    tables = if table, do: [table], else: replicated_tables()

    Enum.map(tables, fn t ->
      copies =
        try do
          :mnesia.table_info(t, :all_nodes)
        rescue
          _ -> [node()]
        end

      %{
        table: t,
        nodes: copies,
        size:
          try do
            :mnesia.table_info(t, :size)
          rescue
            _ -> 0
          end
      }
    end)
  end

  @doc """
  Force re-sync a table by removing and re-adding copies.
  """
  def repair(table) do
    for node <- mesh_nodes() do
      remove_replica(table, node)
    end

    apply_node_scope(table)
  end

  # Private

  defp setup_replication(table, target_node) do
    case :mnesia.add_table_copy(table, target_node, :disc_copies) do
      {:atomic, :ok} ->
        Logger.debug("Replicated #{table} to #{target_node}")
        :ok

      {:aborted, {:already_exists, _, _}} ->
        :ok

      {:aborted, reason} ->
        Logger.warning("Failed to replicate #{table} to #{target_node}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp remove_replica(table, node) do
    case :mnesia.del_table_copy(table, node) do
      {:atomic, :ok} -> :ok
      {:aborted, {:no_exists, _, _}} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp remove_all_replicas(table) do
    for node <- mesh_nodes() do
      remove_replica(table, node)
    end

    :ok
  end

  defp mesh_nodes do
    Node.list()
  end

  defp node_name(erlang_node) do
    erlang_node
    |> Atom.to_string()
    |> String.split("@")
    |> hd()
  end

  defp all_user_tables do
    :mnesia.system_info(:tables) -- [:schema | @system_tables]
  end

  defp replicated_tables do
    :mnesia.system_info(:tables)
    |> Enum.filter(fn t ->
      try do
        length(:mnesia.table_info(t, :all_nodes)) > 1
      rescue
        _ -> false
      end
    end)
  end
end
