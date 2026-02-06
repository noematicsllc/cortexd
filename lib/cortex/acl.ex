defmodule Cortex.ACL do
  @moduledoc """
  Access control layer.

  Checks permissions before allowing operations on tables.
  """

  alias Cortex.Store
  alias Cortex.Identity

  @doc """
  Check if the given UID can perform an operation on a table.

  Operations:
  - :read - get, match, all
  - :write - put, delete
  - :admin - acl_grant, acl_revoke, drop_table
  """
  def authorize(_uid, :table_does_not_exist, _operation) do
    # Table atom doesn't exist - return same error as unauthorized (no info leak)
    {:error, :access_denied}
  end

  def authorize(uid, table_name, operation, requesting_node \\ nil) do
    # Root (UID 0) bypasses all ACL checks. This enables:
    # - Admin backup/recovery of all data
    # - Auditing agent activity across all tables
    # - Emergency data access without per-table grants
    if uid == 0 do
      :ok
    else
      with :ok <- check_node_scope(table_name, requesting_node) do
        authorize_non_root(uid, table_name, operation)
      end
    end
  end

  @doc """
  Check if the requesting node is permitted by the table's node scope.
  Local requests (requesting_node == nil) always pass.
  """
  def check_node_scope(_table_name, nil), do: :ok

  def check_node_scope(table_name, requesting_node) do
    case Store.get_table_meta(table_name) do
      {:ok, %{node_scope: :all}} -> :ok
      {:ok, %{node_scope: :local}} -> {:error, :access_denied}
      {:ok, %{node_scope: nodes}} when is_list(nodes) ->
        if requesting_node in nodes, do: :ok, else: {:error, :access_denied}
      {:error, :not_found} -> {:error, :access_denied}
      error -> error
    end
  end

  defp authorize_non_root(uid, table_name, operation) do
    identity = Identity.uid_to_identity(uid)

    # Check ownership first
    case Store.get_table_meta(table_name) do
      {:ok, %{owner: ^uid}} ->
        # Owner has full access
        :ok

      {:ok, _meta} ->
        # Not owner, check ACLs
        case operation_to_permission(operation) do
          {:error, :unknown_operation} ->
            # Log and deny - don't crash the handler
            require Logger
            Logger.error("Unknown operation in ACL check: #{inspect(operation)}")
            {:error, :access_denied}

          permission ->
            case Store.acl_check(identity, table_name, permission) do
              {:ok, true} -> :ok
              # Uniform error prevents table existence probing
              {:ok, false} -> {:error, :access_denied}
              error -> error
            end
        end

      {:error, :not_found} ->
        # Same error as unauthorized - prevents probing for table existence
        {:error, :access_denied}

      error ->
        error
    end
  end

  @doc """
  Check if the given UID can create tables.
  Currently all users can create tables in their own namespace.
  """
  def can_create_table?(_uid), do: true

  @valid_permissions %{
    "read" => :read,
    "write" => :write,
    "admin" => :admin
  }

  @doc """
  Parse permission strings into atoms.
  Only allows known permissions to prevent atom exhaustion.
  """
  def parse_permissions(perms) when is_binary(perms) do
    perms
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> parse_permission_list()
  end

  def parse_permissions(perms) when is_list(perms) do
    perms
    |> Enum.reduce_while([], fn
      p, acc when is_binary(p) -> {:cont, [p | acc]}
      p, acc when is_atom(p) -> {:cont, [Atom.to_string(p) | acc]}
      _p, _acc -> {:halt, :invalid}
    end)
    |> case do
      :invalid -> {:error, :invalid_permissions}
      list -> list |> Enum.reverse() |> parse_permission_list()
    end
  end

  defp parse_permission_list(perms) do
    result =
      Enum.reduce_while(perms, [], fn perm, acc ->
        case Map.fetch(@valid_permissions, perm) do
          {:ok, atom} -> {:cont, [atom | acc]}
          :error -> {:halt, :invalid}
        end
      end)

    case result do
      :invalid -> {:error, :invalid_permissions}
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp operation_to_permission(op) when op in [:get, :match, :all], do: :read
  defp operation_to_permission(op) when op in [:put, :delete], do: :write
  defp operation_to_permission(op) when op in [:acl_grant, :acl_revoke, :drop_table], do: :admin
  # Return error for unknown operations rather than crashing the handler
  defp operation_to_permission(_op), do: {:error, :unknown_operation}
end
